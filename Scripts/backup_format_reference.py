# /// script
# requires-python = ">=3.9"
# dependencies = ["cryptography>=42", "argon2-cffi>=23"]
# ///
"""Independent reference parser for the ABB v1 backup layout.

Implemented directly from Docs/BACKUP_FORMAT_DESIGN_V1.md §6–§8, separately from the Swift
codec, so the Swift encoder is cross-checked by a second implementation rather than only by
its own decoder.
Structure parsing uses only the standard library; `open_backup` needs the `cryptography` and
`argon2-cffi` packages, imported lazily so structure checks run under a bare python3.

Usage:
    uv run Scripts/backup_format_reference.py container FILE
    uv run Scripts/backup_format_reference.py payload PLAINTEXT
    uv run Scripts/backup_format_reference.py open FILE CREDENTIAL
"""
import json
import re
import struct
import sys
import unicodedata
import uuid

MAGIC = bytes([0x89, 0x41, 0x45, 0x47, 0x49, 0x53, 0x0D, 0x0A])
FIXED_HEADER = 60
PASSWORD_SLOT, VAULT_SLOT = 0x01, 0x02
PASSWORD_SLOT_LENGTH, VAULT_SLOT_LENGTH = 92, 244
TAG = 16
PADDING_BLOCK = 65536
MAX_PAYLOAD = 32 * 1024 * 1024
MAX_FILE = FIXED_HEADER + PASSWORD_SLOT_LENGTH + VAULT_SLOT_LENGTH + MAX_PAYLOAD + TAG
MAX_REVISIONS, MAX_PARENTS, MAX_TOTAL_PARENTS = 100_000, 1_000, 250_000
SEALED_MIN, SEALED_MAX = 28, 300_000
MAX_EXPORTED_AT = 253_402_300_799_999
PASSWORD_KDF = (65536, 3, 1)


class FormatError(ValueError):
    """kind is one of: not_a_backup, unsupported_version, malformed, unsupported_parameters, limit_exceeded."""

    def __init__(self, kind, detail):
        super().__init__(f"{kind}: {detail}")
        self.kind = kind


class Reader:
    def __init__(self, data):
        self.data, self.offset = data, 0

    @property
    def remaining(self):
        return len(self.data) - self.offset

    def take(self, count):
        if count < 0 or count > self.remaining:
            raise FormatError("malformed", f"need {count} bytes at {self.offset}, {self.remaining} left")
        chunk = self.data[self.offset:self.offset + count]
        self.offset += count
        return chunk

    def u8(self):
        return self.take(1)[0]

    def u16(self):
        return struct.unpack("<H", self.take(2))[0]

    def u32(self):
        return struct.unpack("<I", self.take(4))[0]

    def i64(self):
        return struct.unpack("<q", self.take(8))[0]

    def zeros(self, count):
        if any(self.take(count)):
            raise FormatError("malformed", f"non-zero reserved bytes before {self.offset}")

    def uuid(self):
        return str(uuid.UUID(bytes=self.take(16))).upper()

    def kdf(self):
        return struct.unpack("<III", self.take(12))


def vault_kdf_supported(kdf):
    memory, iterations, parallelism = kdf
    return 65536 <= memory <= 262144 and 3 <= iterations <= 10 and 1 <= parallelism <= 4


def wrap(reader):
    return {"wrapNonce": reader.take(12).hex(), "wrappedFileKey": reader.take(32).hex(), "wrapTag": reader.take(16).hex()}


def parse_slot(reader):
    kind = reader.u8()
    reader.zeros(3)
    if kind == PASSWORD_SLOT:
        memory, iterations, parallelism = reader.kdf()
        return {"type": "password", "memoryKiB": memory, "iterations": iterations, "parallelism": parallelism,
                "salt": reader.take(16).hex(), **wrap(reader)}
    if kind == VAULT_SLOT:
        slot = {"type": "vault", "vaultID": reader.uuid(), "vaultSalt": reader.take(16).hex()}
        memory, iterations, parallelism = reader.kdf()
        slot.update(memoryKiB=memory, iterations=iterations, parallelism=parallelism,
                    wrappedKey=reader.take(60).hex(), recoveryWrappedKey=reader.take(60).hex(),
                    hkdfSalt=reader.take(16).hex(), **wrap(reader))
        return slot
    raise FormatError("malformed", f"unknown slot type {kind:#04x}")


def parse_container(data):
    if len(data) > MAX_FILE:
        raise FormatError("limit_exceeded", f"{len(data)} bytes")
    if data[:8] != MAGIC:
        raise FormatError("not_a_backup", "magic mismatch")
    reader = Reader(data)
    reader.take(8)
    version = reader.u16()
    if version != 1:
        raise FormatError("unsupported_version", str(version))
    slot_count = reader.u8()
    reader.zeros(1)
    payload_length = reader.u32()
    header = {"payloadLength": payload_length, "payloadNonce": reader.take(12).hex(), "commitment": reader.take(32).hex()}
    if slot_count not in (1, 2):
        raise FormatError("malformed", f"slot count {slot_count}")
    slots = [parse_slot(reader) for _ in range(slot_count)]
    if [slot["type"] for slot in slots] not in (["password"], ["vault"], ["password", "vault"]):
        raise FormatError("malformed", "slot types or order")
    # §8.1 checks slot types and order before KDF parameters.
    for slot in slots:
        kdf = (slot["memoryKiB"], slot["iterations"], slot["parallelism"])
        if not (kdf == PASSWORD_KDF if slot["type"] == "password" else vault_kdf_supported(kdf)):
            raise FormatError("unsupported_parameters", f"{slot['type']} slot KDF {kdf}")
    if payload_length > MAX_PAYLOAD:
        raise FormatError("limit_exceeded", f"payload {payload_length}")
    if payload_length == 0 or payload_length % PADDING_BLOCK:
        raise FormatError("malformed", f"payload length {payload_length}")
    if reader.remaining != payload_length + TAG:
        raise FormatError("malformed", f"file length mismatch: {reader.remaining} after header")
    header_length = reader.offset
    header["slots"] = slots
    header["headerLength"] = header_length
    ciphertext = reader.take(payload_length)
    return {"header": header, "ciphertext": ciphertext, "tag": reader.take(TAG).hex()}


def parse_payload(data):
    if len(data) > MAX_PAYLOAD:
        raise FormatError("limit_exceeded", f"{len(data)} bytes")
    if len(data) == 0 or len(data) % PADDING_BLOCK:
        raise FormatError("malformed", f"plaintext length {len(data)}")
    reader = Reader(data)
    exported_at = reader.i64()
    if not 0 <= exported_at <= MAX_EXPORTED_AT:
        raise FormatError("malformed", f"exportedAtMillis {exported_at}")
    flags = reader.u32()
    if flags & ~1:
        raise FormatError("malformed", f"flags {flags:#x}")
    payload = {"exportedAtMillis": exported_at, "incompleteHistory": bool(flags & 1),
               "vaultID": reader.uuid(), "vaultKey": reader.take(32).hex(), "vaultSalt": reader.take(16).hex()}
    kdf = reader.kdf()
    if not vault_kdf_supported(kdf):
        raise FormatError("unsupported_parameters", f"vault KDF {kdf}")
    payload.update(memoryKiB=kdf[0], iterations=kdf[1], parallelism=kdf[2],
                   wrappedKey=reader.take(60).hex(), recoveryWrappedKey=reader.take(60).hex())
    count = reader.u32()
    if count > MAX_REVISIONS:
        raise FormatError("limit_exceeded", f"{count} revisions")
    revisions, total_parents, previous = [], 0, None
    for _ in range(count):
        item_id, revision_raw = reader.take(16), reader.take(16)
        if previous is not None and revision_raw <= previous:
            raise FormatError("malformed", "revisions not strictly ascending")
        previous = revision_raw
        parent_count = reader.u16()
        total_parents += parent_count
        if parent_count > MAX_PARENTS or total_parents > MAX_TOTAL_PARENTS:
            raise FormatError("limit_exceeded", "too many parents")
        parents_raw = [reader.take(16) for _ in range(parent_count)]
        if any(b <= a for a, b in zip(parents_raw, parents_raw[1:])) or revision_raw in parents_raw:
            raise FormatError("malformed", "parents not strictly ascending or self-referencing")
        sealed_length = reader.u32()
        if sealed_length > SEALED_MAX:
            raise FormatError("limit_exceeded", f"sealed {sealed_length}")
        if sealed_length < SEALED_MIN:
            raise FormatError("malformed", f"sealed {sealed_length}")
        revisions.append({"itemID": str(uuid.UUID(bytes=item_id)).upper(),
                          "revisionID": str(uuid.UUID(bytes=revision_raw)).upper(),
                          "parents": [str(uuid.UUID(bytes=p)).upper() for p in parents_raw],
                          "sealed": reader.take(sealed_length).hex()})
    reader.zeros(reader.remaining)
    payload["revisions"] = revisions
    return payload


# --- Decryption (§4.3, §5) -------------------------------------------------------------------

def _hkdf(ikm, salt, info):
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt or None, info=info).derive(ikm)


def _argon2id(secret, salt, memory, iterations, parallelism):
    from argon2.low_level import Type, hash_secret_raw
    return hash_secret_raw(secret=secret, salt=salt, time_cost=iterations, memory_cost=memory,
                           parallelism=parallelism, hash_len=32, type=Type.ID, version=19)


def _gcm_open(key, nonce, ciphertext_and_tag, aad):
    from cryptography.exceptions import InvalidTag
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    try:
        return AESGCM(key).decrypt(nonce, ciphertext_and_tag, aad)
    except InvalidTag:
        return None


def _slot_regions(data, header):
    """Yields (index, slot, raw slot bytes) using the on-disk bytes, not a re-encoding."""
    offset = FIXED_HEADER
    for index, slot in enumerate(header["slots"]):
        length = PASSWORD_SLOT_LENGTH if slot["type"] == "password" else VAULT_SLOT_LENGTH
        yield index, slot, data[offset:offset + length]
        offset += length


def _unwrap_file_key(data, index, slot, raw, kek):
    wrap_offset = 32 if slot["type"] == "password" else 184
    aad = data[:FIXED_HEADER] + bytes([index]) + raw[:wrap_offset]
    wrapped = bytes.fromhex(slot["wrappedFileKey"] + slot["wrapTag"])
    return _gcm_open(kek, bytes.fromhex(slot["wrapNonce"]), wrapped, aad)


def _vault_key(slot, credential):
    """Returns (kind, vault key) for a master password or recovery key, or None."""
    wrapped_key, recovery_wrapped = bytes.fromhex(slot["wrappedKey"]), bytes.fromhex(slot["recoveryWrappedKey"])
    recovery_hex = re.sub(r"[\s-]", "", credential)
    if re.fullmatch(r"[0-9A-Fa-f]{64}", recovery_hex):
        aad = f"aegis|key|1|{slot['vaultID']}|recovery".encode()
        key = _gcm_open(bytes.fromhex(recovery_hex), recovery_wrapped[:12], recovery_wrapped[12:], aad)
        if key is not None:
            return "recoveryKey", key
    kek = _argon2id(credential.encode(), bytes.fromhex(slot["vaultSalt"]),
                    slot["memoryKiB"], slot["iterations"], slot["parallelism"])
    key = _gcm_open(kek, wrapped_key[:12], wrapped_key[12:], f"aegis|key|1|{slot['vaultID']}|master".encode())
    return ("masterPassword", key) if key is not None else None


def open_backup(data, credential):
    """Returns (credential kind, payload dict). Mirrors §4.3: recovery key, backup password, master password."""
    parsed = parse_container(data)
    header = parsed["header"]
    slots = list(_slot_regions(data, header))
    file_key, kind = None, None
    for index, slot, raw in slots:
        if slot["type"] == "password":
            secret = unicodedata.normalize("NFC", credential).encode()
            kek = _argon2id(secret, bytes.fromhex(slot["salt"]), *PASSWORD_KDF)
            file_key = _unwrap_file_key(data, index, slot, raw, kek)
            if file_key is not None:
                kind = "backupPassword"
                break
    if file_key is None:
        for index, slot, raw in slots:
            if slot["type"] == "vault" and (found := _vault_key(slot, credential)):
                kind, vault_key = found
                file_key = _unwrap_file_key(data, index, slot, raw, _hkdf(vault_key, bytes.fromhex(slot["hkdfSalt"]),
                                                                         b"aegis.backup.v1.vault-slot"))
                if file_key is None:
                    raise FormatError("tampered", "vault slot does not open with the proven vault key")
    if file_key is None:
        raise FormatError("wrong_credential", "no slot opened")
    if _hkdf(file_key, b"", b"aegis.backup.v1.commit") != bytes.fromhex(header["commitment"]):
        raise FormatError("tampered", "commitment mismatch")
    header_area = data[:header["headerLength"]]
    plaintext = _gcm_open(_hkdf(file_key, b"", b"aegis.backup.v1.payload"), bytes.fromhex(header["payloadNonce"]),
                          parsed["ciphertext"] + bytes.fromhex(parsed["tag"]), header_area)
    if plaintext is None:
        raise FormatError("tampered", "payload authentication failed")
    return kind, parse_payload(plaintext)


def decrypt_revision(payload, revision):
    """Decrypts one record with the payload's vault key and the record AAD of the existing vault format."""
    aad = "|".join(["aegis", "revision", "1", payload["vaultID"], revision["itemID"], revision["revisionID"],
                    *sorted(revision["parents"])]).encode()
    sealed = bytes.fromhex(revision["sealed"])
    plaintext = _gcm_open(bytes.fromhex(payload["vaultKey"]), sealed[:12], sealed[12:], aad)
    if plaintext is None:
        raise FormatError("invalid_content", f"revision {revision['revisionID']} failed authentication")
    return json.loads(plaintext)


def main(argv):
    if not ((len(argv) == 3 and argv[1] in ("container", "payload")) or (len(argv) == 4 and argv[1] == "open")):
        print(__doc__, file=sys.stderr)
        return 2
    with open(argv[2], "rb") as handle:
        data = handle.read(MAX_FILE + 1)
    try:
        if argv[1] == "open":
            kind, payload = open_backup(data, argv[3])
            items = [decrypt_revision(payload, revision) for revision in payload["revisions"]]
            result = {"openedWith": kind, "revisionCount": len(items), "titles": [item["title"] for item in items]}
        else:
            result = parse_container(data) if argv[1] == "container" else parse_payload(data)
    except FormatError as error:
        print(json.dumps({"error": error.kind, "detail": str(error)}))
        return 1
    if "ciphertext" in result:
        result["ciphertext"] = f"<{len(result['ciphertext'])} bytes>"
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

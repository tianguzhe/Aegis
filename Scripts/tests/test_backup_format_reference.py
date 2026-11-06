"""Cross-check the Swift-generated ABB v1 golden fixtures with the independent Python parser."""
import importlib.util
import json
from pathlib import Path
import sys
import unicodedata
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from backup_format_reference import FormatError, decrypt_revision, open_backup, parse_container, parse_payload

FIXTURES = Path(__file__).resolve().parents[2] / "Packages/AegisKit/Tests/AegisCoreTests/Fixtures"


class BackupFormatReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec = json.loads((FIXTURES / "abb-v1-spec.json").read_text())
        cls.container = (FIXTURES / "abb-v1-container.bin").read_bytes()
        cls.payload = (FIXTURES / "abb-v1-payload.bin").read_bytes()

    def assert_kind(self, kind, parse, data):
        with self.assertRaises(FormatError) as context:
            parse(data)
        self.assertEqual(context.exception.kind, kind)

    def test_container_matches_spec(self):
        parsed = parse_container(self.container)
        header, spec = parsed["header"], self.spec["header"]
        vault = self.spec["vault"]
        self.assertEqual(header["headerLength"], 396)
        self.assertEqual(header["payloadLength"], spec["payloadLength"])
        self.assertEqual(header["payloadNonce"], spec["payloadNonce"])
        self.assertEqual(header["commitment"], spec["commitment"])
        password, vault_slot = header["slots"]
        self.assertEqual(password, {"type": "password", "memoryKiB": 65536, "iterations": 3, "parallelism": 1,
                                    **spec["passwordSlot"]})
        self.assertEqual(vault_slot, {
            "type": "vault", "vaultID": vault["vaultID"], "vaultSalt": vault["salt"],
            "memoryKiB": vault["memoryKiB"], "iterations": vault["iterations"], "parallelism": vault["parallelism"],
            "wrappedKey": vault["wrappedKey"], "recoveryWrappedKey": vault["recoveryWrappedKey"], **spec["vaultSlot"]})
        self.assertEqual(parsed["ciphertext"], bytes(i % 251 for i in range(spec["payloadLength"])))
        self.assertEqual(parsed["tag"], self.spec["tag"])

    def test_payload_matches_spec_in_canonical_order(self):
        parsed, spec, vault = parse_payload(self.payload), self.spec["payload"], self.spec["vault"]
        self.assertEqual(len(self.payload), 65536)
        self.assertEqual(parsed["exportedAtMillis"], spec["exportedAtMillis"])
        self.assertEqual(parsed["incompleteHistory"], spec["incompleteHistory"])
        self.assertEqual(parsed["vaultKey"], spec["vaultKey"])
        self.assertEqual((parsed["vaultID"], parsed["vaultSalt"], parsed["wrappedKey"], parsed["recoveryWrappedKey"]),
                         (vault["vaultID"], vault["salt"], vault["wrappedKey"], vault["recoveryWrappedKey"]))
        self.assertEqual((parsed["memoryKiB"], parsed["iterations"], parsed["parallelism"]),
                         (vault["memoryKiB"], vault["iterations"], vault["parallelism"]))
        # Records ascend by revision ID bytes and parents ascend within each record.
        expected = sorted(({**r, "parents": sorted(r["parents"])} for r in spec["revisions"]),
                          key=lambda r: r["revisionID"])
        self.assertEqual(parsed["revisions"], expected)

    def test_container_rejections(self):
        data = self.container
        for length in (0, 7, 8, 59, 395, len(data) - 1):
            self.assertRaises(FormatError, parse_container, data[:length])
        self.assert_kind("not_a_backup", parse_container, b"\x00" + data[1:])
        self.assert_kind("unsupported_version", parse_container, data[:8] + b"\x02\x00" + data[10:])
        self.assert_kind("malformed", parse_container, data + b"\x00")
        self.assert_kind("malformed", parse_container, data[:152] + b"\x01" + data[153:])
        self.assert_kind("unsupported_parameters", parse_container, data[:64] + b"\x00\x00\x02\x00" + data[68:])

    def test_payload_rejections(self):
        data = self.payload
        self.assert_kind("malformed", parse_payload, data[:-1] + b"\x01")
        self.assert_kind("malformed", parse_payload, data[:228] + b"\xff" * 16 + data[244:])
        self.assert_kind("limit_exceeded", parse_payload, data[:246] + (300001).to_bytes(4, "little") + data[250:])


HAS_CRYPTO = all(importlib.util.find_spec(name) for name in ("cryptography", "argon2"))


@unittest.skipUnless(HAS_CRYPTO, "run with: uv run --with cryptography --with argon2-cffi python3 -m unittest "
                                 "discover -s Scripts/tests -p 'test_backup*.py'")
class BackupCryptoReferenceTests(unittest.TestCase):
    """Opens the Swift-sealed golden vector with an independent Argon2id/HKDF/AES-GCM implementation."""

    @classmethod
    def setUpClass(cls):
        cls.spec = json.loads((FIXTURES / "abb-v1-crypto-spec.json").read_text())
        cls.file = (FIXTURES / "abb-v1-crypto.bin").read_bytes()

    def assert_opens(self, credential, expected_kind):
        kind, payload = open_backup(self.file, credential)
        self.assertEqual(kind, expected_kind)
        vault, revision = self.spec["vault"], self.spec["revision"]
        self.assertEqual((payload["vaultID"], payload["vaultKey"]), (vault["vaultID"], vault["vaultKey"]))
        self.assertEqual(payload["exportedAtMillis"], self.spec["payload"]["exportedAtMillis"])
        [record] = payload["revisions"]
        self.assertEqual((record["itemID"], record["revisionID"]), (revision["itemID"], revision["revisionID"]))
        item = decrypt_revision(payload, record)
        self.assertEqual((item["title"], item["username"], item["password"]),
                         (revision["title"], revision["username"], revision["password"]))

    def test_every_credential_opens(self):
        self.assert_opens(self.spec["backupPassword"], "backupPassword")
        self.assert_opens(unicodedata.normalize("NFD", self.spec["backupPassword"]), "backupPassword")
        self.assert_opens(self.spec["masterPassword"], "masterPassword")
        self.assert_opens(self.spec["recoveryKey"], "recoveryKey")

    def test_wrong_credential_and_tampering_are_rejected(self):
        with self.assertRaises(FormatError) as context:
            open_backup(self.file, "not the right password")
        self.assertEqual(context.exception.kind, "wrong_credential")
        tampered = bytearray(self.file)
        tampered[-20] ^= 1
        with self.assertRaises(FormatError) as context:
            open_backup(bytes(tampered), self.spec["recoveryKey"])
        self.assertEqual(context.exception.kind, "tampered")


if __name__ == "__main__":
    unittest.main()

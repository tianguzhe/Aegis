@testable import AegisCore
import Foundation
import Testing

/// Byte-level tests for ABB v1 (Docs/BACKUP_FORMAT_DESIGN_V1.md §6–§8, §14.1).
/// Offsets below are written out by hand from the spec on purpose, so a layout bug in the
/// encoder cannot hide behind the decoder that shares it.
@Suite struct BackupFormatTests {
    // MARK: Golden fixtures

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    private struct Spec: Decodable {
        struct Vault: Decodable {
            let vaultID: UUID; let salt: String; let memoryKiB, iterations, parallelism: UInt32
            let wrappedKey, recoveryWrappedKey: String
        }
        struct Wrap: Decodable { let wrapNonce, wrappedFileKey, wrapTag: String; let salt, hkdfSalt: String? }
        struct Header: Decodable {
            let payloadLength: UInt32; let payloadNonce, commitment: String; let passwordSlot, vaultSlot: Wrap
        }
        struct Revision: Decodable { let itemID, revisionID: UUID; let parents: [UUID]; let sealed: String }
        struct Payload: Decodable {
            let exportedAtMillis: Int64; let incompleteHistory: Bool; let vaultKey: String; let revisions: [Revision]
        }
        let vault: Vault; let header: Header; let tag: String; let payload: Payload
    }

    private static func spec() throws -> Spec {
        try JSONDecoder().decode(Spec.self, from: Data(contentsOf: fixtures.appendingPathComponent("abb-v1-spec.json")))
    }

    private static func vaultHeader(_ spec: Spec) -> VaultHeader {
        var kdf = KDFParameters()
        kdf.memoryKiB = spec.vault.memoryKiB; kdf.iterations = spec.vault.iterations; kdf.parallelism = spec.vault.parallelism
        return VaultHeader(vaultID: spec.vault.vaultID, salt: hex(spec.vault.salt), kdf: kdf,
                           wrappedKey: hex(spec.vault.wrappedKey), recoveryWrappedKey: hex(spec.vault.recoveryWrappedKey))
    }

    private static func wrap(_ wrap: Spec.Wrap) throws -> WrappedFileKey {
        try WrappedFileKey(nonce: hex(wrap.wrapNonce), ciphertext: hex(wrap.wrappedFileKey), tag: hex(wrap.wrapTag))
    }

    private static func specContainer() throws -> BackupContainer {
        let spec = try spec(), header = spec.header
        let slots: [BackupSlot] = [
            .password(kdf: BackupLimits.passwordSlotKDF, salt: hex(header.passwordSlot.salt!), wrap: try wrap(header.passwordSlot)),
            .vault(header: vaultHeader(spec), hkdfSalt: hex(header.vaultSlot.hkdfSalt!), wrap: try wrap(header.vaultSlot))
        ]
        let backupHeader = try BackupHeader(payloadLength: header.payloadLength, payloadNonce: hex(header.payloadNonce),
                                            commitment: hex(header.commitment), slots: slots)
        let ciphertext = Data((0..<Int(header.payloadLength)).map { UInt8($0 % 251) })
        return try BackupContainer(header: backupHeader, ciphertext: ciphertext, tag: hex(spec.tag))
    }

    private static func specPayload() throws -> BackupPayload {
        let spec = try spec(), header = vaultHeader(spec)
        let revisions = spec.payload.revisions.map {
            EncryptedRevision(vaultID: header.vaultID, itemID: $0.itemID, id: $0.revisionID, parents: $0.parents, ciphertext: hex($0.sealed))
        }
        return try BackupPayload(exportedAtMillis: spec.payload.exportedAtMillis, incompleteHistory: spec.payload.incompleteHistory,
                                 vaultKey: hex(spec.payload.vaultKey), header: header, revisions: revisions)
    }

    /// Compares with the committed fixture; `AEGIS_RECORD_FIXTURES=1` rewrites it instead.
    private static func expectGolden(_ data: Data, named name: String) throws {
        let url = fixtures.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["AEGIS_RECORD_FIXTURES"] == "1" {
            try data.write(to: url)
            Issue.record("Recorded \(name); verify it with Scripts/backup_format_reference.py and rerun without AEGIS_RECORD_FIXTURES")
            return
        }
        #expect(data == (try Data(contentsOf: url)), "\(name) differs from the golden fixture")
    }

    @Test func containerMatchesGoldenFixture() throws {
        let encoded = try Self.specContainer().encoded()
        try Self.expectGolden(encoded, named: "abb-v1-container.bin")
        let parsed = try BackupContainer.parse(encoded)
        #expect(parsed.header == (try Self.specContainer()).header)
        #expect(parsed.encoded() == encoded)
    }

    @Test func payloadMatchesGoldenFixture() throws {
        let payload = try Self.specPayload()
        let encoded = try payload.encoded()
        try Self.expectGolden(encoded, named: "abb-v1-payload.bin")
        let decoded = try BackupPayload.decode(encoded)
        #expect(decoded == payload)
        #expect(decoded.revisions.map(\.id.uuidString) == [
            "0B000000-0000-4000-8000-000000000001", "A0000000-0000-4000-8000-000000000002", "F0000000-0000-4000-8000-000000000003"
        ])
        #expect(try decoded.encoded() == encoded)
    }

    // MARK: Header layout

    @Test func headerFieldsSitAtSpecifiedOffsets() throws {
        let file = try Self.specContainer().encoded()
        #expect(slice(file, 0, 8) == BackupHeader.magic)
        #expect(slice(file, 8, 2) == hex("0100"))
        #expect(file[10] == 2 && file[11] == 0)
        #expect(slice(file, 12, 4) == hex("00000100"))
        #expect(slice(file, 16, 12) == hex(String(repeating: "c0", count: 12)))
        #expect(slice(file, 28, 32) == hex(String(repeating: "c1", count: 32)))
        // Password slot at 60.
        #expect(slice(file, 60, 4) == hex("01000000"))
        #expect(slice(file, 64, 12) == hex("00000100" + "03000000" + "01000000"))
        #expect(slice(file, 76, 16) == hex(String(repeating: "d0", count: 16)))
        #expect(slice(file, 92, 12) == hex(String(repeating: "d1", count: 12)))
        #expect(slice(file, 104, 32) == hex(String(repeating: "d2", count: 32)))
        #expect(slice(file, 136, 16) == hex(String(repeating: "d3", count: 16)))
        // Vault slot at 152; UUID bytes in the order uuidString prints them.
        #expect(slice(file, 152, 4) == hex("02000000"))
        #expect(slice(file, 156, 16) == hex("6F9619FF8B86D011B42D00C04FC964FF"))
        #expect(slice(file, 172, 16) == hex(String(repeating: "a0", count: 16)))
        #expect(slice(file, 188, 12) == hex("00000200" + "04000000" + "02000000"))
        #expect(slice(file, 200, 60) == hex(String(repeating: "b1", count: 60)))
        #expect(slice(file, 260, 60) == hex(String(repeating: "b2", count: 60)))
        #expect(slice(file, 320, 16) == hex(String(repeating: "e0", count: 16)))
        #expect(slice(file, 336, 12) == hex(String(repeating: "e1", count: 12)))
        #expect(slice(file, 348, 32) == hex(String(repeating: "e2", count: 32)))
        #expect(slice(file, 380, 16) == hex(String(repeating: "e3", count: 16)))
        #expect(file.count == 396 + 65_536 + 16)
        #expect(slice(file, 396 + 65_536, 16) == hex(String(repeating: "f0", count: 16)))
    }

    @Test func singleSlotHeadersHaveSpecifiedLengthsAndAAD() throws {
        let full = try Self.specContainer().header
        let password = try BackupHeader(payloadLength: 65_536, payloadNonce: full.payloadNonce, commitment: full.commitment,
                                        slots: [full.slots[0]])
        let vault = try BackupHeader(payloadLength: 65_536, payloadNonce: full.payloadNonce, commitment: full.commitment,
                                     slots: [full.slots[1]])
        #expect(password.encoded().count == 152)
        #expect(vault.encoded().count == 304)
        #expect(full.encoded().count == 396)

        let fixed = full.encoded().prefix(60)
        #expect(try full.slotAAD(at: 0) == fixed + Data([0]) + slice(full.encoded(), 60, 32))
        #expect(try full.slotAAD(at: 1) == fixed + Data([1]) + slice(full.encoded(), 152, 184))
        #expect(try vault.slotAAD(at: 0).count == 60 + 1 + 184)
        #expect(throws: BackupError.malformed) { try full.slotAAD(at: 2) }
    }

    // MARK: Container rejection

    @Test func truncatedOrExtendedFilesAreRejected() throws {
        let file = try Self.specContainer().encoded()
        for length in 0..<8 { #expect(throws: BackupError.notABackup) { try BackupContainer.parse(file.prefix(length)) } }
        for length in Array(8...400) + [file.count - 17, file.count - 16, file.count - 1] {
            #expect(throws: BackupError.malformed) { try BackupContainer.parse(file.prefix(length)) }
        }
        #expect(throws: BackupError.malformed) { try BackupContainer.parse(file + Data([0])) }
    }

    @Test func headerErrorsAreClassified() throws {
        let file = try Self.specContainer().encoded()
        #expect(throws: BackupError.notABackup) { try BackupContainer.parse(patched(file, at: 1, "42")) }
        #expect(throws: BackupError.unsupportedVersion) { try BackupContainer.parse(patched(file, at: 8, "0200")) }
        #expect(throws: BackupError.malformed) { try BackupContainer.parse(patched(file, at: 11, "01")) }
        #expect(throws: BackupError.malformed) { try BackupContainer.parse(patched(file, at: 10, "00")) }
        #expect(throws: BackupError.malformed) { try BackupContainer.parse(patched(file, at: 10, "03")) }
        #expect(throws: BackupError.malformed) { try BackupContainer.parse(patched(file, at: 61, "01")) }
        #expect(throws: BackupError.malformed) { try BackupContainer.parse(patched(file, at: 155, "01")) }
        #expect(throws: BackupError.malformed) { try BackupContainer.parse(patched(file, at: 60, "03")) }
        // Two password slots, and the two slot types in the wrong order.
        #expect(throws: BackupError.malformed) { try BackupContainer.parse(patched(file, at: 152, "01")) }
        #expect(throws: BackupError.malformed) { try BackupContainer.parse(patched(file, at: 60, "02")) }
        // Payload length must be a positive multiple of the padding block and match the file.
        #expect(throws: BackupError.malformed) { try BackupContainer.parse(patched(file, at: 12, "01000100")) }
        #expect(throws: BackupError.malformed) { try BackupContainer.parse(patched(file, at: 12, "00000000")) }
        #expect(throws: BackupError.malformed) { try BackupContainer.parse(patched(file, at: 12, "00000200")) }
        #expect(throws: BackupError.limitExceeded) { try BackupContainer.parse(patched(file, at: 12, "00000102")) }
        // KDF profiles outside the supported sets.
        #expect(throws: BackupError.unsupportedParameters) { try BackupContainer.parse(patched(file, at: 64, "00000200")) }
        #expect(throws: BackupError.unsupportedParameters) { try BackupContainer.parse(patched(file, at: 188, "00040000")) }
        #expect(throws: BackupError.limitExceeded) {
            try BackupContainer.parse(file + Data(count: BackupLimits.maxFileLength - file.count + 1))
        }
    }

    @Test func invalidHeadersCannotBeConstructed() throws {
        let full = try Self.specContainer().header
        func make(_ slots: [BackupSlot], nonce: Data? = nil, length: UInt32 = 65_536) throws -> BackupHeader {
            try BackupHeader(payloadLength: length, payloadNonce: nonce ?? full.payloadNonce, commitment: full.commitment, slots: slots)
        }
        #expect(throws: BackupError.malformed) { try make([]) }
        #expect(throws: BackupError.malformed) { try make([full.slots[1], full.slots[0]]) }
        #expect(throws: BackupError.malformed) { try make([full.slots[0], full.slots[0]]) }
        #expect(throws: BackupError.malformed) { try make(full.slots, nonce: Data(count: 11)) }
        #expect(throws: BackupError.malformed) { try make(full.slots, length: 65_535) }
        #expect(throws: BackupError.malformed) { try WrappedFileKey(nonce: Data(count: 12), ciphertext: Data(count: 31), tag: Data(count: 16)) }
    }

    // MARK: Payload

    @Test func payloadFieldsSitAtSpecifiedOffsets() throws {
        let data = try Self.specPayload().encoded()
        #expect(data.count == 65_536)
        #expect(slice(data, 0, 8) == hex("7BB427AEA1010000"))
        #expect(slice(data, 8, 4) == hex("01000000"))
        #expect(slice(data, 12, 16) == hex("6F9619FF8B86D011B42D00C04FC964FF"))
        #expect(slice(data, 28, 32) == hex(String(repeating: "99", count: 32)))
        #expect(slice(data, 76, 12) == hex("00000200" + "04000000" + "02000000"))
        #expect(slice(data, 208, 4) == hex("03000000"))
        // First record (0B…): no parents, 28-byte sealed revision.
        #expect(slice(data, 228, 16) == hex("0B000000000040008000000000000001"))
        #expect(slice(data, 244, 2) == hex("0000"))
        #expect(slice(data, 246, 4) == hex("1C000000"))
        // Third record (F0…): parents written in ascending byte order.
        #expect(slice(data, 404, 2) == hex("0200"))
        #expect(slice(data, 406, 16) == hex("0A000000000040008000000000000009"))
        #expect(slice(data, 422, 16) == hex("A0000000000040008000000000000002"))
        #expect(slice(data, 438, 4) == hex("21000000"))
        #expect(data[475...].allSatisfy { $0 == 0 })
    }

    @Test func payloadErrorsAreClassified() throws {
        let data = try Self.specPayload().encoded()
        func decode(_ offset: Int, _ bytes: String) throws { _ = try BackupPayload.decode(patched(data, at: offset, bytes)) }
        #expect(throws: BackupError.malformed) { try decode(8, "03000000") }            // unknown flag
        #expect(throws: BackupError.malformed) { try decode(7, "80") }                   // negative time
        #expect(throws: BackupError.malformed) { try decode(65_535, "01") }              // non-zero padding
        #expect(throws: BackupError.limitExceeded) { try decode(208, "A1860100") }       // 100001 revisions
        #expect(throws: BackupError.malformed) { try decode(208, "E8030000") }           // more than the bytes hold
        #expect(throws: BackupError.malformed) { try decode(228, String(repeating: "FF", count: 16)) }  // unsorted
        #expect(throws: BackupError.malformed) { try decode(228, "A0000000000040008000000000000002") }  // duplicate
        #expect(throws: BackupError.malformed) { try decode(312, "A0000000000040008000000000000002") }  // parent is self
        #expect(throws: BackupError.malformed) { try decode(406, "A0000000000040008000000000000002") }  // duplicate parent
        #expect(throws: BackupError.malformed) { try decode(406, String(repeating: "FF", count: 16)) }  // unsorted parents
        #expect(throws: BackupError.malformed) { try decode(246, "1B000000") }           // sealed below 28
        #expect(throws: BackupError.limitExceeded) { try decode(246, "E1930400") }       // sealed above 300000
        #expect(throws: BackupError.limitExceeded) { try decode(244, "E903") }           // 1001 parents
        #expect(throws: BackupError.unsupportedParameters) { try decode(76, "00040000") }
        #expect(throws: BackupError.malformed) { _ = try BackupPayload.decode(data.prefix(65_535)) }
        #expect(throws: BackupError.malformed) { _ = try BackupPayload.decode(Data()) }
        #expect(throws: BackupError.limitExceeded) { _ = try BackupPayload.decode(Data(count: BackupLimits.maxPayloadLength + 65_536)) }
        // Extra all-zero padding blocks remain valid.
        #expect(try BackupPayload.decode(data + Data(count: 65_536)) == (try Self.specPayload()))
    }

    @Test func payloadConstructionEnforcesInvariantsAndLimits() throws {
        let spec = try Self.spec(), header = Self.vaultHeader(spec), key = Data(count: 32)
        func revision(_ id: UUID = UUID(), vault: UUID? = nil, parents: [UUID] = [], size: Int = 28) -> EncryptedRevision {
            EncryptedRevision(vaultID: vault ?? header.vaultID, itemID: UUID(), id: id, parents: parents, ciphertext: Data(count: size))
        }
        func make(_ revisions: [EncryptedRevision], key: Data = key) throws -> BackupPayload {
            try BackupPayload(exportedAtMillis: 0, incompleteHistory: false, vaultKey: key, header: header, revisions: revisions)
        }
        let shared = UUID()
        #expect(throws: BackupError.malformed) { try make([], key: Data(count: 31)) }
        #expect(throws: BackupError.malformed) { try make([revision(vault: UUID())]) }
        #expect(throws: BackupError.malformed) { try make([revision(shared), revision(shared)]) }
        #expect(throws: BackupError.malformed) { try make([revision(shared, parents: [shared])]) }
        #expect(throws: BackupError.malformed) { try make([revision(size: 27)]) }
        #expect(throws: BackupError.limitExceeded) { try make([revision(size: 300_001)]) }
        #expect(throws: BackupError.limitExceeded) { try make([revision(parents: (0..<1_001).map { _ in UUID() })]) }
        #expect(throws: BackupError.malformed) {
            try BackupPayload(exportedAtMillis: -1, incompleteHistory: false, vaultKey: key, header: header, revisions: [])
        }

        let empty = try make([]).encoded()
        #expect(empty.count == 65_536)
        #expect(slice(empty, 208, 4) == hex("00000000"))
        // 112 records of 300000 bytes exceed the 32 MiB payload limit only after encoding.
        let large = (0..<112).map { _ in revision(size: 300_000) }
        #expect(throws: BackupError.limitExceeded) { try make(large).encoded() }
    }

    @Test func realRevisionsRoundTripWithIntactAuthenticatedData() async throws {
        let crypto = VaultCrypto()
        let created = try await crypto.create(password: "a unique master passphrase 2026")
        let first = try await crypto.encrypt(VaultItem(title: "First"), parents: [])
        var edited = VaultItem(title: "Edited"); edited.id = try await crypto.decrypt(first).id
        let second = try await crypto.encrypt(edited, parents: [first.id])
        let payload = try BackupPayload(exportedAtMillis: 1, incompleteHistory: false, vaultKey: try await crypto.deviceKey(),
                                        header: created.header, revisions: [second, first])
        let decoded = try BackupPayload.decode(try payload.encoded())
        #expect(decoded.header == created.header)
        #expect(Set(decoded.revisions.map(\.authenticatedData)) == Set([first, second].map(\.authenticatedData)))
        #expect(Set(decoded.revisions.map(\.id)) == Set([first.id, second.id]))
        let entries = try await crypto.entries(from: decoded.revisions)
        #expect(entries.map(\.item.title) == ["Edited"])
    }
}

private func hex(_ string: String) -> Data {
    var data = Data()
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        data.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return data
}

private func slice(_ data: Data, _ offset: Int, _ length: Int) -> Data {
    Data(data[data.startIndex + offset..<data.startIndex + offset + length])
}

private func patched(_ data: Data, at offset: Int, _ bytes: String) -> Data {
    var copy = data
    let replacement = hex(bytes)
    copy.replaceSubrange(offset..<offset + replacement.count, with: replacement)
    return copy
}

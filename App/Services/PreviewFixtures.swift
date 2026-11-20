#if DEBUG
    import AegisCore
    import Foundation

    /// Synthetic in-memory data for visual QA; never used by a release build or synchronized.
    enum PreviewFixtures {
        static var keychainDeleteFails: Bool {
            let arguments = ProcessInfo.processInfo.arguments
            return arguments.contains("--preview-vault") && arguments.contains("--preview-keychain-delete-failure")
        }

        static func passwordCSV() -> String? {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("--preview-vault") else { return nil }
            if arguments.contains("--preview-chrome-csv") {
                return "name,url,username,password,note\nCSV Alpha,https://alpha.example,first,synthetic-alpha,Test note\nCSV Beta,https://beta.example,second,synthetic-beta,"
            }
            if arguments.contains("--preview-onepassword-csv") {
                return "Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\nCSV Alpha,,first,synthetic-alpha,,true,false,work,Test note\nCSV Beta,https://beta.example,second,synthetic-beta,,false,false,,"
            }
            return nil
        }

        /// Exercises the actual decrypt/validate/select/commit flow using only an empty in-memory store.
        @MainActor static func importSelectionPreview(in session: VaultSession) async -> VaultSession.BackupImportPreview? {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("--preview-onboarding"), arguments.contains("--preview-import-selection"),
                  session.phase == .setup else { return nil }
            do {
                let source = VaultCrypto()
                let created = try await source.create(password: "Aegis preview fixture only")
                let items = [
                    VaultItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Apple", username: "fixture@example.com"),
                    VaultItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "GitHub", username: "fixture-user"),
                    VaultItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, kind: .note, title: "Import note"),
                ]
                var revisions: [EncryptedRevision] = []
                for item in items {
                    try await revisions.append(source.encrypt(item, parents: []))
                }
                let payload = try await BackupPayload(exportedAtMillis: 0, incompleteHistory: false,
                                                      vaultKey: source.deviceKey(), header: created.header, revisions: revisions)
                let data = try BackupCryptor.seal(payload, backupPassword: nil, includeVaultSlot: true)
                await source.lock()
                return try await session.previewBackup(BackupContainer.parse(data), credential: "Aegis preview fixture only", requireNewVault: true)
            } catch { session.error = error.localizedDescription; return nil }
        }

        static var items: [VaultItem] {
            if ProcessInfo.processInfo.arguments.contains("--preview-cards") {
                return cards
            }
            var card = VaultItem(kind: .card, title: L10n.text("preview.cardTitle"), notes: L10n.text("preview.cardNotes"))
            card.cardholder = "AEGIS DEMO"; card.cardNumber = "4242 4242 4242 4242"; card.expiry = "12/30"; card.securityCode = "123"
            card.cardBrand = .visa; card.cardType = .debit
            return [
                VaultItem(title: "Apple", username: "hello@example.com", password: "Preview-Only-Not-A-Credential", website: "https://apple.com", isFavorite: true),
                VaultItem(title: "GitHub", username: "aegis-demo", password: "Preview-Only-Not-A-Credential", website: "https://github.com", isFavorite: true),
                VaultItem(title: "Figma", username: "design@example.com", password: "Preview-Only-Not-A-Credential", website: "https://figma.com"),
                VaultItem(title: "Notion", username: "hello@example.com", password: "Preview-Only-Not-A-Credential", website: "https://notion.so"),
                VaultItem(title: "Linear", username: "work@example.com", password: "Preview-Only-Not-A-Credential", website: "https://linear.app"),
                card,
                VaultItem(kind: .note, title: L10n.text("preview.noteTitle"), notes: L10n.text("preview.noteBody")),
            ]
        }

        static var cards: [VaultItem] {
            CardBrand.allCases.flatMap { brand in
                PaymentCardType.allCases.map { type in
                    var card = VaultItem(kind: .card, title: brand.title + " · " + type.title)
                    card.cardBrand = brand; card.cardType = type
                    card.cardholder = "AEGIS DEMO"; card.expiry = "12/30"; card.securityCode = "123"
                    card.cardNumber = "4242424242424242"
                    return card
                }
            }
        }
    }
#endif

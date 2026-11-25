import AegisCore
import Foundation

/// Debounced, atomic publication of the AutoFill extension snapshot.
extension VaultSession {
    struct AutoFillVersion: Equatable {
        let vaultID: UUID
        let loginRevisions: Set<UUID>

        init(header: VaultHeader, entries: [VaultEntry]) {
            vaultID = header.vaultID
            loginRevisions = Set(entries.lazy.filter(AutoFillCredential.includes).map(\.id))
        }
    }

    var autoFillDirectory: URL? {
        guard !isPreview, !appGroup.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    func scheduleAutoFillSnapshot() {
        guard !replacingVault, unreadableRevisionCount == 0, let header, let directory = autoFillDirectory else { return }
        autoFillTask?.cancel()
        autoFillTask = nil
        let version = AutoFillVersion(header: header, entries: entries)
        guard shouldPublishAutoFill(version, directory: directory) else { return }
        let token = generation
        autoFillTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard let self, generation == token, phase == .unlocked else { return }
                defer {
                    if !Task.isCancelled {
                        autoFillTask = nil
                    }
                }
                try await publishAutoFillSnapshot(header: header, entries: entries, version: version, directory: directory)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                discardFailedAutoFillSnapshot(error, directory: directory)
            }
        }
    }

    func flushAutoFillSnapshot() async {
        guard let store, let directory = autoFillDirectory else { return }
        do {
            // A save may have committed just as the UI locked, before its refresh could finish.
            let snapshot = try await store.snapshot()
            let entries = try await crypto.cachedEntries(from: snapshot.revisions)
            let version = AutoFillVersion(header: snapshot.header, entries: entries)
            guard shouldPublishAutoFill(version, directory: directory) else { return }
            try await publishAutoFillSnapshot(header: snapshot.header, entries: entries, version: version, directory: directory)
        } catch {
            discardFailedAutoFillSnapshot(error, directory: directory)
        }
    }

    func shouldPublishAutoFill(_ version: AutoFillVersion, directory: URL) -> Bool {
        publishedAutoFill != version ||
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent(AutoFillSnapshot.filename).path)
    }

    func publishAutoFillSnapshot(header: VaultHeader, entries: [VaultEntry], version: AutoFillVersion, directory: URL) async throws {
        try Task.checkCancellation()
        let data = try await crypto.makeAutoFillSnapshot(header: header, entries: entries)
        try Task.checkCancellation()
        let url = directory.appendingPathComponent(AutoFillSnapshot.filename)
        #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: url, options: .atomic)
        #endif
        publishedAutoFill = version
    }

    func discardFailedAutoFillSnapshot(_ failure: Error, directory: URL) {
        publishedAutoFill = nil
        do {
            try removeAutoFillFile(AutoFillSnapshot.filename, from: directory)
            error = failure.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    func invalidateAutoFillSnapshot() throws {
        autoFillTask?.cancel()
        autoFillTask = nil
        publishedAutoFill = nil
        guard let directory = autoFillDirectory else { return }
        try removeAutoFillFile(AutoFillSnapshot.filename, from: directory)
    }

    func removeAutoFillFile(_ filename: String, from directory: URL) throws {
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
        } catch CocoaError.fileNoSuchFile {}
    }
}

import Foundation

// MARK: - Store files: location, protection and fail-closed purge
//
// Purge contract (per account, synchronous):
//   1. write a content-free marker file `<id>.purge` atomically (checked error),
//   2. rename every store file (`<id>.sqlite`, -wal, -shm, -journal) to a tombstone name, so it can
//      never be opened again as that account's store even if unlinking fails,
//   3. unlink tombstones and any remaining originals (logical unlink; SQLite secure_delete already
//      overwrote deleted rows inside the file — no physical flash erase is claimed),
//   4. remove the marker only when no original or tombstone remains.
// Opening an account store first completes any pending purge (marker, tombstones, or a failure seen
// earlier in this process) and fails closed while anything remains.

/// File operations the purge depends on; every failure is observed. Tests inject faults here.
protocol SGTasksCloudFileSystem: AnyObject {
    func fileExists(atPath path: String) -> Bool
    func createProtectedDirectory(at url: URL) throws
    func excludeFromBackup(_ url: URL) throws
    func writeAtomically(_ data: Data, toPath path: String) throws
    func moveItem(atPath source: String, toPath destination: String) throws
    func removeItem(atPath path: String) throws
    func contentsOfDirectory(atPath path: String) throws -> [String]
    func applyProtection(toPath path: String) throws
}

final class SGTasksCloudDefaultFileSystem: SGTasksCloudFileSystem {
    static let shared = SGTasksCloudDefaultFileSystem()

    private let fileManager = FileManager.default

    func fileExists(atPath path: String) -> Bool {
        return self.fileManager.fileExists(atPath: path)
    }

    func createProtectedDirectory(at url: URL) throws {
        #if os(iOS)
        try self.fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        #else
        try self.fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        #endif
    }

    func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try target.setResourceValues(values)
    }

    func writeAtomically(_ data: Data, toPath path: String) throws {
        #if os(iOS)
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        #endif
    }

    func moveItem(atPath source: String, toPath destination: String) throws {
        try self.fileManager.moveItem(atPath: source, toPath: destination)
    }

    func removeItem(atPath path: String) throws {
        try self.fileManager.removeItem(atPath: path)
    }

    func contentsOfDirectory(atPath path: String) throws -> [String] {
        return try self.fileManager.contentsOfDirectory(atPath: path)
    }

    func applyProtection(toPath path: String) throws {
        #if os(iOS)
        try self.fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
        #endif
    }
}

final class SGTasksCloudStoreFiles {
    private static let fileSuffixes = ["", "-wal", "-shm", "-journal"]

    let directory: URL
    private let fileSystem: SGTasksCloudFileSystem
    /// Accounts whose purge could not be completed in this process (even if no marker persisted).
    private var incompletePurges = Set<Int64>()

    init(directory: URL, fileSystem: SGTasksCloudFileSystem) {
        self.directory = directory
        self.fileSystem = fileSystem
    }

    /// `Application Support`, where every Tasks cloud root lives.
    static func applicationSupportBase() -> URL {
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    }

    /// The pre-origin root (`zenlygram-tasks-cloud`), written by builds before stores were scoped by
    /// backend origin. Never opened, read, copied or imported as a store: only an explicit logout purges
    /// an account from it.
    static func legacyDirectory(in base: URL) -> URL {
        return base.appendingPathComponent("zenlygram-tasks-cloud", isDirectory: true)
    }

    /// One backend origin's root: a SIBLING of the pre-origin root (never inside it, so neither
    /// directory's account scan sees the other's files), named by an opaque token
    /// (`SGEntitlementStoreScope.storageToken`) that neither reveals nor is parsed as the origin.
    static func originDirectory(in base: URL, originToken: String) -> URL {
        return base.appendingPathComponent("zenlygram-tasks-cloud.o-\(originToken)", isDirectory: true)
    }

    func path(accountPeerId: Int64) -> String {
        return self.directory.appendingPathComponent("\(accountPeerId).sqlite").path
    }

    private func markerPath(accountPeerId: Int64) -> String {
        return self.directory.appendingPathComponent("\(accountPeerId).purge").path
    }

    func storeExists(accountPeerId: Int64) -> Bool {
        return self.fileSystem.fileExists(atPath: self.path(accountPeerId: accountPeerId))
    }

    /// Background-sync-compatible protection class (the platform default the Tasks database also
    /// inherits), and excluded from device backups: the shadow is server-derived and another owner's
    /// shared cache must not outlive access loss inside a backup. Re-asserted on every open.
    func prepareDirectory() throws {
        if !self.fileSystem.fileExists(atPath: self.directory.path) {
            try self.fileSystem.createProtectedDirectory(at: self.directory)
        }
        try self.fileSystem.excludeFromBackup(self.directory)
    }

    func applyFileProtection(accountPeerId: Int64) throws {
        for suffix in Self.fileSuffixes {
            let path = self.path(accountPeerId: accountPeerId) + suffix
            if self.fileSystem.fileExists(atPath: path) {
                try self.fileSystem.applyProtection(toPath: path)
            }
        }
    }

    /// nil only when an existing directory cannot be listed (then nothing is assumed gone).
    private func names() -> [String]? {
        guard self.fileSystem.fileExists(atPath: self.directory.path) else { return [] }
        return try? self.fileSystem.contentsOfDirectory(atPath: self.directory.path)
    }

    private func tombstoneNames(accountPeerId: Int64) -> [String] {
        let prefix = "\(accountPeerId).purging-"
        return (self.names() ?? []).filter { $0.hasPrefix(prefix) }
    }

    /// A purge for this account is unfinished (persisted marker, leftover tombstone, or a failure
    /// observed in this process).
    func hasPendingPurge(accountPeerId: Int64) -> Bool {
        if self.incompletePurges.contains(accountPeerId) { return true }
        if self.fileSystem.fileExists(atPath: self.markerPath(accountPeerId: accountPeerId)) { return true }
        return !self.tombstoneNames(accountPeerId: accountPeerId).isEmpty
    }

    /// Removes every store file of the account. Returns true only when no original, tombstone or
    /// marker remains. Call with the account's connection already closed.
    @discardableResult
    func purge(accountPeerId: Int64) -> Bool {
        let markerPath = self.markerPath(accountPeerId: accountPeerId)
        var markerPresent = self.fileSystem.fileExists(atPath: markerPath)
        if !markerPresent {
            do {
                try self.fileSystem.writeAtomically(Data("\(accountPeerId)\n".utf8), toPath: markerPath)
                markerPresent = true
            } catch {
                // No durable marker: fall through to rename/unlink, which still protect the account;
                // an incomplete outcome is remembered for this process below.
                markerPresent = false
            }
        }
        let token = UUID().uuidString.lowercased()
        for suffix in Self.fileSuffixes {
            let original = self.path(accountPeerId: accountPeerId) + suffix
            guard self.fileSystem.fileExists(atPath: original) else { continue }
            let tombstone = self.directory.appendingPathComponent("\(accountPeerId).purging-\(token)\(suffix)").path
            do {
                try self.fileSystem.moveItem(atPath: original, toPath: tombstone)
            } catch {
                // Still try to unlink the original in place below.
            }
        }
        for name in self.tombstoneNames(accountPeerId: accountPeerId) {
            try? self.fileSystem.removeItem(atPath: self.directory.appendingPathComponent(name).path)
        }
        for suffix in Self.fileSuffixes {
            let original = self.path(accountPeerId: accountPeerId) + suffix
            if self.fileSystem.fileExists(atPath: original) {
                try? self.fileSystem.removeItem(atPath: original)
            }
        }
        // Success is decided only by observing what remains, never by the calls above.
        let originalsRemain = Self.fileSuffixes.contains { self.fileSystem.fileExists(atPath: self.path(accountPeerId: accountPeerId) + $0) }
        let tombstonesRemain = !self.tombstoneNames(accountPeerId: accountPeerId).isEmpty
        let filesGone = !originalsRemain && !tombstonesRemain && self.names() != nil
        if filesGone && markerPresent {
            try? self.fileSystem.removeItem(atPath: markerPath)
        }
        let complete = filesGone && !self.fileSystem.fileExists(atPath: markerPath)
        if complete {
            self.incompletePurges.remove(accountPeerId)
        } else {
            self.incompletePurges.insert(accountPeerId)
        }
        return complete
    }

    /// Account peer ids with any file here (store, WAL, tombstone or purge marker).
    func storedAccountPeerIds() -> Set<Int64>? {
        guard let names = self.names() else { return nil }
        var out = Set<Int64>()
        for name in names {
            let digits = name.prefix { $0 == "-" || $0.isNumber }
            guard !digits.isEmpty, let id = Int64(digits), name.dropFirst(digits.count).hasPrefix(".") else { continue }
            out.insert(id)
        }
        return out.union(self.incompletePurges)
    }
}

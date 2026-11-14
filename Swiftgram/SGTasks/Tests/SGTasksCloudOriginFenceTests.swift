import Foundation

/// Zenlygram — the Tasks cloud store's origin fence, on real files in a temporary Application Support
/// stand-in. Each backend origin gets its own SIBLING directory named by an opaque token, so:
/// - a new origin starts with no store even when the pre-origin root holds one for the same account
///   (old cloud data is never opened or imported);
/// - the per-directory account scanner never sees, parses or reports the other root's files;
/// - an origin's purge never touches the pre-origin root or another origin;
/// - the pre-origin root is removed only by an explicit per-account purge of THAT root, and only for
///   the account named.
@main
struct SGTasksCloudOriginFenceTests {
    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    private static let tokenA = String(repeating: "a1", count: 32)
    private static let tokenB = String(repeating: "b2", count: 32)

    static func main() throws {
        try self.originDirectoriesAreOpaqueSiblingsOfThePreOriginRoot()
        try self.aNewOriginNeverSeesThePreOriginStore()
        try self.anOriginPurgeNeverReachesAnotherRoot()
        try self.anExplicitPreOriginPurgeRemovesOnlyTheNamedAccount()
        print("SGTasksCloudStoreFiles origin fence: all checks passed")
    }

    private static func withBase(_ body: (URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("zenlygram-tasks-origin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: base)
        }
        try body(base)
    }

    private static func files(_ directory: URL) -> SGTasksCloudStoreFiles {
        return SGTasksCloudStoreFiles(directory: directory, fileSystem: SGTasksCloudDefaultFileSystem.shared)
    }

    /// A store as an earlier build left it: the database plus its WAL.
    private static func writeStore(_ files: SGTasksCloudStoreFiles, accountPeerId: Int64, contents: String) throws -> [String: Data] {
        try files.prepareDirectory()
        var written: [String: Data] = [:]
        for suffix in ["", "-wal"] {
            let path = files.path(accountPeerId: accountPeerId) + suffix
            let data = Data("\(contents)\(suffix)".utf8)
            try data.write(to: URL(fileURLWithPath: path))
            written[path] = data
        }
        return written
    }

    private static func snapshot(_ directory: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let path = directory.appendingPathComponent(name).path
            out[path] = FileManager.default.contents(atPath: path)
        }
        return out
    }

    private static func originDirectoriesAreOpaqueSiblingsOfThePreOriginRoot() throws {
        try self.withBase { base in
            let legacy = SGTasksCloudStoreFiles.legacyDirectory(in: base)
            let a = SGTasksCloudStoreFiles.originDirectory(in: base, originToken: tokenA)
            let b = SGTasksCloudStoreFiles.originDirectory(in: base, originToken: tokenB)
            check(legacy.lastPathComponent == "zenlygram-tasks-cloud", "the pre-origin root moved: \(legacy.path)")
            check(a.lastPathComponent == "zenlygram-tasks-cloud.o-\(tokenA)", "unexpected origin directory \(a.lastPathComponent)")
            for directory in [a, b] {
                check(directory.deletingLastPathComponent().standardizedFileURL == legacy.deletingLastPathComponent().standardizedFileURL, "an origin directory is not a sibling of the pre-origin root")
                check(!directory.standardizedFileURL.path.hasPrefix(legacy.standardizedFileURL.path + "/"), "an origin directory sits inside the pre-origin root")
            }
            check(a != b && a != legacy, "two roots share a directory")
            check(SGTasksCloudStoreFiles.originDirectory(in: base, originToken: tokenA) == a, "the origin directory is not stable")
            check(SGTasksCloudStoreFiles.applicationSupportBase().lastPathComponent == "Application Support", "unexpected base \(SGTasksCloudStoreFiles.applicationSupportBase().path)")
        }
    }

    private static func aNewOriginNeverSeesThePreOriginStore() throws {
        try self.withBase { base in
            let legacy = self.files(SGTasksCloudStoreFiles.legacyDirectory(in: base))
            _ = try self.writeStore(legacy, accountPeerId: 42, contents: "legacy-com-shadow")
            let before = self.snapshot(legacy.directory)
            let a = self.files(SGTasksCloudStoreFiles.originDirectory(in: base, originToken: tokenA))
            check(!a.storeExists(accountPeerId: 42), "the new origin would open the pre-origin store")
            check(!a.hasPendingPurge(accountPeerId: 42), "the new origin inherited a purge state")
            check(a.storedAccountPeerIds() == [], "the new origin's scanner reported the pre-origin root")
            try a.prepareDirectory()
            check(a.storedAccountPeerIds() == [], "an empty origin directory reported accounts")
            check(self.snapshot(legacy.directory) == before, "opening a new origin touched the pre-origin root")
            check(legacy.storedAccountPeerIds() == [42], "the pre-origin scanner saw an origin directory")
        }
    }

    private static func anOriginPurgeNeverReachesAnotherRoot() throws {
        try self.withBase { base in
            let legacy = self.files(SGTasksCloudStoreFiles.legacyDirectory(in: base))
            let a = self.files(SGTasksCloudStoreFiles.originDirectory(in: base, originToken: tokenA))
            let b = self.files(SGTasksCloudStoreFiles.originDirectory(in: base, originToken: tokenB))
            _ = try self.writeStore(legacy, accountPeerId: 42, contents: "legacy")
            _ = try self.writeStore(a, accountPeerId: 42, contents: "origin-a")
            _ = try self.writeStore(b, accountPeerId: 42, contents: "origin-b")
            let legacyBefore = self.snapshot(legacy.directory)
            let bBefore = self.snapshot(b.directory)
            check(a.purge(accountPeerId: 42), "the origin purge did not complete")
            check(!a.storeExists(accountPeerId: 42) && a.storedAccountPeerIds() == [], "the origin purge left files")
            check(self.snapshot(legacy.directory) == legacyBefore, "an origin purge reached the pre-origin root")
            check(self.snapshot(b.directory) == bBefore, "an origin purge reached another origin")
        }
    }

    private static func anExplicitPreOriginPurgeRemovesOnlyTheNamedAccount() throws {
        try self.withBase { base in
            let legacy = self.files(SGTasksCloudStoreFiles.legacyDirectory(in: base))
            let a = self.files(SGTasksCloudStoreFiles.originDirectory(in: base, originToken: tokenA))
            _ = try self.writeStore(legacy, accountPeerId: 42, contents: "signed-out")
            let kept = try self.writeStore(legacy, accountPeerId: 43, contents: "still-signed-in")
            _ = try self.writeStore(a, accountPeerId: 42, contents: "origin-a")
            let aBefore = self.snapshot(a.directory)
            check(legacy.purge(accountPeerId: 42), "the explicit pre-origin purge did not complete")
            check(!legacy.storeExists(accountPeerId: 42), "the signed-out account's pre-origin store survived its logout")
            check(legacy.storedAccountPeerIds() == [43], "the explicit purge reached another account")
            for (path, data) in kept {
                check(FileManager.default.contents(atPath: path) == data, "another account's pre-origin file changed: \(path)")
            }
            check(self.snapshot(a.directory) == aBefore, "the pre-origin purge reached the origin directory")
        }
    }
}

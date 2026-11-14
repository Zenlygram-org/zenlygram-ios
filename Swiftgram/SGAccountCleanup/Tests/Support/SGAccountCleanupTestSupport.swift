import Foundation

var sgCleanupTestChecks = 0

func check(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    sgCleanupTestChecks += 1
    if !condition {
        print("FAIL \(file):\(line): \(message())")
        exit(1)
    }
}

/// In-memory Keychain and defaults over real temporary directories (two roots, like Application
/// Support and the app-group container).
final class TestStorage: SGFeatureStorage {
    private let lock = NSLock()
    private var keychain: [String: Set<String>] = [:]
    private var defaults: [String: String] = [:]
    var keychainReadable = true
    let rootURLs: [URL]

    init() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sgcleanup-\(UUID().uuidString)", isDirectory: true)
        self.rootURLs = [
            base.appendingPathComponent("support", isDirectory: true),
            base.appendingPathComponent("group", isDirectory: true),
        ]
        for root in self.rootURLs {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    deinit {
        if let base = self.rootURLs.first?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: base)
        }
    }

    // MARK: Fixture

    func addKeychain(_ accounts: [String], service: String = SGFeatureStorageCleanup.keychainService) {
        self.lock.lock()
        self.keychain[service, default: []].formUnion(accounts)
        self.lock.unlock()
    }

    func keychain(service: String = SGFeatureStorageCleanup.keychainService) -> Set<String> {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.keychain[service] ?? []
    }

    func addDefaults(_ keys: [String]) {
        self.lock.lock()
        for key in keys {
            self.defaults[key] = "x"
        }
        self.lock.unlock()
    }

    var defaultsKeySet: Set<String> {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return Set(self.defaults.keys)
    }

    /// Creates `root[rootIndex]/<path>` as a directory holding one file.
    func addFolder(_ path: String, root rootIndex: Int = 0) {
        let url = self.rootURLs[rootIndex].appendingPathComponent(path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: url.appendingPathComponent("data.json"))
    }

    func exists(_ path: String, root rootIndex: Int = 0) -> Bool {
        return FileManager.default.fileExists(atPath: self.rootURLs[rootIndex].appendingPathComponent(path).path)
    }

    // MARK: SGFeatureStorage

    func keychainAccounts(service: String) -> [String]? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        guard self.keychainReadable else {
            return nil
        }
        return Array(self.keychain[service] ?? [])
    }

    func deleteKeychainItem(service: String, account: String) {
        self.lock.lock()
        self.keychain[service]?.remove(account)
        self.lock.unlock()
    }

    func roots() -> [URL] {
        return self.rootURLs
    }

    func children(of directory: URL) -> [URL]? {
        return try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    func removeItem(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func defaultsKeys() -> [String] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return Array(self.defaults.keys)
    }

    func removeDefault(forKey key: String) {
        self.lock.lock()
        self.defaults.removeValue(forKey: key)
        self.lock.unlock()
    }
}

/// Records the hook calls and what the Keychain held at that moment.
actor HookRecorder {
    private(set) var calls: [Int64] = []
    private(set) var keychainAtCall: [Int64: Set<String>] = [:]

    func record(_ accountPeerId: Int64, keychain: Set<String>) {
        self.calls.append(accountPeerId)
        self.keychainAtCall[accountPeerId] = keychain
    }
}

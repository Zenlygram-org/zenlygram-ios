import Foundation
import TelegramCore

// Loads the bundled Webshare proxy list (one `host:port:username:password` per line, `#` comments
// allowed) and returns it as SOCKS5 proxy servers in randomized order, so each launch spreads load
// across the pool and starts from a different candidate.
enum SGProxyPool {
    // Parsed once per process and cached: the bundled list only changes with an app update, and
    // both the UI availability gates and the probe/selection paths ask repeatedly. `static let`
    // initialization is lazy and thread-safe.
    private static let servers: [ProxyServerSettings] = SGProxyPool.parseBundledList()

    // True when the bundled list has no valid entries (e.g. it still ships as a placeholder).
    // Callers use this to keep the whole Auto Proxy feature dormant.
    static var isEmpty: Bool {
        return self.servers.isEmpty
    }

    static func loadShuffled() -> [ProxyServerSettings] {
        return self.servers.shuffled()
    }

    private static func parseBundledList() -> [ProxyServerSettings] {
        guard let text = self.loadBundledText() else {
            return []
        }
        var servers: [ProxyServerSettings] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            let components = line.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            if components.count != 4 {
                continue
            }
            let host = components[0]
            guard !host.isEmpty, let port = Int32(components[1]), port > 0, port <= 65535 else {
                continue
            }
            let username = components[2]
            let password = components[3]
            servers.append(ProxyServerSettings(host: host, port: port, connection: .socks5(username: username, password: password)))
        }
        return servers
    }

    private static func loadBundledText() -> String? {
        let moduleBundle = Bundle(for: SGAutoProxyManager.self)
        guard let bundlePath = moduleBundle.path(forResource: "SGAutoProxyResources", ofType: "bundle"),
              let resourceBundle = Bundle(path: bundlePath),
              let filePath = resourceBundle.path(forResource: "proxies", ofType: "txt"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

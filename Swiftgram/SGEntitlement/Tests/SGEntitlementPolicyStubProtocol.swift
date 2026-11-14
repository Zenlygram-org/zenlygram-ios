import Foundation

/// Zenlygram — a scripted HTTP origin for the policy transport tests.
///
/// Served through `URLProtocol`, so the REAL `URLSession` delegate path runs — response, per-chunk
/// `didReceive data`, the redirect hook and cancellation — with no network, no ATS and no server
/// process. Routes are keyed by host, or by `host + path` (`"policy.zenlygram.test/v1/app-policy"`)
/// when one origin must answer its two policy endpoints differently; the path-keyed route wins.
/// Chunks are delivered one at a time on the loading thread's run loop, `chunkInterval` apart, and
/// delivery stops as soon as the session cancels the load, so `deliveredChunks` shows whether a body
/// was cut off WHILE it was arriving.
final class SGPolicyStubProtocol: URLProtocol {
    struct Route {
        var status: Int = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        var chunkInterval: TimeInterval = 0.02
        /// Answer with `status` (a 3xx) and `Location: redirectTo` instead of a body.
        var redirectTo: URL?
    }

    private static let lock = NSLock()
    private static var routes: [String: Route] = [:]
    private static var recorded: [URLRequest] = []
    private static var delivered = 0

    static func reset(routes: [String: Route]) {
        self.lock.lock()
        self.routes = routes
        self.recorded = []
        self.delivered = 0
        self.lock.unlock()
    }

    /// Every request that reached the origin, in order.
    static var requests: [URLRequest] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.recorded
    }

    static var deliveredChunks: Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.delivered
    }

    // Touched only on the loading thread's run loop (startLoading / stopLoading / scheduled blocks).
    private var isStopped = false
    private var runLoop: CFRunLoop?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        self.runLoop = CFRunLoopGetCurrent()
        let request = self.request
        SGPolicyStubProtocol.lock.lock()
        SGPolicyStubProtocol.recorded.append(request)
        let route = request.url.flatMap { url -> Route? in
            guard let host = url.host else {
                return nil
            }
            return SGPolicyStubProtocol.routes["\(host)\(url.path)"] ?? SGPolicyStubProtocol.routes[host]
        }
        SGPolicyStubProtocol.lock.unlock()

        guard let route, let url = request.url else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        if let target = route.redirectTo {
            var headers = route.headers
            headers["Location"] = target.absoluteString
            let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            self.client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            // A refused redirect makes the 3xx itself the answer; a followed one has already
            // cancelled this load, and these calls go nowhere.
            guard !self.isStopped else {
                return
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: route.headers)!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.deliver(route.chunks, index: 0, interval: route.chunkInterval)
    }

    override func stopLoading() {
        self.isStopped = true
    }

    private func deliver(_ chunks: [Data], index: Int, interval: TimeInterval) {
        self.later(interval) { [weak self] in
            guard let self, !self.isStopped else {
                return
            }
            guard index < chunks.count else {
                self.client?.urlProtocolDidFinishLoading(self)
                return
            }
            SGPolicyStubProtocol.lock.lock()
            SGPolicyStubProtocol.delivered += 1
            SGPolicyStubProtocol.lock.unlock()
            self.client?.urlProtocol(self, didLoad: chunks[index])
            self.deliver(chunks, index: index + 1, interval: interval)
        }
    }

    /// Runs `block` on the loading thread's run loop after `delay`: `URLProtocolClient` is called on
    /// the thread that started the load, never from a background queue.
    private func later(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        guard let runLoop = self.runLoop else {
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
            CFRunLoopWakeUp(runLoop)
        }
    }
}

extension SGPolicyStubProtocol {
    /// `count` chunks of `size` bytes each.
    static func chunks(_ count: Int, of size: Int) -> [Data] {
        return Array(repeating: Data(repeating: 0x41, count: size), count: count)
    }

    static func json(_ object: [String: Any]) -> Data {
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

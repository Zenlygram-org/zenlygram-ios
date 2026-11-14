import Foundation

/// Zenlygram — a scripted HTTP origin keyed by URL PATH (`/v1/profile/consents`, `/v1/health`, …),
/// for the customer-data and client tests.
///
/// Served through `URLProtocol`, like `SGPolicyStubProtocol`, so the REAL `URLSession` path runs —
/// response, body delivery, the redirect hook — with no network, no ATS and no server process. Each
/// path holds a FIFO of answers and every request to it takes the next one; a path with none left,
/// or never scripted, fails with `cannotConnectToHost`, so nothing unexpected passes silently. The
/// body a request carried is captured from `httpBodyStream`, which is what `URLSession` hands a
/// protocol in place of `httpBody`.
final class SGEntitlementPathStubProtocol: URLProtocol {
    struct Response {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data()
        /// Answer with `status` (a 3xx) and `Location: redirectTo` instead of a body.
        var redirectTo: URL?
        /// Runs on the loading thread once this answer was taken from the script, before it is
        /// delivered: what changes while the request is in flight.
        var onServe: (() -> Void)?

        init(status: Int = 200, headers: [String: String] = ["Content-Type": "application/json"], body: Data = Data(), redirectTo: URL? = nil) {
            self.status = status
            self.headers = headers
            self.body = body
            self.redirectTo = redirectTo
        }

        static func json(_ status: Int, _ object: [String: Any], headers: [String: String] = [:]) -> Response {
            var merged = ["Content-Type": "application/json"]
            for (name, value) in headers {
                merged[name] = value
            }
            return Response(status: status, headers: merged, body: SGEntitlementPathStubProtocol.json(object))
        }
    }

    struct Recorded {
        let request: URLRequest
        /// The bytes the request carried (`httpBody` or the drained `httpBodyStream`); nil without one.
        let body: Data?

        var path: String {
            return self.request.url?.path ?? ""
        }
    }

    private static let lock = NSLock()
    private static var responses: [String: [Response]] = [:]
    private static var recordedRequests: [Recorded] = []

    /// Replaces the script: `path` → its answers, in order.
    static func reset(_ responses: [String: [Response]] = [:]) {
        self.lock.lock()
        self.responses = responses
        self.recordedRequests = []
        self.lock.unlock()
    }

    static func enqueue(_ path: String, _ response: Response) {
        self.lock.lock()
        self.responses[path, default: []].append(response)
        self.lock.unlock()
    }

    /// Every request that reached the origin, in order.
    static var recorded: [Recorded] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.recordedRequests
    }

    static func recorded(path: String) -> [Recorded] {
        return self.recorded.filter { $0.path == path }
    }

    // Touched only on the loading thread (startLoading / stopLoading).
    private var isStopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let request = self.request
        let body = SGEntitlementPathStubProtocol.bodyData(of: request)
        let path = request.url?.path ?? ""
        SGEntitlementPathStubProtocol.lock.lock()
        SGEntitlementPathStubProtocol.recordedRequests.append(Recorded(request: request, body: body))
        var response: Response?
        if var queue = SGEntitlementPathStubProtocol.responses[path], !queue.isEmpty {
            response = queue.removeFirst()
            SGEntitlementPathStubProtocol.responses[path] = queue
        }
        SGEntitlementPathStubProtocol.lock.unlock()

        guard let response, let url = request.url else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        response.onServe?()
        if let target = response.redirectTo {
            var headers = response.headers
            headers["Location"] = target.absoluteString
            let redirect = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            self.client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
            // A refused redirect makes the 3xx itself the answer; a followed one has already
            // cancelled this load, and these calls go nowhere.
            guard !self.isStopped else {
                return
            }
            self.client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocolDidFinishLoading(self)
            return
        }
        let answer = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        self.client?.urlProtocol(self, didReceive: answer, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty {
            self.client?.urlProtocol(self, didLoad: response.body)
        }
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        self.isStopped = true
    }

    /// `httpBody`, or everything `httpBodyStream` yields.
    static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer {
            stream.close()
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }

    static func json(_ object: [String: Any]) -> Data {
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

import Foundation

/// Zenlygram — one GET whose response body is bounded while it is received.
///
/// A private ephemeral session per request with a serial delegate queue: the body is accumulated by
/// the delegate and the task is cancelled the moment it would pass `limit` — counted as the bytes
/// arrive, never taken from `Content-Length` (a declared length over the limit only refuses
/// earlier). Redirects are refused, so a 3xx is itself the answer and no request ever leaves for
/// another host. The session is invalidated as soon as the task is started, which releases the
/// delegate when the task ends.
///
/// `timeout` is the idle timeout of the request; the whole exchange is bounded at twice that
/// (`timeoutIntervalForResource`). No cookies, no URL cache.
///
/// Foundation only, so the guarantees are exercised on the host (`Tests/run-policy-core-tests.sh`).
enum SGEntitlementBoundedFetch {
    /// `protocolClasses` is nil in the app; tests pass a scripted `URLProtocol` origin.
    static func perform(_ request: URLRequest, timeout: TimeInterval, limit: Int, protocolClasses: [AnyClass]? = nil) async -> Result<(Int, Data), SGEntitlementFailureClass> {
        return await withCheckedContinuation { continuation in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout * 2.0
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            if let protocolClasses {
                configuration.protocolClasses = protocolClasses
            }
            let delegate = Delegate(limit: limit, completion: { result in
                continuation.resume(returning: result)
            })
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
            session.dataTask(with: request).resume()
            session.finishTasksAndInvalidate()
        }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate {
        private let limit: Int
        // Touched only on the session's serial delegate queue.
        private var body = Data()
        private var exceededLimit = false
        private var completion: ((Result<(Int, Data), SGEntitlementFailureClass>) -> Void)?

        init(limit: Int, completion: @escaping (Result<(Int, Data), SGEntitlementFailureClass>) -> Void) {
            self.limit = limit
            self.completion = completion
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if response.expectedContentLength > Int64(self.limit) {
                self.exceededLimit = true
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !self.exceededLimit else {
                return
            }
            guard self.body.count + data.count <= self.limit else {
                self.exceededLimit = true
                self.body = Data()
                dataTask.cancel()
                return
            }
            self.body.append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let result: Result<(Int, Data), SGEntitlementFailureClass>
            if self.exceededLimit {
                result = .failure(.offline(.malformedResponse))
            } else if let error {
                result = .failure(SGEntitlementFailureMapping.classify(urlErrorCode: (error as? URLError)?.code ?? .unknown))
            } else if let http = task.response as? HTTPURLResponse {
                result = .success((http.statusCode, self.body))
            } else {
                result = .failure(.offline(.malformedResponse))
            }
            let completion = self.completion
            self.completion = nil
            completion?(result)
        }
    }
}

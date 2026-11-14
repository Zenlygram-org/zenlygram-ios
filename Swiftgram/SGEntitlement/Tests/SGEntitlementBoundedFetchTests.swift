import XCTest
@testable import SGEntitlement

/// Zenlygram — the policy transport's own guarantees, through the REAL `URLSession` delegate path
/// (`SGPolicyStubProtocol` serves a scripted origin): the 16 KiB bound applies WHILE the body
/// arrives, a declared length is never trusted in place of counting, and no redirect is followed.
final class SGEntitlementBoundedFetchTests: XCTestCase {
    private let limit = 16384
    private let host = "policy.zenlygram.test"
    private var origin: URL {
        return URL(string: "https://\(self.host)/v1/monetization")!
    }

    override func setUp() {
        super.setUp()
        SGPolicyStubProtocol.reset(routes: [:])
    }

    override func tearDown() {
        SGPolicyStubProtocol.reset(routes: [:])
        super.tearDown()
    }

    private func serve(_ route: SGPolicyStubProtocol.Route, at host: String? = nil) {
        SGPolicyStubProtocol.reset(routes: [host ?? self.host: route])
    }

    private func fetch() async -> Result<(Int, Data), SGEntitlementFailureClass> {
        return await SGEntitlementBoundedFetch.perform(URLRequest(url: self.origin), timeout: 5, limit: self.limit, protocolClasses: [SGPolicyStubProtocol.self])
    }

    func test_aBodyOfExactlyTheLimitStreamedInChunksIsAccepted() async {
        self.serve(SGPolicyStubProtocol.Route(chunks: SGPolicyStubProtocol.chunks(4, of: 4096)))
        guard case let .success((status, data)) = await self.fetch() else {
            return XCTFail("16384 bytes is within the contract's 16 KiB")
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(data.count, self.limit)
    }

    func test_oneByteOverTheLimitIsRefused() async {
        self.serve(SGPolicyStubProtocol.Route(chunks: SGPolicyStubProtocol.chunks(4, of: 4096) + [Data([0x41])]))
        guard case .failure = await self.fetch() else {
            return XCTFail("16385 bytes must not be handed to the verifier")
        }
    }

    func test_anOversizedBodyIsCutOffWhileItArrives() async {
        let chunks = SGPolicyStubProtocol.chunks(16, of: 4096)
        self.serve(SGPolicyStubProtocol.Route(chunks: chunks, chunkInterval: 0.03))
        guard case .failure = await self.fetch() else {
            return XCTFail("a 64 KiB body must be refused")
        }
        XCTAssertLessThan(SGPolicyStubProtocol.deliveredChunks, chunks.count, "the load must be cancelled during the stream, not after buffering all of it")
    }

    func test_aSmallDeclaredLengthIsNotTrusted() async {
        let chunks = SGPolicyStubProtocol.chunks(8, of: 4096)
        self.serve(SGPolicyStubProtocol.Route(headers: ["Content-Length": "64"], chunks: chunks))
        guard case .failure = await self.fetch() else {
            return XCTFail("bytes are counted as they arrive; Content-Length is not the bound")
        }
        XCTAssertLessThan(SGPolicyStubProtocol.deliveredChunks, chunks.count)
    }

    func test_aDeclaredLengthOverTheLimitIsRefusedBeforeTheBody() async {
        let chunks = SGPolicyStubProtocol.chunks(5, of: 4096)
        self.serve(SGPolicyStubProtocol.Route(headers: ["Content-Length": "20000"], chunks: chunks, chunkInterval: 0.1))
        guard case .failure = await self.fetch() else {
            return XCTFail("a declared 20000-byte body is over the bound")
        }
        XCTAssertLessThan(SGPolicyStubProtocol.deliveredChunks, chunks.count)
    }

    func test_aRedirectIsNeverFollowed() async {
        let elsewhere = "elsewhere.zenlygram.test"
        SGPolicyStubProtocol.reset(routes: [
            self.host: SGPolicyStubProtocol.Route(status: 302, redirectTo: URL(string: "https://\(elsewhere)/v1/monetization")!),
            elsewhere: SGPolicyStubProtocol.Route(chunks: [SGPolicyStubProtocol.json(["policy_token": "x"])])
        ])
        let result = await self.fetch()
        if case let .success((status, _)) = result {
            XCTAssertFalse((200 ..< 300).contains(status), "the redirect target answered: the redirect was followed")
        }
        XCTAssertEqual(SGPolicyStubProtocol.requests.compactMap { $0.url?.host }, [self.host], "no request may leave for the redirect's host")
    }
}

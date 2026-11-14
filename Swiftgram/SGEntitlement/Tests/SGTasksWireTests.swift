import XCTest
@testable import SGEntitlement

/// Zenlygram — the Tasks wire codec against the normative R3 business-hash vectors
/// (`zenlygram-tasks-business-hash-vectors-v1-r3.json`, wire sha256 377a4c1d…), the R4 vectors
/// (`B/tests/Fixtures/tasks-r4/vectors.json` = `tasks-sync.json` `x-r4-vectors`, copied inline) and
/// the strict parsing / validation / classification edges the wire requires.
final class SGTasksWireTests: XCTestCase {
    private let principal = "01arz3ndektsv4rrffq69g5fav"

    private func uuid(_ raw: String) -> SGTasksWire.UUID {
        return SGTasksWire.UUID(raw)!
    }

    private func data(_ text: String) -> Data {
        return Data(text.utf8)
    }

    // MARK: - Normative vectors

    func test_vectorListCreate() throws {
        let request = try SGTasksWire.MutationRequest(mutationId: self.uuid("11111111-1111-4111-8111-111111111111"), operation: .listCreate(SGTasksWire.ListCreate(
            listId: self.uuid("22222222-2222-4222-8222-222222222222"), title: "Ishlar", sortOrder: 0, createdAt: nil
        )))
        let bytes = request.canonicalBusinessBytes(principal: self.principal)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), #"["zenlygram-tasks-business-v1","01arz3ndektsv4rrffq69g5fav","11111111-1111-4111-8111-111111111111","list.create",["22222222-2222-4222-8222-222222222222","Ishlar",0,null]]"#)
        XCTAssertEqual(bytes.count, 170)
        XCTAssertEqual(request.businessHash(principal: self.principal), "c6d73bb69d9db2ec2dcbbfd91acfd21c312fba3c49025a9f7dc27c595d37e862")
        XCTAssertEqual(String(decoding: request.wireJSON, as: UTF8.self), #"{"schema_version":1,"mutation_id":"11111111-1111-4111-8111-111111111111","operation":{"kind":"list.create","list_id":"22222222-2222-4222-8222-222222222222","title":"Ishlar","sort_order":0,"created_at":null}}"#)
    }

    func test_vectorUnicodeTaskCreate() throws {
        let content = SGTasksWire.Content(
            listId: nil,
            title: "Hisobot / O‘zbekiston",
            // The normative vector separates "Keyingi" and "qator" with U+2028 LINE SEPARATOR (3 UTF-8
            // bytes), not a space; the canonical encoding carries it raw, unescaped.
            description: "“Tayyor”\nKeyingi\u{2028}qator",
            dueAt: 1792512000,
            priority: 2,
            sortOrder: -1,
            annotation: SGTasksWire.Annotation(telegramUserId: SGTasksWire.TelegramId("123456789")!, displayName: "Ali")
        )
        let request = try SGTasksWire.MutationRequest(mutationId: self.uuid("44444444-4444-4444-8444-444444444444"), operation: .taskCreate(SGTasksWire.TaskCreate(
            taskId: self.uuid("33333333-3333-4333-8333-333333333333"), content: content, createdAt: nil, isCompleted: false, completedAt: nil
        )))
        let bytes = request.canonicalBusinessBytes(principal: self.principal)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), #"["zenlygram-tasks-business-v1","01arz3ndektsv4rrffq69g5fav","44444444-4444-4444-8444-444444444444","task.create",["33333333-3333-4333-8333-333333333333",[null,"Hisobot / O‘zbekiston","“Tayyor”\nKeyingi\#u{2028}qator",1792512000,2,-1,["123456789","Ali"]],null,false,null]]"#)
        XCTAssertEqual(bytes.count, 271)
        XCTAssertEqual(request.businessHash(principal: self.principal), "45c2f4005d98a0c1d9af316a8643f616703caa6dfe8de0287450feb6c5881ac7")
    }

    func test_vectorCompletion() throws {
        let request = try SGTasksWire.MutationRequest(mutationId: self.uuid("55555555-5555-4555-8555-555555555555"), operation: .taskComplete(SGTasksWire.TaskComplete(
            taskId: self.uuid("33333333-3333-4333-8333-333333333333"), baseRevision: SGTasksWire.Revision("7")!, invitationId: nil, isCompleted: true
        )))
        let bytes = request.canonicalBusinessBytes(principal: self.principal)
        XCTAssertEqual(bytes.count, 170)
        XCTAssertEqual(request.businessHash(principal: self.principal), "cbfe591d3b6eeccd2ef2e7a9549ae471b2967e650f82d7aae5ad3fb42c719c8b")
    }

    func test_theHashDependsOnThePrincipalBytesAndNothingTransport() throws {
        let request = try SGTasksWire.MutationRequest(mutationId: self.uuid("55555555-5555-4555-8555-555555555555"), operation: .taskDelete(SGTasksWire.TaskDelete(taskId: self.uuid("33333333-3333-4333-8333-333333333333"), baseRevision: SGTasksWire.Revision("9")!)))
        XCTAssertNotEqual(request.businessHash(principal: self.principal), request.businessHash(principal: self.principal.uppercased()), "the stored key is hashed byte for byte, never re-cased")
        let restored = try SGTasksWire.MutationRequest(wireJSON: request.wireJSON)
        XCTAssertEqual(restored, request)
        XCTAssertEqual(restored.businessHash(principal: self.principal), request.businessHash(principal: self.principal))
    }

    // MARK: - Canonical encoder

    func test_encoderEscapesExactlyTheCanonicalSet() {
        let text = "a\"b\\c/d\u{08}\u{09}\u{0A}\u{0C}\u{0D}\u{01}\u{1F}\u{7F}\u{2028}\u{2029}é"
        let encoded = String(decoding: SGTasksJSON.encode(.string(text)), as: UTF8.self)
        XCTAssertEqual(encoded, "\"a\\\"b\\\\c/d\\b\\t\\n\\f\\r\\u0001\\u001f\u{7F}\u{2028}\u{2029}é\"")
        XCTAssertEqual(SGTasksJSON.encode(.array([.integer(-2147483648), .bool(true), .null])), self.data("[-2147483648,true,null]"))
    }

    // MARK: - Strict parser

    private func parses(_ text: String, depth: Int = 16) -> Bool {
        return (try? SGTasksJSON.parse(self.data(text), maxBytes: 65536, maxDepth: depth)) != nil
    }

    func test_parserRefusesWhatFoundationWouldAccept() {
        XCTAssertFalse(self.parses(#"{"a":1,"a":2}"#), "duplicate keys")
        XCTAssertFalse(self.parses("1.0"), "a fraction is not an integer")
        XCTAssertFalse(self.parses("1e2"), "an exponent is not an integer")
        XCTAssertFalse(self.parses("01"), "leading zero")
        XCTAssertFalse(self.parses("-0"))
        XCTAssertFalse(self.parses("9223372036854775808"), "past Int64")
        XCTAssertTrue(self.parses("9223372036854775807"))
        XCTAssertTrue(self.parses("-9223372036854775808"))
        XCTAssertFalse(self.parses(#""\ud800""#), "lone high surrogate")
        XCTAssertFalse(self.parses(#""\udc00""#), "lone low surrogate")
        XCTAssertEqual(try? SGTasksJSON.parse(self.data(#""\ud83d\ude00""#), maxBytes: 64, maxDepth: 4), .string("😀"))
        XCTAssertFalse(self.parses("\"a\u{01}b\""), "raw control character in a string")
        XCTAssertFalse(self.parses("{} x"), "trailing bytes")
        XCTAssertFalse(self.parses("\u{FEFF}{}"), "byte order mark")
        XCTAssertFalse(self.parses("{\"a\":1,}"), "trailing comma")
        XCTAssertFalse((try? SGTasksJSON.parse(Data([0x22, 0xff, 0x22]), maxBytes: 16, maxDepth: 4)) != nil, "invalid UTF-8")
        XCTAssertFalse((try? SGTasksJSON.parse(self.data("[1]"), maxBytes: 2, maxDepth: 4)) != nil, "over the byte bound")
    }

    func test_parserDepthBound() {
        let sixteen = String(repeating: "[", count: 16) + String(repeating: "]", count: 16)
        let seventeen = String(repeating: "[", count: 17) + String(repeating: "]", count: 17)
        XCTAssertTrue(self.parses(sixteen))
        XCTAssertThrowsError(try SGTasksJSON.parse(self.data(seventeen), maxBytes: 65536, maxDepth: 16)) { error in
            XCTAssertEqual(error as? SGTasksJSON.ParseError, .tooDeep)
        }
    }

    // MARK: - Scalars

    func test_uuidIsLowercaseVersion4Only() {
        XCTAssertNotNil(SGTasksWire.UUID("22222222-2222-4222-b222-222222222222"))
        XCTAssertNil(SGTasksWire.UUID("22222222-2222-4222-8222-22222222222A"), "uppercase")
        XCTAssertNil(SGTasksWire.UUID("22222222-2222-1222-8222-222222222222"), "version 1")
        XCTAssertNil(SGTasksWire.UUID("22222222-2222-4222-c222-222222222222"), "variant")
        XCTAssertNil(SGTasksWire.UUID("22222222222242228222222222222222"))
        let fresh = SGTasksWire.UUID.generate()
        XCTAssertNotNil(SGTasksWire.UUID(fresh.rawValue))
    }

    func test_decimalsAreCanonicalAndFitInt64() {
        XCTAssertNil(SGTasksWire.Revision("0"))
        XCTAssertNil(SGTasksWire.Revision("07"))
        XCTAssertNil(SGTasksWire.Revision("+7"))
        XCTAssertNil(SGTasksWire.Revision("9223372036854775808"))
        XCTAssertEqual(SGTasksWire.Revision("9223372036854775807")?.int64Value, Int64.max)
        XCTAssertEqual(SGTasksWire.Sequence("0")?.int64Value, 0)
        XCTAssertNil(SGTasksWire.Sequence("00"))
        XCTAssertNil(SGTasksWire.TelegramId("0"))
        XCTAssertNil(SGTasksWire.TelegramId("12345678901234567890"))
        XCTAssertTrue(SGTasksWire.Revision("10")! > SGTasksWire.Revision("9")!, "numeric, not lexicographic")
    }

    func test_instantIsAnExactCalendarSecond() {
        XCTAssertEqual(SGTasksWire.Instant("2000-02-29T00:00:00Z")?.epochSeconds, 951_782_400)
        XCTAssertEqual(SGTasksWire.Instant("1970-01-01T00:00:00Z")?.epochSeconds, 0)
        XCTAssertEqual(SGTasksWire.Instant("0000-01-01T00:00:00Z")?.epochSeconds, -62_167_219_200)
        XCTAssertEqual(SGTasksWire.Instant("9999-12-31T23:59:59Z")?.epochSeconds, 253_402_300_799)
        XCTAssertNil(SGTasksWire.Instant("2023-02-29T00:00:00Z"))
        XCTAssertNil(SGTasksWire.Instant("2024-04-31T00:00:00Z"))
        XCTAssertNil(SGTasksWire.Instant("2024-01-01T24:00:00Z"))
        XCTAssertNil(SGTasksWire.Instant("2024-01-01T00:00:60Z"))
        XCTAssertNil(SGTasksWire.Instant("2024-01-01T00:00:00.000Z"))
        XCTAssertNil(SGTasksWire.Instant("2024-01-01T00:00:00+00:00"))
        XCTAssertEqual(SGTasksWire.Instant(date: Date(timeIntervalSince1970: 1_792_512_000.9))?.rawValue, "2026-10-20T16:00:00Z")
        XCTAssertEqual(SGTasksWire.Instant(date: Date(timeIntervalSince1970: -0.5))?.rawValue, "1969-12-31T23:59:59Z")
        XCTAssertNil(SGTasksWire.Instant(date: Date(timeIntervalSince1970: 253_402_300_800)))
    }

    /// Postbox packing (`Peer.swift`): bits 32...34 namespace, id high bits shifted left by three.
    func test_cloudUserPeerIdDecodesOnlyCloudUsers() {
        XCTAssertEqual(SGTasksWire.TelegramId(cloudUserPeerId: 777_000)?.rawValue, "777000")
        XCTAssertEqual(SGTasksWire.TelegramId(cloudUserPeerId: 35_064_771_072)?.int64Value, 5_000_000_000, "a user id above UInt32.max")
        XCTAssertEqual(SGTasksWire.TelegramId(cloudUserPeerId: 576_460_722_238_652_415)?.int64Value, (1 << 56) - 1, "Postbox's largest PeerId.Id")
        XCTAssertNil(SGTasksWire.TelegramId(cloudUserPeerId: 576_460_752_303_423_488), "past Postbox's 56-bit id domain")
        XCTAssertNil(SGTasksWire.TelegramId(cloudUserPeerId: (1 << 32) | 1234), "CloudGroup")
        XCTAssertNil(SGTasksWire.TelegramId(cloudUserPeerId: (2 << 32) | 1234), "CloudChannel")
        XCTAssertNil(SGTasksWire.TelegramId(cloudUserPeerId: (3 << 32) | 1234), "SecretChat")
        XCTAssertNil(SGTasksWire.TelegramId(cloudUserPeerId: 0))
        XCTAssertNil(SGTasksWire.TelegramId(cloudUserPeerId: -777_000))
    }

    // MARK: - Sealing rules

    private func taskCreate(title: String = "Ish", description: String? = nil, annotationName: String? = nil, priority: Int = 0, dueAt: Int32? = nil, isCompleted: Bool = false, completedAt: SGTasksWire.Instant? = nil) -> SGTasksWire.Operation {
        let annotation = annotationName.map { SGTasksWire.Annotation(telegramUserId: SGTasksWire.TelegramId("42")!, displayName: $0) }
        return .taskCreate(SGTasksWire.TaskCreate(
            taskId: SGTasksWire.UUID.generate(),
            content: SGTasksWire.Content(listId: nil, title: title, description: description, dueAt: dueAt, priority: priority, sortOrder: 0, annotation: annotation),
            createdAt: nil, isCompleted: isCompleted, completedAt: completedAt
        ))
    }

    private func assertRefused(_ operation: SGTasksWire.Operation, path: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SGTasksWire.MutationRequest(mutationId: SGTasksWire.UUID.generate(), operation: operation), file: file, line: line) { error in
            XCTAssertEqual((error as? SGTasksWire.ValidationError)?.path, path, file: file, line: line)
        }
    }

    func test_sealingRefusesWhatWouldNeedNormalising() {
        let titlePath = "mutation.operation.content.title"
        self.assertRefused(self.taskCreate(title: " Ish"), path: titlePath)
        self.assertRefused(self.taskCreate(title: "Ish\n"), path: titlePath)
        self.assertRefused(self.taskCreate(title: "Ish\u{2028}"), path: titlePath)
        self.assertRefused(self.taskCreate(title: ""), path: titlePath)
        self.assertRefused(self.taskCreate(title: "\u{200B}\u{0301}"), path: titlePath)
        self.assertRefused(self.taskCreate(title: String(repeating: "a", count: 201)), path: titlePath)
        self.assertRefused(self.taskCreate(annotationName: String(repeating: "n", count: 257)), path: "mutation.operation.content.annotation.display_name")
        self.assertRefused(self.taskCreate(annotationName: "Ali "), path: "mutation.operation.content.annotation.display_name")
        self.assertRefused(self.taskCreate(description: String(repeating: "d", count: 4097)), path: "mutation.operation.content.description")
        self.assertRefused(self.taskCreate(priority: 5), path: "mutation.operation.content.priority")
        self.assertRefused(self.taskCreate(dueAt: -1), path: "mutation.operation.content.due_at")
        self.assertRefused(self.taskCreate(isCompleted: false, completedAt: SGTasksWire.Instant("2026-01-01T00:00:00Z")), path: "mutation.operation.completed_at")
        self.assertRefused(.listCreate(SGTasksWire.ListCreate(listId: SGTasksWire.UUID.generate(), title: String(repeating: "l", count: 101), sortOrder: 0, createdAt: nil)), path: "mutation.operation.title")
    }

    /// "a" + N × U+0301 + "b": two graphemes, 2 + 2N UTF-8 bytes — only the byte ceiling can refuse.
    private func marks(_ count: Int) -> String {
        return "a" + String(repeating: "\u{0301}", count: count) + "b"
    }

    func test_byteCeilingsAreEnforcedIndependentlyOfGraphemes() {
        let seal = { (operation: SGTasksWire.Operation) in
            try SGTasksWire.MutationRequest(mutationId: SGTasksWire.UUID.generate(), operation: operation)
        }
        XCTAssertNoThrow(try seal(self.taskCreate(title: self.marks(4095))), "8192 bytes")
        self.assertRefused(self.taskCreate(title: self.marks(4096)), path: "mutation.operation.content.title")
        let twoHundredHeavy = String(repeating: "e" + String(repeating: "\u{0301}", count: 20), count: 200)
        XCTAssertEqual(twoHundredHeavy.count, 200)
        self.assertRefused(self.taskCreate(title: twoHundredHeavy), path: "mutation.operation.content.title")
        XCTAssertNoThrow(try seal(self.taskCreate(annotationName: self.marks(2047))), "4096 bytes")
        self.assertRefused(self.taskCreate(annotationName: self.marks(2048)), path: "mutation.operation.content.annotation.display_name")
        XCTAssertNoThrow(try seal(self.taskCreate(description: self.marks(8191))), "16384 bytes")
        self.assertRefused(self.taskCreate(description: self.marks(8192)), path: "mutation.operation.content.description")
        let list = { (title: String) in
            SGTasksWire.Operation.listCreate(SGTasksWire.ListCreate(listId: SGTasksWire.UUID.generate(), title: title, sortOrder: 0, createdAt: nil))
        }
        XCTAssertNoThrow(try seal(list(self.marks(4095))))
        self.assertRefused(list(self.marks(4096)), path: "mutation.operation.title")
    }

    func test_historicalDatesBefore1970AreNeverSealed() {
        let before = SGTasksWire.Instant("1969-12-31T23:59:59Z")!
        let epoch = SGTasksWire.Instant("1970-01-01T00:00:00Z")!
        let content = SGTasksWire.Content(listId: nil, title: "Ish", description: nil, dueAt: nil, priority: 0, sortOrder: 0, annotation: nil)
        let task = { (createdAt: SGTasksWire.Instant?, completedAt: SGTasksWire.Instant?) in
            SGTasksWire.Operation.taskCreate(SGTasksWire.TaskCreate(taskId: SGTasksWire.UUID.generate(), content: content, createdAt: createdAt, isCompleted: true, completedAt: completedAt))
        }
        self.assertRefused(task(before, nil), path: "mutation.operation.created_at")
        self.assertRefused(task(epoch, before), path: "mutation.operation.completed_at")
        self.assertRefused(.listCreate(SGTasksWire.ListCreate(listId: SGTasksWire.UUID.generate(), title: "L", sortOrder: 0, createdAt: before)), path: "mutation.operation.created_at")
        XCTAssertNoThrow(try SGTasksWire.MutationRequest(mutationId: SGTasksWire.UUID.generate(), operation: task(epoch, epoch)))
    }

    func test_sealingAcceptsTheCeilingsAndGraphemeClusters() throws {
        XCTAssertNoThrow(try SGTasksWire.MutationRequest(mutationId: SGTasksWire.UUID.generate(), operation: self.taskCreate(title: String(repeating: "👍🏽", count: 200))))
        XCTAssertNoThrow(try SGTasksWire.MutationRequest(mutationId: SGTasksWire.UUID.generate(), operation: self.taskCreate(description: "  inner  whitespace is user content \n")))
        XCTAssertNoThrow(try SGTasksWire.MutationRequest(mutationId: SGTasksWire.UUID.generate(), operation: self.taskCreate(isCompleted: true, completedAt: nil)), "a completed import may have an unknown completion time")
    }

    // MARK: - Sealed bytes

    func test_restoringRefusesAnythingButTheExactSealedBytes() throws {
        let sealed = String(decoding: try SGTasksWire.MutationRequest(mutationId: self.uuid("11111111-1111-4111-8111-111111111111"), operation: .listCreate(SGTasksWire.ListCreate(
            listId: self.uuid("22222222-2222-4222-8222-222222222222"), title: "Ishlar", sortOrder: 0, createdAt: nil
        ))).wireJSON, as: UTF8.self)
        XCTAssertNoThrow(try SGTasksWire.MutationRequest(wireJSON: self.data(sealed)))
        let variants = [
            sealed.replacingOccurrences(of: ",", with: ", "),
            sealed.replacingOccurrences(of: #""created_at":null"#, with: #""created_at":null,"extra":1"#),
            sealed.replacingOccurrences(of: #","created_at":null"#, with: ""),
            sealed.replacingOccurrences(of: #""schema_version":1"#, with: #""schema_version":2"#),
            sealed.replacingOccurrences(of: #""title":"Ishlar""#, with: #""title":"Ishlar","title":"Ishlar""#),
            sealed.replacingOccurrences(of: #"{"schema_version":1,"mutation_id":"11111111-1111-4111-8111-111111111111","#, with: #"{"mutation_id":"11111111-1111-4111-8111-111111111111","schema_version":1,"#)
        ]
        for variant in variants {
            XCTAssertThrowsError(try SGTasksWire.MutationRequest(wireJSON: self.data(variant)), variant)
        }
    }

    // MARK: - Responses

    private let listJSON = #"{"kind":"list","id":"22222222-2222-4222-8222-222222222222","revision":"3","title":"Ishlar","sort_order":0,"created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-02T00:00:00Z"}"#

    private func taskJSON(role: String = "owner", listId: String = "null", annotation: String = "null", assignment: String = "null", completed: Bool = false, completedAt: String = "null") -> String {
        return #"{"kind":"task","id":"33333333-3333-4333-8333-333333333333","revision":"7","owner_tg_id":"5000000000","viewer_role":"\#(role)","content":{"list_id":\#(listId),"title":"Hisobot","description":null,"due_at":null,"priority":0,"sort_order":0,"annotation":\#(annotation)},"is_completed":\#(completed),"completed_at":\#(completedAt),"created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-02T00:00:00Z","assignment":\#(assignment)}"#
    }

    private let invitationJSON = #"{"kind":"invitation","id":"66666666-6666-4666-8666-666666666666","task_id":"33333333-3333-4333-8333-333333333333","task_revision":"7","owner_tg_id":"5000000000","title":"Hisobot","due_at":1792512000,"expires_at":"2026-10-08T00:00:00Z"}"#
    private let blockJSON = #"{"kind":"block","id":"123456789","created_at":"2026-10-01T00:00:00Z"}"#

    private func snapshot(_ items: [String], limit: Int = 50) throws -> SGTasksWire.SnapshotResponse {
        let text = #"{"schema_version":1,"items":[\#(items.joined(separator: ","))],"next_cursor":null,"changes_cursor":"c1","server_time":"2026-10-24T00:00:00Z"}"#
        return try SGTasksWireCodec.decodeSnapshotResponse(try SGTasksJSON.parse(self.data(text), maxBytes: 1 << 20, maxDepth: 16), limit: limit)
    }

    func test_snapshotDecodesEveryProjectionKind() throws {
        let response = try self.snapshot([self.listJSON, self.taskJSON(), self.invitationJSON, self.blockJSON])
        XCTAssertEqual(response.items.count, 4)
        XCTAssertNil(response.nextCursor)
        guard case let .task(task) = response.items[1] else {
            return XCTFail("second item is the task")
        }
        XCTAssertEqual(task.ownerTgId.int64Value, 5_000_000_000)
        XCTAssertEqual(task.revision.rawValue, "7")
        for item in response.items {
            XCTAssertEqual(try SGTasksWire.Projection(wireJSON: item.wireJSON), item, "a persisted shadow row restores to the same value")
        }
    }

    func test_snapshotRefusesShapeViolations() {
        let acceptedAssignment = #"{"invitation_id":"66666666-6666-4666-8666-666666666666","recipient_tg_id":"42","state":"accepted","expires_at":"2026-10-08T00:00:00Z"}"#
        let pendingAssignment = acceptedAssignment.replacingOccurrences(of: "accepted", with: "pending")
        XCTAssertNoThrow(try self.snapshot([self.taskJSON(role: "assignee", assignment: acceptedAssignment)]))
        let refused: [(String, [String])] = [
            ("unknown field", [self.listJSON.replacingOccurrences(of: #""sort_order":0"#, with: #""sort_order":0,"color":"red""#)]),
            ("missing nullable field", [self.taskJSON().replacingOccurrences(of: #","assignment":null"#, with: "")]),
            ("revision as a number", [self.listJSON.replacingOccurrences(of: #""revision":"3""#, with: #""revision":3"#)]),
            ("assignee sees an owner list", [self.taskJSON(role: "assignee", listId: #""22222222-2222-4222-8222-222222222222""#, assignment: acceptedAssignment)]),
            ("assignee sees a private annotation", [self.taskJSON(role: "assignee", annotation: #"{"telegram_user_id":"42","display_name":"Ali"}"#, assignment: acceptedAssignment)]),
            ("assignee of a pending invitation", [self.taskJSON(role: "assignee", assignment: pendingAssignment)]),
            ("completion time on an open task", [self.taskJSON(completedAt: #""2026-10-03T00:00:00Z""#)]),
            ("the same projection twice", [self.listJSON, self.listJSON]),
            ("sort order outside Int32", [self.listJSON.replacingOccurrences(of: #""sort_order":0"#, with: #""sort_order":2147483648"#)]),
            ("unknown kind", [#"{"kind":"note","id":"1"}"#])
        ]
        for (name, items) in refused {
            XCTAssertThrowsError(try self.snapshot(items), name)
        }
        XCTAssertThrowsError(try self.snapshot([self.listJSON, self.blockJSON], limit: 1), "more items than the page limit")
    }

    private func changes(_ entries: [String]) throws -> SGTasksWire.ChangesResponse {
        let text = #"{"schema_version":1,"changes":[\#(entries.joined(separator: ","))],"next_cursor":"c2","has_more":false,"server_time":"2026-10-24T00:00:00Z"}"#
        return try SGTasksWireCodec.decodeChangesResponse(try SGTasksJSON.parse(self.data(text), maxBytes: 1 << 20, maxDepth: 16), limit: 50)
    }

    func test_changesAreTypedAndAscending() throws {
        let response = try self.changes([
            #"{"position":"0","action":"upsert","item":\#(self.blockJSON)}"#,
            #"{"position":"9223372036854775807","action":"remove","kind":"task","id":"33333333-3333-4333-8333-333333333333"}"#
        ])
        XCTAssertEqual(response.changes.last, .remove(position: SGTasksWire.Sequence("9223372036854775807")!, target: .task(self.uuid("33333333-3333-4333-8333-333333333333"))))
        XCTAssertThrowsError(try self.changes([
            #"{"position":"5","action":"remove","kind":"block","id":"42"}"#,
            #"{"position":"5","action":"remove","kind":"block","id":"43"}"#
        ]), "positions must strictly ascend")
        XCTAssertThrowsError(try self.changes([#"{"position":"5","action":"remove","kind":"block","id":"33333333-3333-4333-8333-333333333333"}"#]), "a block is removed by Telegram id")
        XCTAssertThrowsError(try self.changes([#"{"position":"5","action":"remove","kind":"list","id":"42"}"#]), "a list is removed by UUID")
        XCTAssertThrowsError(try self.changes([#"{"position":"5","action":"remove","kind":"list","id":"22222222-2222-4222-8222-222222222222","item":null}"#]))
    }

    private func receipt(operation: String, kind: String, id: String, revision: String) throws -> SGTasksWire.MutationResponse {
        let text = #"{"schema_version":1,"receipt":{"mutation_id":"11111111-1111-4111-8111-111111111111","operation":"\#(operation)","outcome":"committed","resource_kind":"\#(kind)","resource_id":"\#(id)","resource_revision":\#(revision),"committed_at":"2026-10-24T00:00:00Z"},"server_time":"2026-10-24T00:00:01Z"}"#
        return try SGTasksWireCodec.decodeMutationResponse(try SGTasksJSON.parse(self.data(text), maxBytes: 65536, maxDepth: 16))
    }

    func test_receiptProjectionIsConsistent() throws {
        XCTAssertEqual(try self.receipt(operation: "list.update", kind: "list", id: "22222222-2222-4222-8222-222222222222", revision: #""4""#).receipt.resourceRevision?.rawValue, "4")
        XCTAssertEqual(try self.receipt(operation: "sender.block", kind: "block", id: "5000000000", revision: "null").receipt.resourceId, .telegramId(SGTasksWire.TelegramId("5000000000")!))
        XCTAssertThrowsError(try self.receipt(operation: "list.update", kind: "task", id: "22222222-2222-4222-8222-222222222222", revision: #""4""#))
        XCTAssertThrowsError(try self.receipt(operation: "invitation.request", kind: "task", id: "42", revision: #""4""#))
        XCTAssertThrowsError(try self.receipt(operation: "sender.block", kind: "block", id: "42", revision: #""4""#))
        XCTAssertThrowsError(try self.receipt(operation: "task.update", kind: "task", id: "33333333-3333-4333-8333-333333333333", revision: "null"))
    }

    // MARK: - Error classification

    private func classify(_ status: Int, _ body: String, retryAfter: Int? = nil, mutation: Bool = true) -> SGTasksErrorClassifier.Classified {
        return SGTasksErrorClassifier.classify(status: status, body: self.data(body), retryAfterHeader: retryAfter, isMutation: mutation)
    }

    func test_errorClassificationKeepsEveryDistinction() {
        let notLinked = self.classify(403, #"{"error":"tasks_account_not_linked","message":"x","server_time":"2026-10-24T00:00:00Z"}"#)
        XCTAssertEqual(notLinked.error.kind, .accountNotLinked)
        XCTAssertNil(notLinked.entitlementFailure, "never routed to the session machinery")
        XCTAssertEqual(notLinked.error.serverTime, SGTasksWire.Instant("2026-10-24T00:00:00Z")?.date)
        XCTAssertEqual(self.classify(403, #"{"error":"tasks_creation_not_permitted","message":"","server_time":"2026-10-24T00:00:00Z"}"#).error.kind, .creationNotPermitted)
        XCTAssertEqual(self.classify(409, #"{"error":"tasks_conflict","message":"","server_time":"2026-10-24T00:00:00Z","reason":"invitation_expired"}"#).error.kind, .conflict(.invitationExpired))
        XCTAssertEqual(self.classify(409, #"{"error":"tasks_conflict","message":"","server_time":"2026-10-24T00:00:00Z"}"#).error.kind, .malformedResponse, "a conflict without its reason is not a usable conflict")
        XCTAssertEqual(self.classify(409, #"{"error":"tasks_resync_required","message":"","server_time":"2026-10-24T00:00:00Z"}"#).error.kind, .resyncRequired)
        XCTAssertEqual(self.classify(409, #"{"error":"tasks_mutation_in_flight","message":"","server_time":"2026-10-24T00:00:00Z"}"#).error.kind, .mutationInFlight)
        XCTAssertEqual(self.classify(422, #"{"error":"tasks_mutation_mismatch","message":"","server_time":"2026-10-24T00:00:00Z"}"#).error.kind, .mutationMismatch)
        XCTAssertEqual(self.classify(422, #"{"error":"tasks_invalid_request","message":"","server_time":"2026-10-24T00:00:00Z"}"#).error.kind, .invalidRequest)
        XCTAssertEqual(self.classify(404, #"{"error":"tasks_not_found","message":"","server_time":"2026-10-24T00:00:00Z"}"#).error.kind, .notFound)

        let session = self.classify(401, #"{"error":"invalid_token","message":"","server_time":"2026-10-24T00:00:00Z"}"#)
        XCTAssertEqual(session.error.kind, .session(.invalidToken))
        XCTAssertEqual(session.entitlementFailure, .session(.invalidToken))
        let notADeviceAuthAnswer = self.classify(403, #"{"error":"invalid_token"}"#)
        XCTAssertEqual(notADeviceAuthAnswer.error.kind, .rejected(status: 403), "session codes count only under HTTP 401")
        XCTAssertNil(notADeviceAuthAnswer.entitlementFailure, "so nothing can reach SGEntitlement.apply")
        let proxied = self.classify(502, #"{"error":"device_revoked"}"#)
        XCTAssertEqual(proxied.error.kind, .unavailable)
        XCTAssertNil(proxied.entitlementFailure)
        XCTAssertTrue(proxied.error.outcomeUnknown)

        let throttled = self.classify(429, #"{"error":"too_many_requests"}"#, retryAfter: 30)
        XCTAssertEqual(throttled.error.kind, .rateLimited)
        XCTAssertEqual(throttled.error.retryAfter, 30)
        XCTAssertEqual(self.classify(429, "", retryAfter: 999_999).error.retryAfter, 86400)

        XCTAssertEqual(self.classify(503, #"{"error":"tasks_unavailable","message":"","server_time":"2026-10-24T00:00:00Z"}"#).error, SGTasksError(kind: .unavailable, serverTime: SGTasksWire.Instant("2026-10-24T00:00:00Z")?.date, outcomeUnknown: true))
        XCTAssertFalse(self.classify(503, #"{"error":"tasks_unavailable","message":"","server_time":"2026-10-24T00:00:00Z"}"#, mutation: false).error.outcomeUnknown, "a read commits nothing")
        XCTAssertEqual(self.classify(502, "<html>bad gateway</html>").error.kind, .unavailable)
        XCTAssertEqual(self.classify(413, "").error.kind, .rejected(status: 413))
        XCTAssertEqual(self.classify(400, #"{"error":"invalid_request"}"#).error.kind, .rejected(status: 400))
    }

    func test_anyServerFailureMayHaveCommittedWhateverItsCode() {
        for body in [#"{"error":"request_failed"}"#, #"{"error":"not_found"}"#, #"{"error":"tasks_conflict","message":"","server_time":"2026-10-24T00:00:00Z","reason":"revision_changed"}"#, #"{"error":"invalid_token"}"#] {
            let classified = self.classify(500, body)
            XCTAssertEqual(classified.error.kind, .unavailable, body)
            XCTAssertTrue(classified.error.outcomeUnknown, body)
            XCTAssertNil(classified.entitlementFailure, body)
        }
    }

    /// Existing middleware envelopes may carry metadata the success decoder refuses; the stable
    /// code must survive, while bounds and duplicate keys still disqualify a body.
    func test_errorEnvelopeVariationsKeepTheirCodeWithinBounds() {
        let fraction = self.classify(401, #"{"error":"invalid_token","retry_after":1.5,"meta":{"t":1e3},"server_time":"2026-10-24T00:00:00Z"}"#)
        XCTAssertEqual(fraction.error.kind, .session(.invalidToken))
        XCTAssertEqual(fraction.error.serverTime, SGTasksWire.Instant("2026-10-24T00:00:00Z")?.date)
        XCTAssertNil(fraction.error.retryAfter, "a fractional retry_after is unreadable, not invented")

        let duplicated = self.classify(401, #"{"error":"device_revoked","error":"nonce_replayed"}"#)
        XCTAssertEqual(duplicated.error.kind, .session(.unauthenticated), "conflicting codes are not trusted: a bare 401, which never drops the session")
        XCTAssertEqual(SGEntitlementFailureMapping.recovery(for: .session(.unauthenticated)).consequence, .keepEverything)

        let oversized = self.classify(401, #"{"error":"device_revoked","pad":""# + String(repeating: "x", count: 70000) + #""}"#)
        XCTAssertEqual(oversized.error.kind, .session(.unauthenticated), "past the error-body bound nothing is read")

        let longMessage = self.classify(409, #"{"error":"tasks_conflict","message":""# + String(repeating: "m", count: 300) + #"","server_time":"2026-10-24T00:00:00Z","reason":"completed_task"}"#)
        XCTAssertEqual(longMessage.error.kind, .conflict(.completedTask))

        XCTAssertEqual(try? SGTasksJSON.parse(Data(#"{"a":1.5,"b":2}"#.utf8), maxBytes: 64, maxDepth: 4, lenientNumbers: true), .object([SGTasksJSON.Member(name: "a", value: .null), SGTasksJSON.Member(name: "b", value: .integer(2))]))
        XCTAssertNil(try? SGTasksJSON.parse(Data(#"{"a":1.5}"#.utf8), maxBytes: 64, maxDepth: 4), "success bodies stay strict")
        XCTAssertNil(try? SGTasksJSON.parse(Data(#"{"a":1,"a":2}"#.utf8), maxBytes: 64, maxDepth: 4, lenientNumbers: true))
        XCTAssertNil(try? SGTasksJSON.parse(Data(#"{"a":01.5}"#.utf8), maxBytes: 64, maxDepth: 4, lenientNumbers: true))
        XCTAssertNil(try? SGTasksJSON.parse(Data(#"{"a":1.}"#.utf8), maxBytes: 64, maxDepth: 4, lenientNumbers: true))
    }

    func test_transportFailuresSayWhetherAMutationMayHaveLanded() {
        XCTAssertTrue(SGTasksErrorClassifier.transport(.offline(.timeout), isMutation: true).outcomeUnknown)
        XCTAssertTrue(SGTasksErrorClassifier.transport(.offline(.connectionLost), isMutation: true).outcomeUnknown)
        XCTAssertFalse(SGTasksErrorClassifier.transport(.offline(.dns), isMutation: true).outcomeUnknown)
        XCTAssertFalse(SGTasksErrorClassifier.transport(.offline(.tls), isMutation: true).outcomeUnknown)
        XCTAssertTrue(SGTasksErrorClassifier.transport(.offline(.noRoute), isMutation: true).outcomeUnknown, "the interface can drop after the bytes left")
        XCTAssertTrue(SGTasksErrorClassifier.transport(.offline(.cancelled), isMutation: true).outcomeUnknown)
        XCTAssertFalse(SGTasksErrorClassifier.transport(.offline(.timeout), isMutation: false).outcomeUnknown)
        XCTAssertEqual(SGTasksErrorClassifier.transport(.offline(.malformedResponse), isMutation: false).kind, .malformedResponse)
    }

    // MARK: - R4 hash vectors (inline copies of `x-r4-vectors.hash_vectors`)

    private let r4TaskId = "33333333-3333-4333-8333-333333333333"
    private let r4ListId = "22222222-2222-4222-8222-222222222222"

    private func patch1() throws -> SGTasksWire.PatchRequest {
        return try SGTasksWire.PatchRequest(mutationId: self.uuid("66666666-6666-4666-8666-666666666666"), patch: SGTasksWire.TaskPatch(
            taskId: self.uuid(self.r4TaskId),
            set: [.priority: .priority(3), .title: .title("Hisobot 2")],
            expect: [.priority: .priority(2), .title: .title("Hisobot / O\u{2018}zbekiston")]
        ))
    }

    func test_vectorPatch1() throws {
        let request = try self.patch1()
        let bytes = request.canonicalBusinessBytes(principal: self.principal)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), #"["zenlygram-tasks-business-v1","01arz3ndektsv4rrffq69g5fav","66666666-6666-4666-8666-666666666666","task.patch",["33333333-3333-4333-8333-333333333333",[["title","Hisobot 2"],["priority",3]],[["title","Hisobot / O\#u{2018}zbekiston"],["priority",2]]]]"#)
        XCTAssertEqual(bytes.count, 245)
        XCTAssertEqual(request.businessHash(principal: self.principal), "6193411e93311f66fbad3b0f833a692d44a990ee1ba9c4cb0e357c41f06c3f0c")
        XCTAssertEqual(String(decoding: request.wireJSON, as: UTF8.self), #"{"schema_version":1,"mutation_id":"66666666-6666-4666-8666-666666666666","operation":{"kind":"task.patch","task_id":"33333333-3333-4333-8333-333333333333","set":{"title":"Hisobot 2","priority":3},"expect":{"title":"Hisobot / O\#u{2018}zbekiston","priority":2}}}"#, "sealed keys in content order")
        XCTAssertEqual(SGTasksWire.SealedMutation.patch(request).businessHash(principal: self.principal), request.businessHash(principal: self.principal))
        // The fixture lists `set` / `expect` out of content order on purpose: key order is no identity.
        let fixture = #"{"kind":"task.patch","task_id":"33333333-3333-4333-8333-333333333333","set":{"priority":3,"title":"Hisobot 2"},"expect":{"priority":2,"title":"Hisobot / O\#u{2018}zbekiston"}}"#
        XCTAssertEqual(try SGTasksWireCodec.decodePatch(try SGTasksJSON.parse(self.data(fixture), maxBytes: 65536, maxDepth: 16), path: "operation"), request.patch)
    }

    func test_vectorPatch2() throws {
        let request = try SGTasksWire.PatchRequest(mutationId: self.uuid("77777777-7777-4777-8777-777777777777"), patch: SGTasksWire.TaskPatch(
            taskId: self.uuid(self.r4TaskId),
            set: [.listId: .listId(nil), .sortOrder: .sortOrder(2048), .annotation: .annotation(nil)],
            expect: [.listId: .listId(self.uuid(self.r4ListId)), .sortOrder: .sortOrder(-1), .annotation: .annotation(SGTasksWire.Annotation(telegramUserId: SGTasksWire.TelegramId("123456789")!, displayName: "Ali"))]
        ))
        let bytes = request.canonicalBusinessBytes(principal: self.principal)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), #"["zenlygram-tasks-business-v1","01arz3ndektsv4rrffq69g5fav","77777777-7777-4777-8777-777777777777","task.patch",["33333333-3333-4333-8333-333333333333",[["list_id",null],["sort_order",2048],["annotation",null]],[["list_id","22222222-2222-4222-8222-222222222222"],["sort_order",-1],["annotation",["123456789","Ali"]]]]]"#)
        XCTAssertEqual(bytes.count, 318)
        XCTAssertEqual(request.businessHash(principal: self.principal), "ad41a47effcf0e3022648c4278167ea14f71cc503d8dbd704e3611548f684b83")
        XCTAssertEqual(String(decoding: request.wireJSON, as: UTF8.self), #"{"schema_version":1,"mutation_id":"77777777-7777-4777-8777-777777777777","operation":{"kind":"task.patch","task_id":"33333333-3333-4333-8333-333333333333","set":{"list_id":null,"sort_order":2048,"annotation":null},"expect":{"list_id":"22222222-2222-4222-8222-222222222222","sort_order":-1,"annotation":{"telegram_user_id":"123456789","display_name":"Ali"}}}}"#, "the wire carries an annotation as an object, the hash as a pair")
        XCTAssertEqual(try SGTasksWire.PatchRequest(wireJSON: request.wireJSON), request)
        XCTAssertEqual(request.patch.fields, [.listId, .sortOrder, .annotation])
    }

    func test_vectorListDeleteR3AndR4() throws {
        let id = self.uuid("88888888-8888-4888-8888-888888888888")
        let r3 = try SGTasksWire.MutationRequest(mutationId: id, operation: .listDelete(SGTasksWire.ListDelete(listId: self.uuid(self.r4ListId), baseRevision: SGTasksWire.Revision("3")!)))
        XCTAssertEqual(String(decoding: r3.canonicalBusinessBytes(principal: self.principal), as: UTF8.self), #"["zenlygram-tasks-business-v1","01arz3ndektsv4rrffq69g5fav","88888888-8888-4888-8888-888888888888","list.delete",["22222222-2222-4222-8222-222222222222","3"]]"#)
        XCTAssertEqual(r3.canonicalBusinessBytes(principal: self.principal).count, 158)
        XCTAssertEqual(r3.businessHash(principal: self.principal), "ac5c6e31a9e616e9608df595538209a3888471fb8456cb549f9ea735885f8a81")
        XCTAssertEqual(String(decoding: r3.wireJSON, as: UTF8.self), #"{"schema_version":1,"mutation_id":"88888888-8888-4888-8888-888888888888","operation":{"kind":"list.delete","list_id":"22222222-2222-4222-8222-222222222222","base_revision":"3"}}"#, "an R3 delete seals exactly as before")
        XCTAssertFalse(SGTasksWire.SealedMutation.mutation(r3).requiresWire4)

        let r4 = try SGTasksWire.MutationRequest(mutationId: id, operation: .listDelete(SGTasksWire.ListDelete(listId: self.uuid(self.r4ListId), baseRevision: SGTasksWire.Revision("3")!, baseMembersRevision: SGTasksWire.Revision("7")!)))
        XCTAssertEqual(String(decoding: r4.canonicalBusinessBytes(principal: self.principal), as: UTF8.self), #"["zenlygram-tasks-business-v1","01arz3ndektsv4rrffq69g5fav","88888888-8888-4888-8888-888888888888","list.delete",["22222222-2222-4222-8222-222222222222","3","7"]]"#)
        XCTAssertEqual(r4.canonicalBusinessBytes(principal: self.principal).count, 162)
        XCTAssertEqual(r4.businessHash(principal: self.principal), "a7fe3b0bfe45cfd11e343bad1095ef5cd52badbc93506cc0aaf7ca6583a5f76b")
        XCTAssertEqual(String(decoding: r4.wireJSON, as: UTF8.self), #"{"schema_version":1,"mutation_id":"88888888-8888-4888-8888-888888888888","operation":{"kind":"list.delete","list_id":"22222222-2222-4222-8222-222222222222","base_revision":"3","base_members_revision":"7"}}"#)
        XCTAssertEqual(try SGTasksWire.MutationRequest(wireJSON: r4.wireJSON), r4)
        XCTAssertTrue(SGTasksWire.SealedMutation.mutation(r4).requiresWire4)
        XCTAssertTrue(SGTasksWire.SealedMutation.patch(try self.patch1()).requiresWire4)
        let numeric = String(decoding: r4.wireJSON, as: UTF8.self).replacingOccurrences(of: #""base_members_revision":"7""#, with: #""base_members_revision":7"#)
        XCTAssertThrowsError(try SGTasksWire.MutationRequest(wireJSON: self.data(numeric)), "a revision is a decimal string")
    }

    // MARK: - task.patch rules

    private func assertPatchRefused(_ patch: SGTasksWire.TaskPatch, path: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SGTasksWire.PatchRequest(mutationId: SGTasksWire.UUID.generate(), patch: patch), file: file, line: line) { error in
            XCTAssertEqual((error as? SGTasksWire.ValidationError)?.path, path, file: file, line: line)
        }
    }

    private func taskPatch(set: [SGTasksWire.ContentField: SGTasksWire.FieldValue], expect: [SGTasksWire.ContentField: SGTasksWire.FieldValue]) -> SGTasksWire.TaskPatch {
        return SGTasksWire.TaskPatch(taskId: self.uuid(self.r4TaskId), set: set, expect: expect)
    }

    func test_aPatchIsSealedOnlyWhenItsShapeAndSetValuesHold() throws {
        let path = "mutation.operation"
        self.assertPatchRefused(self.taskPatch(set: [:], expect: [:]), path: path + ".set")
        self.assertPatchRefused(self.taskPatch(set: [.title: .title("A")], expect: [.priority: .priority(1)]), path: path + ".expect")
        self.assertPatchRefused(self.taskPatch(set: [.title: .title("A"), .priority: .priority(1)], expect: [.title: .title("B")]), path: path + ".expect")
        self.assertPatchRefused(self.taskPatch(set: [.title: .priority(1)], expect: [.title: .title("B")]), path: path + ".set.title")
        self.assertPatchRefused(self.taskPatch(set: [.title: .title("A")], expect: [.title: .description("B")]), path: path + ".expect.title")
        // `set` is stored: the native sealing rules.
        self.assertPatchRefused(self.taskPatch(set: [.title: .title(" A")], expect: [.title: .title("B")]), path: path + ".set.title")
        self.assertPatchRefused(self.taskPatch(set: [.title: .title(String(repeating: "a", count: 201))], expect: [.title: .title("B")]), path: path + ".set.title")
        self.assertPatchRefused(self.taskPatch(set: [.description: .description(String(repeating: "d", count: 4097))], expect: [.description: .description(nil)]), path: path + ".set.description")
        self.assertPatchRefused(self.taskPatch(set: [.priority: .priority(5)], expect: [.priority: .priority(0)]), path: path + ".set.priority")
        self.assertPatchRefused(self.taskPatch(set: [.dueAt: .dueAt(-1)], expect: [.dueAt: .dueAt(nil)]), path: path + ".set.due_at")
        let ali = SGTasksWire.Annotation(telegramUserId: SGTasksWire.TelegramId("42")!, displayName: "Ali ")
        self.assertPatchRefused(self.taskPatch(set: [.annotation: .annotation(ali)], expect: [.annotation: .annotation(nil)]), path: path + ".set.annotation.display_name")
        // `expect` is only compared, and holds the server's own value: only the wire's structural
        // rules, never a stricter native one that could strand a stored task.
        XCTAssertNoThrow(try SGTasksWire.PatchRequest(mutationId: SGTasksWire.UUID.generate(), patch: self.taskPatch(set: [.title: .title("A")], expect: [.title: .title(" stored with a space")])))
        XCTAssertNoThrow(try SGTasksWire.PatchRequest(mutationId: SGTasksWire.UUID.generate(), patch: self.taskPatch(set: [.title: .title("A")], expect: [.title: .title(String(repeating: "a", count: 201))])))
        self.assertPatchRefused(self.taskPatch(set: [.title: .title("A")], expect: [.title: .title("")]), path: path + ".expect.title")
        self.assertPatchRefused(self.taskPatch(set: [.priority: .priority(1)], expect: [.priority: .priority(9)]), path: path + ".expect.priority")
        XCTAssertNoThrow(try SGTasksWire.PatchRequest(mutationId: SGTasksWire.UUID.generate(), patch: self.taskPatch(set: [.priority: .priority(1)], expect: [.priority: .priority(1)])), "a patch to the stored value is the server's benign no-op, not a local refusal")
        let huge = String(repeating: "x", count: 16384)
        self.assertPatchRefused(self.taskPatch(set: [.description: .description(self.marks(8191))], expect: [.description: .description(huge + huge + huge)]), path: path + ".expect.description")
    }

    func test_restoringAPatchRefusesAnythingButItsExactSealedBytes() throws {
        let request = try self.patch1()
        let sealed = String(decoding: request.wireJSON, as: UTF8.self)
        XCTAssertEqual(try SGTasksWire.PatchRequest(wireJSON: request.wireJSON), request)
        XCTAssertEqual(try SGTasksWire.SealedMutation(wireJSON: request.wireJSON), .patch(request))
        XCTAssertThrowsError(try SGTasksWire.MutationRequest(wireJSON: request.wireJSON), "task.patch is no R3 operation")
        let variants = [
            sealed.replacingOccurrences(of: #""set":{"title":"Hisobot 2","priority":3}"#, with: #""set":{"priority":3,"title":"Hisobot 2"}"#),
            sealed.replacingOccurrences(of: #""priority":3}"#, with: #""priority":3,"color":"red"}"#),
            sealed.replacingOccurrences(of: #","priority":2}"#, with: "}"),
            sealed.replacingOccurrences(of: #""set":{"title":"Hisobot 2","priority":3}"#, with: #""set":{}"#),
            sealed.replacingOccurrences(of: #""priority":3"#, with: #""priority":"3""#),
            sealed.replacingOccurrences(of: #""priority":3"#, with: #""priority":7"#),
            sealed.replacingOccurrences(of: #","expect""#, with: #","extra":1,"expect""#),
            sealed.replacingOccurrences(of: #""title":"Hisobot 2""#, with: #""title":"Hisobot 2","title":"Hisobot 2""#)
        ]
        for variant in variants {
            XCTAssertThrowsError(try SGTasksWire.PatchRequest(wireJSON: self.data(variant)), variant)
            XCTAssertThrowsError(try SGTasksWire.SealedMutation(wireJSON: self.data(variant)), variant)
        }
        let r3 = try SGTasksWire.MutationRequest(mutationId: self.uuid("11111111-1111-4111-8111-111111111111"), operation: .taskDelete(SGTasksWire.TaskDelete(taskId: self.uuid(self.r4TaskId), baseRevision: SGTasksWire.Revision("9")!)))
        XCTAssertEqual(try SGTasksWire.SealedMutation(wireJSON: r3.wireJSON), .mutation(r3), "R3 bytes restore as an R3 mutation")
        XCTAssertEqual(SGTasksWire.SealedMutation.mutation(r3).kind, .operation(.taskDelete))
    }

    func test_fieldValuesReadAndWriteContentByField() {
        let content = SGTasksWire.Content(listId: self.uuid(self.r4ListId), title: "Ish", description: nil, dueAt: 1_792_512_000, priority: 2, sortOrder: -1, annotation: nil)
        XCTAssertEqual(SGTasksWire.ContentField.allCases.map { SGTasksWire.FieldValue($0, of: content) }, [.listId(self.uuid(self.r4ListId)), .title("Ish"), .description(nil), .dueAt(1_792_512_000), .priority(2), .sortOrder(-1), .annotation(nil)])
        XCTAssertEqual(SGTasksWire.ContentField.allCases.map { SGTasksWire.FieldValue($0, of: content).field }, SGTasksWire.ContentField.allCases)
        XCTAssertEqual(SGTasksWire.ContentField.allCases.map { $0.rawValue }, ["list_id", "title", "description", "due_at", "priority", "sort_order", "annotation"])
        XCTAssertEqual(SGTasksWire.ContentField.allCases.sorted(), SGTasksWire.ContentField.allCases, "declared in content order")
        let patched = content.applying([.title: .title("Ish 2"), .listId: .listId(nil), .priority: .priority(4)])
        XCTAssertEqual(patched, SGTasksWire.Content(listId: nil, title: "Ish 2", description: nil, dueAt: 1_792_512_000, priority: 4, sortOrder: -1, annotation: nil))
        XCTAssertEqual(content.applying([:]), content)
    }

    func test_mutationKindsNameTheWire() {
        XCTAssertEqual(SGTasksWire.MutationKind.taskPatch.rawValue, "task.patch")
        XCTAssertEqual(SGTasksWire.MutationKind(rawValue: "task.patch"), .taskPatch)
        for kind in SGTasksWire.OperationKind.allCases {
            XCTAssertEqual(SGTasksWire.MutationKind(rawValue: kind.rawValue), .operation(kind))
            XCTAssertEqual(SGTasksWire.MutationKind.operation(kind).isCreation, kind.isCreation)
        }
        XCTAssertFalse(SGTasksWire.MutationKind.taskPatch.isCreation)
        XCTAssertNil(SGTasksWire.MutationKind(rawValue: "task.move"))
    }

    // MARK: - R4 responses

    func test_aListProjectionMayCarryItsMembersRevision() throws {
        let r4List = self.listJSON.replacingOccurrences(of: #""revision":"3","#, with: #""revision":"3","members_revision":"12","#)
        let response = try self.snapshot([r4List, self.listJSON.replacingOccurrences(of: "22222222-2222-4222-8222-222222222222", with: "22222222-2222-4222-8222-222222222223")])
        guard case let .list(withMembers) = response.items[0], case let .list(r3) = response.items[1] else {
            return XCTFail("two lists")
        }
        XCTAssertEqual(withMembers.membersRevision, SGTasksWire.Revision("12"))
        XCTAssertEqual(withMembers.revision, SGTasksWire.Revision("3"))
        XCTAssertNil(r3.membersRevision, "an R3 projection has none")
        XCTAssertEqual(String(decoding: response.items[0].wireJSON, as: UTF8.self), r4List, "the shadow row keeps it")
        XCTAssertEqual(try SGTasksWire.Projection(wireJSON: response.items[0].wireJSON), response.items[0])
        XCTAssertEqual(try SGTasksWire.Projection(wireJSON: response.items[1].wireJSON), response.items[1])
        for broken in [#""members_revision":"0""#, #""members_revision":12"#, #""members_revision":null"#] {
            XCTAssertThrowsError(try self.snapshot([self.listJSON.replacingOccurrences(of: #""revision":"3","#, with: #""revision":"3",\#(broken),"#)]), broken)
        }
        XCTAssertThrowsError(try self.snapshot([self.taskJSON().replacingOccurrences(of: #""revision":"7","#, with: #""revision":"7","members_revision":"1","#)]), "only a list has one")
    }

    func test_aPatchReceiptAnswersOnlyItsPatch() throws {
        let request = try self.patch1()
        let patchReceipt = try self.receipt(operation: "task.patch", kind: "task", id: self.r4TaskId, revision: #""8""#).receipt
        XCTAssertEqual(patchReceipt.operation, .taskPatch)
        let ownReceipt = SGTasksWire.Receipt(mutationId: request.mutationId, operation: .taskPatch, outcome: .committed, resourceKind: .task, resourceId: .uuid(self.uuid(self.r4TaskId)), resourceRevision: SGTasksWire.Revision("8"), committedAt: SGTasksWire.Instant("2026-10-24T00:00:00Z")!)
        XCTAssertTrue(SGTasksWireCodec.receipt(ownReceipt, answers: .patch(request)))
        let otherTask = SGTasksWire.Receipt(mutationId: request.mutationId, operation: .taskPatch, outcome: .committed, resourceKind: .task, resourceId: .uuid(self.uuid("33333333-3333-4333-8333-333333333334")), resourceRevision: SGTasksWire.Revision("8"), committedAt: SGTasksWire.Instant("2026-10-24T00:00:00Z")!)
        XCTAssertFalse(SGTasksWireCodec.receipt(otherTask, answers: .patch(request)))
        let asUpdate = SGTasksWire.Receipt(mutationId: request.mutationId, operation: SGTasksWire.OperationKind.taskUpdate, outcome: .committed, resourceKind: .task, resourceId: .uuid(self.uuid(self.r4TaskId)), resourceRevision: SGTasksWire.Revision("8"), committedAt: SGTasksWire.Instant("2026-10-24T00:00:00Z")!)
        XCTAssertFalse(SGTasksWireCodec.receipt(asUpdate, answers: .patch(request)), "a patch is answered as a patch")
        XCTAssertThrowsError(try self.receipt(operation: "task.patch", kind: "list", id: self.r4TaskId, revision: #""8""#))
        XCTAssertThrowsError(try self.receipt(operation: "task.patch", kind: "task", id: self.r4TaskId, revision: "null"))
        XCTAssertThrowsError(try self.receipt(operation: "task.move", kind: "task", id: self.r4TaskId, revision: #""8""#))
    }

    // MARK: - R4 error bodies

    private func strictError(_ text: String) -> SGTasksWire.Error? {
        guard let value = try? SGTasksJSON.parse(self.data(text), maxBytes: 65536, maxDepth: 16) else {
            return nil
        }
        return SGTasksWireCodec.decodeError(value)
    }

    func test_r4ErrorBodiesFollowTheErrorRulesStrictly() {
        let time = #""server_time":"2026-10-24T00:00:00Z""#
        let fieldChanged = self.strictError(#"{"error":"tasks_conflict","message":"m",\#(time),"reason":"field_changed","fields":["title","priority"]}"#)
        XCTAssertEqual(fieldChanged?.reason, .fieldChanged)
        XCTAssertEqual(fieldChanged?.fields, [.title, .priority])
        XCTAssertEqual(self.strictError(#"{"error":"tasks_conflict","message":"m",\#(time),"reason":"members_changed"}"#)?.reason, .membersChanged)
        let consent = self.strictError(#"{"error":"tasks_consent_required","message":"m",\#(time),"reason":"withdrawn","effective_at":"2026-10-30T12:00:00Z"}"#)
        XCTAssertEqual(consent?.reason, .withdrawn)
        XCTAssertEqual(consent?.effectiveAt, SGTasksWire.Instant("2026-10-30T12:00:00Z"))
        XCTAssertEqual(self.strictError(#"{"error":"tasks_unavailable","message":"m",\#(time),"reason":"migration_paused"}"#)?.reason, .migrationPaused)
        XCTAssertEqual(self.strictError(#"{"error":"tasks_unavailable","message":"m",\#(time),"reason":"batch_disabled"}"#)?.reason, .batchDisabled)
        XCTAssertNotNil(self.strictError(#"{"error":"tasks_unavailable","message":"m",\#(time)}"#), "the transient 503 has no reason")
        let refused: [(String, String)] = [
            ("fields without field_changed", #"{"error":"tasks_conflict","message":"m",\#(time),"reason":"revision_changed","fields":["title"]}"#),
            ("field_changed without fields", #"{"error":"tasks_conflict","message":"m",\#(time),"reason":"field_changed"}"#),
            ("fields out of content order", #"{"error":"tasks_conflict","message":"m",\#(time),"reason":"field_changed","fields":["priority","title"]}"#),
            ("a field twice", #"{"error":"tasks_conflict","message":"m",\#(time),"reason":"field_changed","fields":["title","title"]}"#),
            ("an unknown field", #"{"error":"tasks_conflict","message":"m",\#(time),"reason":"field_changed","fields":["color"]}"#),
            ("no field", #"{"error":"tasks_conflict","message":"m",\#(time),"reason":"field_changed","fields":[]}"#),
            ("a 503 reason on a conflict", #"{"error":"tasks_conflict","message":"m",\#(time),"reason":"migration_paused"}"#),
            ("consent without effective_at", #"{"error":"tasks_consent_required","message":"m",\#(time),"reason":"withdrawn"}"#),
            ("consent without its reason", #"{"error":"tasks_consent_required","message":"m",\#(time),"effective_at":"2026-10-30T12:00:00Z"}"#),
            ("effective_at on another code", #"{"error":"tasks_unavailable","message":"m",\#(time),"effective_at":"2026-10-30T12:00:00Z"}"#),
            ("a conflict reason on a 503", #"{"error":"tasks_unavailable","message":"m",\#(time),"reason":"field_changed","fields":["title"]}"#),
            ("a reason on a reasonless code", #"{"error":"tasks_not_found","message":"m",\#(time),"reason":"withdrawn"}"#),
            ("an unknown reason", #"{"error":"tasks_conflict","message":"m",\#(time),"reason":"moved"}"#)
        ]
        for (name, body) in refused {
            XCTAssertNil(self.strictError(body), name)
        }
    }

    func test_r4AnswersKeepTheirR3KindAndSayWhatTheyAre() {
        let time = #""server_time":"2026-10-24T00:00:00Z""#
        let consent = self.classify(403, #"{"error":"tasks_consent_required","message":"m",\#(time),"reason":"withdrawn","effective_at":"2026-10-30T12:00:00Z"}"#)
        XCTAssertEqual(consent.error, SGTasksError(kind: .rejected(status: 403), serverTime: SGTasksWire.Instant("2026-10-24T00:00:00Z")?.date, refinement: .consentRequired(effectiveAt: "2026-10-30T12:00:00Z")))
        XCTAssertNil(consent.entitlementFailure, "never the session's business")
        XCTAssertNil(consent.sessionError)
        XCTAssertEqual(self.classify(403, #"{"error":"tasks_consent_required","message":"m","effective_at":"not a time"}"#).error.refinement, .consentRequired(effectiveAt: nil), "an unreadable time keeps the fence")
        XCTAssertEqual(self.classify(403, #"{"error":"tasks_consent_required","message":"m",\#(time),"reason":"withdrawn","effective_at":"2026-10-30T12:00:00Z"}"#, mutation: false).error.kind, .rejected(status: 403), "reads too")

        let fields = self.classify(409, #"{"error":"tasks_conflict","message":"m",\#(time),"reason":"field_changed","fields":["title","priority"]}"#)
        XCTAssertEqual(fields.error.kind, .conflict(.revisionChanged))
        XCTAssertEqual(fields.error.refinement, .fieldChanged(fields: [.title, .priority]))
        XCTAssertFalse(fields.error.outcomeUnknown)
        let members = self.classify(409, #"{"error":"tasks_conflict","message":"m",\#(time),"reason":"members_changed"}"#)
        XCTAssertEqual(members.error.kind, .conflict(.revisionChanged))
        XCTAssertEqual(members.error.refinement, .membersChanged)
        XCTAssertEqual(self.classify(409, #"{"error":"tasks_conflict","message":"m",\#(time),"reason":"field_changed"}"#).error.kind, .malformedResponse, "a field conflict without its fields is not a usable conflict")
        XCTAssertNil(self.classify(409, #"{"error":"tasks_conflict","message":"m",\#(time),"reason":"completed_task"}"#).error.refinement, "an R3 answer has no refinement")

        let paused = self.classify(503, #"{"error":"tasks_unavailable","message":"m",\#(time),"reason":"migration_paused"}"#, retryAfter: 3600)
        XCTAssertEqual(paused.error, SGTasksError(kind: .unavailable, retryAfter: 3600, serverTime: SGTasksWire.Instant("2026-10-24T00:00:00Z")?.date, outcomeUnknown: false, refinement: .migrationPaused))
        let disabled = self.classify(503, #"{"error":"tasks_unavailable","message":"m",\#(time),"reason":"batch_disabled"}"#)
        XCTAssertEqual(disabled.error.refinement, .batchDisabled)
        XCTAssertFalse(disabled.error.outcomeUnknown, "the batch route refused before anything ran")
        let transient = self.classify(503, #"{"error":"tasks_unavailable","message":"m",\#(time)}"#)
        XCTAssertNil(transient.error.refinement)
        XCTAssertTrue(transient.error.outcomeUnknown, "a reasonless 503 may still have committed")
        XCTAssertTrue(self.classify(500, #"{"error":"tasks_unavailable","message":"m",\#(time),"reason":"migration_paused"}"#).error.outcomeUnknown, "the reasons count under their 503 only")

        XCTAssertEqual(self.classify(413, #"{"error":"tasks_invalid_request","message":"m",\#(time)}"#).error.kind, .rejected(status: 413), "an oversized request stays a 413 whatever its code: send less")
        XCTAssertEqual(self.classify(422, #"{"error":"tasks_invalid_request","message":"m",\#(time)}"#).error.kind, .invalidRequest)
        XCTAssertEqual(self.classify(404, #"{"error":"not_found","message":"m",\#(time)}"#).error.kind, .rejected(status: 404), "no route: not a missing resource")
        XCTAssertEqual(self.classify(404, #"{"error":"tasks_not_found","message":"m",\#(time)}"#).error.kind, .notFound)
    }

    func test_aDeviceAuth401KeepsItsReasonForTheSession() {
        let erased = self.classify(401, #"{"error":"invalid_token","message":"m","reason":"account_erased","server_time":"2026-10-24T00:00:00Z"}"#)
        XCTAssertEqual(erased.error.kind, .session(.invalidToken))
        XCTAssertEqual(erased.sessionError, SGEntitlementRequestError(failure: .session(.invalidToken), serverTime: SGTasksWire.Instant("2026-10-24T00:00:00Z")?.date, status: 401, code: "invalid_token", reason: "account_erased"))
        XCTAssertNil(self.classify(401, #"{"error":"invalid_token","message":"m","server_time":"2026-10-24T00:00:00Z"}"#).sessionError?.reason)
        XCTAssertNil(self.classify(403, #"{"error":"invalid_token","reason":"account_erased"}"#).sessionError, "nothing outside a 401 reaches apply")
        XCTAssertNil(self.classify(401, #"{"error":"apple_jws_invalid","message":"m"}"#).sessionError)
    }

    // MARK: - R4 batch

    private func batchItemError(_ status: Int, _ error: String, retryAfter: Int? = nil) -> SGTasksErrorClassifier.Classified? {
        guard let value = try? SGTasksJSON.parse(self.data(error), maxBytes: 65536, maxDepth: 16) else {
            return nil
        }
        return SGTasksErrorClassifier.classifyItem(status: status, error: value, serverTime: SGTasksWire.Instant("2026-10-24T00:00:00Z")?.date, retryAfter: retryAfter)
    }

    /// An item is classified by the table an envelope with the same code and status gets.
    func test_batchItemsClassifyLikeTheSingleRoute() {
        let time = #""server_time":"2026-10-24T00:00:00Z""#
        let cases: [(Int, String)] = [
            (403, #""error":"tasks_account_not_linked","message":"m""#),
            (403, #""error":"tasks_creation_not_permitted","message":"m""#),
            (403, #""error":"tasks_consent_required","message":"m","reason":"withdrawn","effective_at":"2026-10-30T12:00:00Z""#),
            (404, #""error":"tasks_not_found","message":"m""#),
            (409, #""error":"tasks_conflict","message":"m","reason":"revision_changed""#),
            (409, #""error":"tasks_conflict","message":"m","reason":"field_changed","fields":["description","due_at"]"#),
            (409, #""error":"tasks_conflict","message":"m","reason":"members_changed""#),
            (409, #""error":"tasks_resync_required","message":"m""#),
            (409, #""error":"tasks_mutation_in_flight","message":"m""#),
            (422, #""error":"tasks_invalid_request","message":"m""#),
            (422, #""error":"tasks_mutation_mismatch","message":"m""#),
            (401, #""error":"invalid_token","message":"m""#),
            (401, #""error":"device_revoked","message":"m""#),
            (503, #""error":"tasks_unavailable","message":"m""#),
            (503, #""error":"tasks_unavailable","message":"m","reason":"migration_paused""#)
        ]
        for (status, members) in cases {
            guard let item = self.batchItemError(status, "{\(members)}") else {
                XCTFail("\(status) \(members) is a valid BatchItemError")
                continue
            }
            let envelope = self.classify(status, "{\(members),\(time)}")
            XCTAssertEqual(item.error, envelope.error, "\(status) \(members)")
            XCTAssertEqual(item.entitlementFailure, envelope.entitlementFailure, "\(status) \(members)")
            XCTAssertEqual(item.sessionError, envelope.sessionError, "\(status) \(members)")
        }
        let limited = self.batchItemError(429, #"{"error":"tasks_rate_limited","message":"m","retry_after":45}"#)
        XCTAssertEqual(limited?.error.kind, .rateLimited)
        XCTAssertEqual(limited?.error.retryAfter, 45)
        XCTAssertEqual(self.batchItemError(429, #"{"error":"tasks_rate_limited","message":"m"}"#, retryAfter: 30)?.error.retryAfter, 30, "the batch's retry_after when the item names none")
        XCTAssertNil(self.batchItemError(409, #"{"error":"tasks_conflict","message":"m","reason":"revision_changed"}"#, retryAfter: 30)?.error.retryAfter, "only a 429 / 503 waits")
        XCTAssertEqual(self.batchItemError(503, #"{"error":"tasks_unavailable","message":"m","reason":"migration_paused","retry_after":3600}"#)?.error, SGTasksError(kind: .unavailable, retryAfter: 3600, serverTime: SGTasksWire.Instant("2026-10-24T00:00:00Z")?.date, outcomeUnknown: false, refinement: .migrationPaused))
        let revoked = self.batchItemError(401, #"{"error":"device_revoked","message":"m"}"#)
        XCTAssertEqual(revoked?.sessionError, SGEntitlementRequestError(failure: .session(.deviceRevoked), serverTime: SGTasksWire.Instant("2026-10-24T00:00:00Z")?.date, status: 401, code: "device_revoked"))

        let broken: [(Int, String)] = [
            // `account_erased` rides on the envelope 401 of `RequireDevice` (contract A3); an item
            // carries a reason only with the three Tasks codes `ErrorRules` gives one.
            (401, #"{"error":"invalid_token","message":"m","reason":"account_erased"}"#),
            (409, #"{"error":"tasks_conflict","message":"m","reason":"revision_changed","retry_after":5}"#),
            (409, #"{"error":"tasks_conflict","message":"m","reason":"revision_changed","fields":["title"]}"#),
            (429, #"{"error":"tasks_rate_limited","message":"m","retry_after":0}"#),
            (409, #"{"error":"tasks_conflict","message":"m","reason":"revision_changed",\#(time)}"#),
            (404, #"{"error":"tasks_not_found"}"#),
            (403, #"{"error":"tasks_consent_required","message":"m","reason":"withdrawn"}"#),
            (404, #"{"error":"tasks_not_found","message":"m","effective_at":"2026-10-30T12:00:00Z"}"#),
            (409, #"{"error":"tasks_conflict","message":"m","reason":"revision_changed","retry_after":1.5}"#)
        ]
        for (status, error) in broken {
            XCTAssertNil(self.batchItemError(status, error), error)
        }
    }

    private func sealedCreate(_ id: String, list: String) throws -> SGTasksWire.SealedMutation {
        return .mutation(try SGTasksWire.MutationRequest(mutationId: self.uuid(id), operation: .listCreate(SGTasksWire.ListCreate(listId: self.uuid(list), title: "Ishlar", sortOrder: 0, createdAt: nil))))
    }

    private let batchId = "99999999-9999-4999-8999-999999999999"

    func test_aBatchIsValidatedWhenMadeAndItsBodyIsTheSealedBytes() throws {
        let create = try self.sealedCreate("11111111-1111-4111-8111-111111111111", list: self.r4ListId)
        let patch = SGTasksWire.SealedMutation.patch(try self.patch1())
        let batch = try SGTasksWire.MutationBatchRequest(batchId: self.uuid(self.batchId), items: [.init(patch), .init(create, origin: .migration)])
        let createBytes = String(decoding: create.wireJSON, as: UTF8.self)
        let createWithoutBrace = String(createBytes.dropFirst())
        var expected = #"{"schema_version":1,"batch_id":"99999999-9999-4999-8999-999999999999","mutations":["#
        expected += String(decoding: patch.wireJSON, as: UTF8.self)
        expected += #",{"origin":"migration","# + createWithoutBrace + "]}"
        XCTAssertEqual(String(decoding: SGTasksWireCodec.batchBody(batch, creationProof: nil), as: UTF8.self), expected)
        XCTAssertEqual(batch.bodyBytes, SGTasksWireCodec.batchBody(batch, creationProof: nil).count)
        XCTAssertTrue(String(decoding: SGTasksWireCodec.batchBody(batch, creationProof: nil), as: UTF8.self).hasSuffix(createWithoutBrace + "]}"), "the sealed bytes stay a byte-exact suffix")
        XCTAssertTrue(batch.containsCreation)
        XCTAssertEqual(String(decoding: SGTasksWireCodec.batchBody(batch, creationProof: "jws"), as: UTF8.self), String(expected.dropLast()) + #","creation_proof":{"jws":"jws"}}"#)

        let patchOnly = try SGTasksWire.MutationBatchRequest(batchId: self.uuid(self.batchId), items: [.init(patch)])
        XCTAssertFalse(patchOnly.containsCreation)
        XCTAssertFalse(String(decoding: SGTasksWireCodec.batchBody(patchOnly, creationProof: "jws"), as: UTF8.self).contains("creation_proof"), "a proof only accompanies a create")

        func refused(_ items: [SGTasksWire.MutationBatchRequest.Item], _ path: String, line: UInt = #line) {
            XCTAssertThrowsError(try SGTasksWire.MutationBatchRequest(batchId: self.uuid(self.batchId), items: items), line: line) { error in
                XCTAssertEqual((error as? SGTasksWire.ValidationError)?.path, path, line: line)
            }
        }
        refused([], "mutations")
        refused([.init(create), .init(create)], "mutations[1].mutation_id")
        refused([.init(patch, origin: .migration)], "mutations[0].origin")
        let hundredAndOne = try (0 ... 100).map { index -> SGTasksWire.MutationBatchRequest.Item in
            let suffix = String(index)
            return .init(try self.sealedCreate("11111111-1111-4111-8111-" + String(repeating: "0", count: 12 - suffix.count) + suffix, list: self.r4ListId))
        }
        refused(hundredAndOne, "mutations")
        XCTAssertNoThrow(try SGTasksWire.MutationBatchRequest(batchId: self.uuid(self.batchId), items: Array(hundredAndOne.prefix(100))))
    }

    func test_aBatchPastItsByteCeilingIsRefusedAndAProofNeverPushesItPast() throws {
        // Creates with a maximal description ("a" + 8191 combining marks + "b": 16384 bytes) until
        // one more would pass 512 KiB — about thirty.
        func update(_ index: Int) throws -> SGTasksWire.SealedMutation {
            let suffix = String(index)
            let content = SGTasksWire.Content(listId: nil, title: "Ish", description: self.marks(8191), dueAt: nil, priority: 0, sortOrder: 0, annotation: nil)
            return .mutation(try SGTasksWire.MutationRequest(mutationId: self.uuid("11111111-1111-4111-8111-" + String(repeating: "0", count: 12 - suffix.count) + suffix), operation: .taskCreate(SGTasksWire.TaskCreate(taskId: SGTasksWire.UUID.generate(), content: content, createdAt: nil, isCompleted: false, completedAt: nil))))
        }
        var items: [SGTasksWire.MutationBatchRequest.Item] = []
        while SGTasksWire.MutationBatchRequest.bodyBytes(of: items + [.init(try update(items.count))]) <= SGTasksWire.maxBatchRequestBytes {
            items.append(.init(try update(items.count)))
        }
        let full = try SGTasksWire.MutationBatchRequest(batchId: self.uuid(self.batchId), items: items)
        XCTAssertLessThanOrEqual(full.bodyBytes, SGTasksWire.maxBatchRequestBytes)
        XCTAssertThrowsError(try SGTasksWire.MutationBatchRequest(batchId: self.uuid(self.batchId), items: items + [.init(try update(items.count))])) { error in
            XCTAssertEqual((error as? SGTasksWire.ValidationError)?.path, "batch")
        }
        let proof = String(repeating: "p", count: SGTasksWire.maxBatchRequestBytes - full.bodyBytes)
        XCTAssertEqual(SGTasksWireCodec.batchBody(full, creationProof: proof), SGTasksWireCodec.batchBody(full, creationProof: nil), "a proof that does not fit is left out")
        XCTAssertLessThanOrEqual(SGTasksWireCodec.batchBody(full, creationProof: "short").count, SGTasksWire.maxBatchRequestBytes)
    }

    private func batchResponse(_ results: [String], batchId: String? = nil, retryAfter: String = "null") -> String {
        return #"{"schema_version":1,"batch_id":"\#(batchId ?? self.batchId)","results":[\#(results.joined(separator: ","))],"retry_after":\#(retryAfter),"server_time":"2026-10-24T00:00:05Z"}"#
    }

    private func decodeBatch(_ text: String, _ request: SGTasksWire.MutationBatchRequest, serverWire: Int? = 4) throws -> SGTasksWireCodec.DecodedBatch {
        return try SGTasksWireCodec.decodeBatchResponse(try SGTasksJSON.parse(self.data(text), maxBytes: 262144, maxDepth: 16), request: request, serverWire: serverWire)
    }

    func test_aBatchAnswerIsDecodedStrictlyItemByItem() throws {
        let create = try self.sealedCreate("11111111-1111-4111-8111-111111111111", list: self.r4ListId)
        let patch = SGTasksWire.SealedMutation.patch(try self.patch1())
        let third = try self.sealedCreate("11111111-1111-4111-8111-111111111112", list: "22222222-2222-4222-8222-222222222223")
        let request = try SGTasksWire.MutationBatchRequest(batchId: self.uuid(self.batchId), items: [.init(create, origin: .migration), .init(patch), .init(third, origin: .migration)])
        let receipt = #"{"mutation_id":"11111111-1111-4111-8111-111111111111","status":200,"receipt":{"mutation_id":"11111111-1111-4111-8111-111111111111","operation":"list.create","outcome":"committed","resource_kind":"list","resource_id":"22222222-2222-4222-8222-222222222222","resource_revision":"1","committed_at":"2026-10-24T00:00:04Z"}}"#
        let conflict = #"{"mutation_id":"66666666-6666-4666-8666-666666666666","status":409,"error":{"error":"tasks_conflict","message":"m","reason":"field_changed","fields":["title"]}}"#
        let skipped = #"{"mutation_id":"11111111-1111-4111-8111-111111111112","status":null,"skipped":true}"#
        let decoded = try self.decodeBatch(self.batchResponse([receipt, conflict, skipped], retryAfter: "120"), request)
        let response = decoded.response
        XCTAssertEqual(response.batchId, self.uuid(self.batchId))
        XCTAssertEqual(response.retryAfter, 120)
        XCTAssertEqual(response.serverWire, 4)
        XCTAssertEqual(response.serverTime, SGTasksWire.Instant("2026-10-24T00:00:05Z"))
        XCTAssertEqual(response.results.count, 3)
        guard case let .receipt(first) = response.results[0] else {
            return XCTFail("a receipt")
        }
        XCTAssertEqual(first.operation, .operation(.listCreate))
        XCTAssertEqual(response.results[1], .error(status: 409, SGTasksError(kind: .conflict(.revisionChanged), serverTime: SGTasksWire.Instant("2026-10-24T00:00:05Z")?.date, refinement: .fieldChanged(fields: [.title]))))
        XCTAssertEqual(response.results[2], .skipped)
        XCTAssertTrue(decoded.sessionFailures.isEmpty)
        XCTAssertNil(try self.decodeBatch(self.batchResponse([receipt, conflict, skipped]), request, serverWire: nil).response.serverWire, "no echo, no wire")

        let broken: [(String, String)] = [
            ("another batch", self.batchResponse([receipt, conflict, skipped], batchId: "99999999-9999-4999-8999-999999999998")),
            ("a result missing", self.batchResponse([receipt, conflict])),
            ("a result too many", self.batchResponse([receipt, conflict, skipped, skipped])),
            ("results out of order", self.batchResponse([conflict, receipt, skipped])),
            ("a receipt for another resource", self.batchResponse([receipt.replacingOccurrences(of: #""resource_id":"22222222-2222-4222-8222-222222222222""#, with: #""resource_id":"22222222-2222-4222-8222-222222222229""#), conflict, skipped])),
            ("a receipt for another mutation", self.batchResponse([receipt.replacingOccurrences(of: #""receipt":{"mutation_id":"11111111-1111-4111-8111-111111111111""#, with: #""receipt":{"mutation_id":"11111111-1111-4111-8111-111111111112""#), conflict, skipped])),
            ("an item status outside the wire", self.batchResponse([receipt, conflict.replacingOccurrences(of: #""status":409"#, with: #""status":500"#), skipped])),
            ("a 200 with an error", self.batchResponse([receipt, conflict.replacingOccurrences(of: #""status":409"#, with: #""status":200"#), skipped])),
            ("skipped false", self.batchResponse([receipt, conflict, skipped.replacingOccurrences(of: "true", with: "false")])),
            ("an error that breaks its rules", self.batchResponse([receipt, conflict.replacingOccurrences(of: #","fields":["title"]"#, with: ""), skipped])),
            ("an unknown key", self.batchResponse([receipt, conflict, skipped.replacingOccurrences(of: #""skipped":true"#, with: #""skipped":true,"why":"x""#)])),
            ("retry_after zero", self.batchResponse([receipt, conflict, skipped], retryAfter: "0")),
            ("retry_after a string", self.batchResponse([receipt, conflict, skipped], retryAfter: #""120""#))
        ]
        for (name, text) in broken {
            XCTAssertThrowsError(try self.decodeBatch(text, request), name)
        }
    }

    func test_anItem401IsKeptForTheSessionMachinery() throws {
        let create = try self.sealedCreate("11111111-1111-4111-8111-111111111111", list: self.r4ListId)
        let second = try self.sealedCreate("11111111-1111-4111-8111-111111111112", list: "22222222-2222-4222-8222-222222222223")
        let request = try SGTasksWire.MutationBatchRequest(batchId: self.uuid(self.batchId), items: [.init(create), .init(second)])
        let decoded = try self.decodeBatch(self.batchResponse([
            #"{"mutation_id":"11111111-1111-4111-8111-111111111111","status":401,"error":{"error":"device_revoked","message":"m"}}"#,
            #"{"mutation_id":"11111111-1111-4111-8111-111111111112","status":401,"error":{"error":"invalid_token","message":"m"}}"#
        ]), request)
        XCTAssertEqual(decoded.response.results.first, .error(status: 401, SGTasksError(kind: .session(.deviceRevoked), serverTime: SGTasksWire.Instant("2026-10-24T00:00:05Z")?.date)))
        XCTAssertEqual(decoded.response.results.last, .error(status: 401, SGTasksError(kind: .session(.invalidToken), serverTime: SGTasksWire.Instant("2026-10-24T00:00:05Z")?.date)))
        XCTAssertEqual(decoded.sessionFailures.map { $0.code }, ["device_revoked", "invalid_token"], "in item order")
        XCTAssertEqual(decoded.sessionFailures.first, SGEntitlementRequestError(failure: .session(.deviceRevoked), serverTime: SGTasksWire.Instant("2026-10-24T00:00:05Z")?.date, status: 401, code: "device_revoked"))
        let withReason = #"{"mutation_id":"11111111-1111-4111-8111-111111111111","status":401,"error":{"error":"device_revoked","message":"m","reason":"account_erased"}}"#
        XCTAssertThrowsError(try self.decodeBatch(self.batchResponse([withReason, #"{"mutation_id":"11111111-1111-4111-8111-111111111112","status":null,"skipped":true}"#]), request), "BatchItemError follows ErrorRules")
    }
}

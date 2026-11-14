import Foundation

/// Zenlygram — a failed Tasks call (`SGEntitlement.tasksMutation` / `tasksMutationBatch` /
/// `tasksSnapshot` / `tasksChanges`) or batch item, already classified. It carries allowlisted codes
/// only: no server message, no request content, no credential.
///
/// `kind` is the R3 classification and a closed set (the cloud engine switches over it
/// exhaustively); an R4 answer it has no case for keeps its R3 class there — exactly what an R3
/// client concludes from it — and says what it really is in `refinement`.
public struct SGTasksError: Error, Equatable {
    /// R4 (`X-Tasks-Wire: 4`) answers, each with the R3 `kind` it keeps.
    public enum Refinement: Equatable {
        /// `403 tasks_consent_required` (every wire and route, and per batch item): a processed
        /// consent withdrawal stands. `kind` `.rejected(status:)`. NEVER terminal for an entry:
        /// requeue it without an attempt and pause the account's Tasks traffic with backoff.
        /// `effectiveAt` is the withdrawal's `effective_at` (a wire `Instant`), when readable.
        case consentRequired(effectiveAt: String?)
        /// `409 tasks_conflict` `field_changed` (`task.patch`): these fields, in content order, hold
        /// neither the `expect` nor the `set` value. `kind` `.conflict(.revisionChanged)`.
        case fieldChanged(fields: [SGTasksWire.ContentField])
        /// `409 tasks_conflict` `members_changed` (members-fenced `list.delete`). `kind`
        /// `.conflict(.revisionChanged)`.
        case membersChanged
        /// `503 tasks_unavailable` `migration_paused` (a `migration`-origin batch item): hold the
        /// migration entries until `retryAfter`; user entries keep going. `kind` `.unavailable`,
        /// not committed.
        case migrationPaused
        /// `503 tasks_unavailable` `batch_disabled` (the batch route, before authentication): send
        /// user entries through the single route. `kind` `.unavailable`, nothing ran.
        case batchDisabled
    }

    public enum Kind: Equatable {
        /// This build has no entitlement server. Nothing was sent.
        case notConfigured
        /// No stored session for the account (never bound, or logged out). Nothing was sent.
        case notSignedIn
        /// `403 tasks_account_not_linked`: a VALID session with no verified Telegram link. Pause the
        /// account's sync with no automatic retry; the refresh token, cached JWS, binding, key,
        /// caches, outbox and cursors are all untouched. Only explicit Telegram linking recovers.
        case accountNotLinked
        /// `403 tasks_creation_not_permitted`: keep the blocked draft; never resend automatically.
        case creationNotPermitted
        /// `404 tasks_not_found`.
        case notFound
        /// `409 tasks_conflict` with its required reason.
        case conflict(SGTasksWire.ConflictReason)
        /// `409 tasks_resync_required`: the cursor is no longer usable — restart the snapshot.
        case resyncRequired
        /// `409 tasks_mutation_in_flight`: retry later with the SAME mutation.
        case mutationInFlight
        /// `422 tasks_invalid_request`.
        case invalidRequest
        /// `422 tasks_mutation_mismatch`: same id, different business bytes — a client-integrity bug.
        case mutationMismatch
        /// `429` (`retryAfter` when given).
        case rateLimited
        /// `503 tasks_unavailable`, or any other 5xx.
        case unavailable
        /// The DeviceAuth 401 family. Already handed to `SGEntitlement.apply` for the exact session
        /// the request presented; nothing else to do here.
        case session(SGEntitlementSessionFailure)
        /// The account's session changed (rotation, logout, re-bind) while this call waited or was in
        /// flight: its answer was discarded. Call again; a fresh session is read then.
        case credentialChanged
        /// No answer: timeout, offline, cancelled.
        case transport(SGEntitlementOfflineCause)
        /// A 2xx that broke the wire (shape, bounds, receipt not matching the request), or a body
        /// over the response bound.
        case malformedResponse
        /// Any other non-success status (413 whatever its code, 405, an unknown 4xx code, ...).
        case rejected(status: Int)
        /// A local argument out of bounds (page limit). Nothing was sent.
        case invalidLocalRequest
    }

    public let kind: Kind
    /// Seconds, from `Retry-After` (or a body `retry_after`), clamped to 0...86400.
    public let retryAfter: Int?
    /// `server_time` of the error body (of the batch, for an item), when one was read.
    public let serverTime: Date?
    /// The mutation's bytes may have reached the server and committed (timeout, lost connection,
    /// 5xx after send). Resolve by sending the SAME `MutationRequest` again — never a new id.
    public let outcomeUnknown: Bool
    /// What an R4 answer really is when `kind` has no case for it; nil for every R3 answer.
    public let refinement: Refinement?

    public init(kind: Kind, retryAfter: Int? = nil, serverTime: Date? = nil, outcomeUnknown: Bool = false, refinement: Refinement? = nil) {
        self.kind = kind
        self.retryAfter = retryAfter
        self.serverTime = serverTime
        self.outcomeUnknown = outcomeUnknown
        self.refinement = refinement
    }
}

/// The single place that turns a Tasks HTTP answer — or one batch item's answer — into
/// `SGTasksError`. The Tasks stable code decides first; only a non-Tasks code falls through to the
/// existing entitlement classification, whose session family is the ONLY thing ever handed to
/// `SGEntitlement.apply`.
enum SGTasksErrorClassifier {
    static let maxRetryAfter = 86400
    /// Error bodies are parsed no further than this.
    static let errorBodyLimit = 65536

    struct Classified: Equatable {
        let error: SGTasksError
        /// The existing classification, kept for the retry decision and for `apply` (session only).
        let entitlementFailure: SGEntitlementFailureClass?
        /// Exactly when `entitlementFailure` is a session failure: the error as `SGEntitlement.apply`
        /// takes it — status, code and the body's `reason` (`account_erased` ends the session with
        /// that reason recorded).
        let sessionError: SGEntitlementRequestError?
    }

    /// The parts of an error body classification may use. Never the `message`.
    struct Envelope: Equatable {
        var code: String?
        /// As sent (1...80 scalars): a Tasks reason (`ErrorReason`) or a DeviceAuth one.
        var reason: String?
        /// `field_changed` only, in content order.
        var fields: [SGTasksWire.ContentField]?
        var effectiveAt: SGTasksWire.Instant?
        var retryAfter: Int?
        var serverTime: Date?
    }

    /// ERROR bodies only. The strict wire `Error` first; otherwise a bounded read of the top-level
    /// `error` / `reason` / `fields` / `effective_at` / `retry_after` / `server_time` of an existing
    /// middleware envelope (a DeviceAuth 401 with its `reason`, among others), whose metadata may
    /// carry fractions or exponents the success decoder refuses. Byte, depth and UTF-8 bounds still
    /// apply, and a body with duplicate keys has no trustworthy code at all.
    static func envelope(_ body: Data) -> Envelope {
        if let value = try? SGTasksJSON.parse(body, maxBytes: self.errorBodyLimit, maxDepth: SGTasksWire.maxDepth), let strict = SGTasksWireCodec.decodeError(value) {
            return Envelope(code: strict.error, reason: strict.reason?.rawValue, fields: strict.fields.isEmpty ? nil : strict.fields, effectiveAt: strict.effectiveAt, retryAfter: nil, serverTime: strict.serverTime.date)
        }
        guard case let .object(members)? = try? SGTasksJSON.parse(body, maxBytes: self.errorBodyLimit, maxDepth: SGTasksWire.maxDepth, lenientNumbers: true) else {
            return Envelope()
        }
        var envelope = Envelope()
        for member in members {
            switch (member.name, member.value) {
            case let ("error", .string(text)) where (1 ... 80).contains(text.unicodeScalars.count):
                envelope.code = text
            case let ("reason", .string(text)) where (1 ... 80).contains(text.unicodeScalars.count):
                envelope.reason = text
            case let ("fields", value):
                envelope.fields = SGTasksWireCodec.conflictFields(value)
            case let ("effective_at", .string(text)):
                envelope.effectiveAt = SGTasksWire.Instant(text)
            case let ("retry_after", .integer(seconds)):
                envelope.retryAfter = Int(clamping: seconds)
            case let ("server_time", .string(text)):
                envelope.serverTime = SGTasksWire.Instant(text)?.date
            default:
                break
            }
        }
        return envelope
    }

    static func classify(status: Int, body: Data, retryAfterHeader: Int?, isMutation: Bool) -> Classified {
        return self.classify(status: status, envelope: self.envelope(body), retryAfterHeader: retryAfterHeader, isMutation: isMutation)
    }

    /// One batch item's answer (`BatchItemResult` with an error status), by the same table as an
    /// envelope. `error` is the embedded `BatchItemError`, validated strictly (it is part of a 200
    /// body); nil when it breaks the schema. `serverTime` is the batch's; `retryAfter` the batch's
    /// top-level value, used for a 429 / 503 item that names none itself.
    static func classifyItem(status: Int, error: SGTasksJSON.Value, serverTime: Date?, retryAfter: Int?) -> Classified? {
        guard let item = try? SGTasksWireCodec.decodeBatchItemError(error, status: status, path: "error") else {
            return nil
        }
        let envelope = Envelope(
            code: item.code,
            reason: item.extras.reason?.rawValue,
            fields: item.extras.fields.isEmpty ? nil : item.extras.fields,
            effectiveAt: item.extras.effectiveAt,
            retryAfter: item.retryAfter ?? (status == 429 || status == 503 ? retryAfter : nil),
            serverTime: serverTime
        )
        return self.classify(status: status, envelope: envelope, retryAfterHeader: nil, isMutation: true)
    }

    /// The table, shared by envelopes and batch items.
    static func classify(status: Int, envelope: Envelope, retryAfterHeader: Int?, isMutation: Bool) -> Classified {
        let code = envelope.code
        let serverTime = envelope.serverTime
        let retryAfter = (retryAfterHeader ?? envelope.retryAfter).map { min(max($0, 0), self.maxRetryAfter) }
        let reason = envelope.reason.flatMap(SGTasksWire.ErrorReason.init(rawValue:))
        func make(_ kind: SGTasksError.Kind, unknown: Bool = false, failure: SGEntitlementFailureClass? = nil, sessionError: SGEntitlementRequestError? = nil, refinement: SGTasksError.Refinement? = nil) -> Classified {
            return Classified(error: SGTasksError(kind: kind, retryAfter: retryAfter, serverTime: serverTime, outcomeUnknown: unknown && isMutation, refinement: refinement), entitlementFailure: failure, sessionError: sessionError)
        }

        // Status first. Any 5xx — whatever code its body names, `tasks_unavailable` for an
        // unconfirmed COMMIT included — may have committed a mutation: resend the SAME one. The two
        // R4 503 reasons are deliberate refusals of work that never ran.
        if status >= 500 {
            if status == 503, code == "tasks_unavailable" {
                switch reason {
                case .migrationPaused?:
                    return make(.unavailable, refinement: .migrationPaused)
                case .batchDisabled?:
                    return make(.unavailable, refinement: .batchDisabled)
                default:
                    break
                }
            }
            return make(.unavailable, unknown: true)
        }
        if status == 429 {
            return make(.rateLimited)
        }
        // An oversized request, whatever code names it (the batch route's 413 is
        // `tasks_invalid_request`): a bounded transport refusal the sender can answer by sending less.
        if status == 413 {
            return make(.rejected(status: status))
        }

        switch code ?? "" {
        case "tasks_account_not_linked":
            return make(.accountNotLinked)
        case "tasks_creation_not_permitted":
            return make(.creationNotPermitted)
        case "tasks_consent_required":
            // An unknown code to the R3 classification: a refusal, which is what an R3 client makes
            // of it. Never terminal (see `Refinement.consentRequired`).
            return make(.rejected(status: status), refinement: .consentRequired(effectiveAt: envelope.effectiveAt?.rawValue))
        case "tasks_not_found":
            return make(.notFound)
        case "tasks_conflict":
            switch reason {
            case .fieldChanged?:
                guard let fields = envelope.fields, !fields.isEmpty else {
                    // Without its fields a field conflict cannot be resolved: not a usable conflict.
                    return make(.malformedResponse)
                }
                return make(.conflict(.revisionChanged), refinement: .fieldChanged(fields: fields))
            case .membersChanged?:
                return make(.conflict(.revisionChanged), refinement: .membersChanged)
            default:
                guard let conflict = reason?.conflictReason else {
                    return make(.malformedResponse)
                }
                return make(.conflict(conflict))
            }
        case "tasks_resync_required":
            return make(.resyncRequired)
        case "tasks_mutation_in_flight":
            return make(.mutationInFlight)
        case "tasks_invalid_request":
            return make(.invalidRequest)
        case "tasks_mutation_mismatch":
            return make(.mutationMismatch)
        case "tasks_rate_limited", "tasks_unavailable":
            // Only meaningful under their documented 429 / 503, handled above.
            return make(.rejected(status: status))
        default:
            break
        }

        // The DeviceAuth family speaks in HTTP 401 only. The same code under any other status (a
        // proxy, a framework page) is not about this session and must never drop it.
        guard status == 401 else {
            return make(.rejected(status: status))
        }
        let failure = SGEntitlementFailureMapping.classify(status: status, code: code, retryAfter: retryAfter)
        if case let .session(cause) = failure {
            let sessionError = SGEntitlementRequestError(failure: failure, serverTime: serverTime, retryAfter: retryAfter, status: status, code: code, reason: envelope.reason)
            return make(.session(cause), failure: failure, sessionError: sessionError)
        }
        // A 401 refusal outside the DeviceAuth family (`apple_jws_invalid`, an unknown code).
        return make(.rejected(status: status))
    }

    /// A transport outcome with no HTTP answer. Only name resolution and TLS failures prove the
    /// request never left the device; everything else — `noRoute` included, since the interface can
    /// drop after the bytes were written — may have reached the server.
    static func transport(_ failure: SGEntitlementFailureClass, isMutation: Bool) -> SGTasksError {
        guard case let .offline(cause) = failure else {
            return SGTasksError(kind: .malformedResponse, outcomeUnknown: isMutation)
        }
        switch cause {
        case .malformedResponse:
            return SGTasksError(kind: .malformedResponse, outcomeUnknown: isMutation)
        case .dns, .tls:
            return SGTasksError(kind: .transport(cause), outcomeUnknown: false)
        case .noRoute, .timeout, .connectionLost, .cancelled, .serverError, .unknown:
            return SGTasksError(kind: .transport(cause), outcomeUnknown: isMutation)
        }
    }
}

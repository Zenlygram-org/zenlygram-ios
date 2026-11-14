import Foundation
import Postbox
import SwiftSignalKit

/// SG: gate on uploading outgoing media that carries a file from a governed local directory
/// (Zenlygram call recordings). Checked by `messageContentToUpload` when the upload starts —
/// Telegram's Retry and every restart included — before the content is built or any byte is read
/// or sent, and kept watching until the content is ready. Ordinary messages are never governed.
/// Fails closed: no decider, no verdict in time, an empty verdict stream or `false` all deny.
public enum OutgoingLocalFileUploadGate {
    public struct Request: Equatable {
        /// The uploading Postbox instance: one account database, one incarnation.
        public let postboxIdentity: ObjectIdentifier
        public let accountPeerId: EnginePeer.Id
        /// Destination chat.
        public let peerId: EnginePeer.Id
        public let messageId: EngineMessage.Id
        /// Standardized (`NSString.standardizingPath`).
        public let localFilePath: String
        public let resourceRandomId: Int64
    }

    /// A stream of verdicts for one request; the latest value is the current verdict.
    public typealias Decider = (Request) -> Signal<Bool, NoError>

    public static let governedDirectoryName = "zenlygram-call-recordings"
    public static let firstVerdictTimeout: Double = 30.0

    private static let decider = Atomic<Decider?>(value: nil)

    /// Register-once. A later call is ignored (and asserts): no module can replace the decider.
    @discardableResult
    public static func setDecider(_ value: @escaping Decider) -> Bool {
        var installed = false
        let _ = OutgoingLocalFileUploadGate.decider.modify { current in
            if current == nil {
                installed = true
                return value
            }
            return current
        }
        assert(installed, "OutgoingLocalFileUploadGate decider registered twice")
        return installed
    }

    /// What app-side deciders compare `Request.postboxIdentity` against.
    public static func postboxIdentity(account: Account) -> ObjectIdentifier {
        return ObjectIdentifier(account.postbox)
    }

    /// The registered decider, read at SUBSCRIPTION time by the wrapper.
    static func registeredDecider() -> Decider? {
        return OutgoingLocalFileUploadGate.decider.with({ $0 })
    }

    enum Governance {
        case notGoverned
        case deny
        case decide(Request)
    }

    static func isGovernedPath(_ path: String) -> Bool {
        return (path as NSString).pathComponents.contains(OutgoingLocalFileUploadGate.governedDirectoryName)
    }

    private static func collect(_ resource: MediaResource, into result: inout [LocalFileReferenceMediaResource]) {
        if let resource = resource as? LocalFileReferenceMediaResource, OutgoingLocalFileUploadGate.isGovernedPath(resource.localFilePath) {
            result.append(resource)
        }
    }

    private static func collect(_ media: Media, into result: inout [LocalFileReferenceMediaResource]) {
        if let file = media as? TelegramMediaFile {
            collect(file.resource, into: &result)
            for representation in file.previewRepresentations {
                collect(representation.resource, into: &result)
            }
            for thumbnail in file.videoThumbnails {
                collect(thumbnail.resource, into: &result)
            }
            if let cover = file.videoCover {
                collect(cover, into: &result)
            }
            for alternative in file.alternativeRepresentations {
                collect(alternative, into: &result)
            }
        } else if let image = media as? TelegramMediaImage {
            for representation in image.representations {
                collect(representation.resource, into: &result)
            }
        } else if let paid = media as? TelegramMediaPaidContent {
            for extended in paid.extendedMedia {
                if case let .full(fullMedia) = extended {
                    collect(fullMedia, into: &result)
                }
            }
        }
    }

    static func governance(accountPeerId: PeerId, peerId: PeerId, postbox: Postbox, messageId: MessageId?, attributes: [MessageAttribute], media: [Media]) -> Governance {
        var governed: [LocalFileReferenceMediaResource] = []
        for item in media {
            collect(item, into: &governed)
        }
        if peerId.namespace != Namespaces.Peer.SecretChat, let rich = attributes.first(where: { $0 is RichTextMessageAttribute }) as? RichTextMessageAttribute {
            for item in rich.instantPage.media.values {
                collect(item, into: &governed)
            }
        }
        if governed.isEmpty {
            return .notGoverned
        }
        // A recording message carries exactly one governed file, is an ordinary outgoing media
        // message, and is not a forward, an inline-bot result or a screenshot notice.
        guard governed.count == 1 else {
            return .deny
        }
        if attributes.contains(where: { $0 is ForwardSourceInfoAttribute || $0 is OutgoingChatContextResultMessageAttribute }) {
            return .deny
        }
        if media.contains(where: { ($0 as? TelegramMediaAction)?.action == .historyScreenshot }) {
            return .deny
        }
        guard let messageId, messageId.namespace == Namespaces.Message.Local, messageId.peerId == peerId, peerId == accountPeerId else {
            return .deny
        }
        let resource = governed[0]
        return .decide(Request(postboxIdentity: ObjectIdentifier(postbox), accountPeerId: accountPeerId, peerId: peerId, messageId: messageId, localFilePath: (resource.localFilePath as NSString).standardizingPath, resourceRandomId: resource.randomId))
    }
}

private enum OutgoingLocalFileUploadGatePhase {
    case waiting
    case running
    case finished
}

public extension OutgoingLocalFileUploadGate {
    /// ONE subscription to `verdicts`. The first `true` builds and starts `content` once; a later
    /// `true` is ignored (no restart). `false` while waiting or running disposes content immediately
    /// (even before its first event) and fails with `denied`. A verdict stream that completes before
    /// any `true`, or no verdict within `firstVerdictTimeout`, fails with `denied`. The watchdog acts
    /// ONLY while waiting (phase-checked), so a re-armed timer can never deny a running upload. Once
    /// `isFinal` content is forwarded the verdict subscription is dropped: a late revocation cannot
    /// fail a message that already went to the send step.
    ///
    /// Cancellation precision: disposing the gate marks it finished BEFORE anything else, and the
    /// content factory runs outside the start of its signal — `running` is re-checked after the
    /// factory returns, so a revocation or disposal that lands while the factory is still building
    /// can never be followed by the upload starting.
    static func gate<T, E>(verdicts: Signal<Bool, NoError>, firstVerdictTimeout: Double, timeoutQueue: Queue, denied: E, isFinal: @escaping (T) -> Bool, content: @escaping () -> Signal<T, E>) -> Signal<T, E> {
        return Signal { subscriber in
            let phase = Atomic<OutgoingLocalFileUploadGatePhase>(value: .waiting)
            let verdictDisposable = MetaDisposable()
            let contentDisposable = MetaDisposable()
            func move(_ from: OutgoingLocalFileUploadGatePhase, _ to: OutgoingLocalFileUploadGatePhase) -> Bool {
                var moved = false
                let _ = phase.modify { current in
                    if current == from {
                        moved = true
                        return to
                    }
                    return current
                }
                return moved
            }
            let watchdog = SwiftSignalKit.Timer(timeout: firstVerdictTimeout, repeat: false, completion: {
                if move(.waiting, .finished) {
                    verdictDisposable.dispose()
                    subscriber.putError(denied)
                }
            }, queue: timeoutQueue)
            // Armed BEFORE the verdict subscription, so a synchronous first verdict cannot run
            // before it exists; acting is phase-guarded anyway.
            watchdog.start()
            verdictDisposable.set(verdicts.start(next: { allowed in
                if allowed {
                    guard move(.waiting, .running) else {
                        return
                    }
                    watchdog.invalidate()
                    // Built first, started only if still running: the factory may block, and a
                    // revocation or disposal during it must win.
                    let contentSignal = content()
                    guard phase.with({ $0 == .running }) else {
                        return
                    }
                    contentDisposable.set(contentSignal.start(next: { value in
                        if isFinal(value) {
                            if move(.running, .finished) {
                                verdictDisposable.dispose()
                                subscriber.putNext(value)
                                subscriber.putCompletion()
                            }
                        } else if phase.with({ $0 == .running }) {
                            subscriber.putNext(value)
                        }
                    }, error: { error in
                        if move(.running, .finished) {
                            verdictDisposable.dispose()
                            subscriber.putError(error)
                        }
                    }, completed: {
                        if move(.running, .finished) {
                            verdictDisposable.dispose()
                            subscriber.putCompletion()
                        }
                    }))
                } else if move(.waiting, .finished) || move(.running, .finished) {
                    watchdog.invalidate()
                    contentDisposable.dispose()
                    subscriber.putError(denied)
                }
            }, completed: {
                // Completing before any allow is a denial. Completing while running only means no
                // further revocation can come; the upload continues.
                if move(.waiting, .finished) {
                    watchdog.invalidate()
                    subscriber.putError(denied)
                }
            }))
            return ActionDisposable {
                // Finished FIRST, so nothing racing this disposal can start or forward anything.
                let _ = phase.modify { _ in
                    return .finished
                }
                watchdog.invalidate()
                verdictDisposable.dispose()
                contentDisposable.dispose()
            }
        }
    }
}

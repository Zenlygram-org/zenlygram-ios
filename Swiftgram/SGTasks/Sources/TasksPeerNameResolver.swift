import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
#if canImport(SGEntitlement)
import SGEntitlement
#endif

// Zenlygram — Tasks: the name shown for another Telegram user on a task (wf15 §5.6). A name comes
// only from the viewer's own contacts (`Peer(id:)` of a raw Telegram id, `tasksCloudLocalUserName`);
// anyone else stays the numeric "Telegram foydalanuvchisi N" that the caller formats. Looked up on the
// device, cached for the board's lifetime, never persisted and never sent. The owner-side fallbacks
// before the numeric id (a mapped device row's name, a legacy annotation's name) are not this
// resolver's — the pure `TasksAssigneeNameFallback` orders them after the contact name.

final class TasksPeerNameResolver {
    private let context: AccountContext
    /// Resolved ids: the contact's name, or nil when the id is not one of the viewer's contacts.
    private var cache: [SGTasksWire.TelegramId: String?] = [:]
    private var inFlight = Set<SGTasksWire.TelegramId>()
    private let disposables = DisposableSet()
    /// Called on the main queue once more names are known (the caller re-renders).
    var changed: (() -> Void)?

    init(context: AccountContext) {
        self.context = context
    }

    deinit {
        self.disposables.dispose()
    }

    /// The contact name known so far; nil while unknown or for a non-contact.
    func cachedName(for id: SGTasksWire.TelegramId) -> String? {
        return self.cache[id] ?? nil
    }

    /// Every id resolved so far, for the renderer.
    var cachedNames: [SGTasksWire.TelegramId: String] {
        var names: [SGTasksWire.TelegramId: String] = [:]
        for (id, name) in self.cache {
            if let name {
                names[id] = name
            }
        }
        return names
    }

    /// Forgets every name (the contacts may have changed: a board appearance, a picker closed).
    func invalidate() {
        self.cache.removeAll()
    }

    /// Looks up the ids not cached yet; `changed` fires when they arrive.
    func resolve(_ ids: Set<SGTasksWire.TelegramId>) {
        let missing = ids.filter { self.cache[$0] == nil && !self.inFlight.contains($0) }
        guard !missing.isEmpty else {
            return
        }
        self.inFlight.formUnion(missing)
        let disposable = (self.names(for: missing)
        |> deliverOnMainQueue).start(next: { [weak self] names in
            guard let self else {
                return
            }
            for id in missing {
                self.inFlight.remove(id)
                self.cache[id] = .some(names[id])
            }
            self.changed?()
        })
        self.disposables.add(disposable)
    }

    /// One-shot: the contact names among `ids` (absent = not a contact, or no visible name).
    func names(for ids: Set<SGTasksWire.TelegramId>) -> Signal<[SGTasksWire.TelegramId: String], NoError> {
        guard !ids.isEmpty else {
            return .single([:])
        }
        let pairs = ids.map { (id: $0, peerId: EnginePeer.Id(tasksCloudPackedUserPeerId($0))) }
        let context = self.context
        return context.engine.data.get(
            EngineDataMap(pairs.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0.peerId) }),
            EngineDataMap(pairs.map { TelegramEngine.EngineData.Item.Peer.IsContact(id: $0.peerId) })
        )
        |> map { peers, contacts -> [SGTasksWire.TelegramId: String] in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            var names: [SGTasksWire.TelegramId: String] = [:]
            for pair in pairs {
                guard contacts[pair.peerId] == true, let peer = peers[pair.peerId] ?? nil else {
                    continue
                }
                if let name = tasksCloudLocalUserName(peer, presentationData: presentationData) {
                    names[pair.id] = name
                }
            }
            return names
        }
    }
}

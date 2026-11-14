import Foundation
import SGEntitlement

// MARK: - Durable manual answers to invitations (wf15 §5.3, D2)
//
// What the user decided by hand about an invitation must never be undone by the automatic accept
// of a contact's task (`SGTasksAutoAcceptPolicy`): a manual Accept, Decline or Block records the
// invitation id; a manual Decline or Leave also records the task id, so that every later epoch of
// that task (the owner's Qayta yuborish) waits in Takliflar even from a contact. The record lives
// in `UserDefaults` under `sgtasks.inviteAnswers.<accountPeerId>` as the JSON
// `{"i":{invitationId: unixSeconds}, "t":{taskId: unixSeconds}}` — content-free UUIDs and times,
// nothing about the task or the people — because the per-account cloud store is purged by every
// logout (F13) and the server hides non-pending invitations, so after a re-login nothing could
// rebuild it. It therefore survives every logout, the last one included (revision 2:
// `SGTasksLocalMarkers.removeAll()` of WP-I6 skips this key); it goes only with the app or by its
// own prune: invitation ids older than 8 days (an invitation lives 7), task ids beyond the 500
// newest. Only manual answers are recorded; the policy's `leaveForUser` never is, so adding a
// contact later still accepts every invitation the user never answered.

public struct SGTasksInviteAnswers: Equatable {
    /// An invitation lives 7 UTC days; a recorded id is kept one day longer.
    public static let invitationRetention: TimeInterval = 8 * 86400
    /// Refused task ids are capped at the newest this many.
    public static let maximumRefusedTasks = 500

    /// Invitation id → the unix time (seconds) of the manual answer.
    public private(set) var invitationIds: [String: Int64]
    /// Task id → the unix time (seconds) of the manual decline or leave.
    public private(set) var refusedTaskIds: [String: Int64]

    public static let empty = SGTasksInviteAnswers(invitationIds: [:], refusedTaskIds: [:])

    public init(invitationIds: [String: Int64], refusedTaskIds: [String: Int64]) {
        self.invitationIds = invitationIds
        self.refusedTaskIds = refusedTaskIds
    }

    public var isEmpty: Bool {
        return self.invitationIds.isEmpty && self.refusedTaskIds.isEmpty
    }

    /// This invitation was answered by hand (queued, in flight, sent or resealed).
    public func answered(invitationId: SGTasksWire.UUID) -> Bool {
        return self.invitationIds[invitationId.rawValue] != nil
    }

    /// This task was declined or left by hand: no later epoch of it is accepted automatically.
    public func refused(taskId: SGTasksWire.UUID) -> Bool {
        return self.refusedTaskIds[taskId.rawValue] != nil
    }

    public mutating func recordInvitation(_ id: SGTasksWire.UUID, at now: Date) {
        self.invitationIds[id.rawValue] = Self.seconds(now)
    }

    public mutating func recordRefusedTask(_ id: SGTasksWire.UUID, at now: Date) {
        self.refusedTaskIds[id.rawValue] = Self.seconds(now)
    }

    /// Invitation ids older than `invitationRetention` go; task ids are capped at the
    /// `maximumRefusedTasks` newest (ties by id, so the result is deterministic).
    public mutating func prune(now: Date) {
        let cutoff = Self.seconds(now) - Int64(Self.invitationRetention)
        self.invitationIds = self.invitationIds.filter { $0.value > cutoff }
        if self.refusedTaskIds.count > Self.maximumRefusedTasks {
            let kept = self.refusedTaskIds
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(Self.maximumRefusedTasks)
            self.refusedTaskIds = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
    }

    // MARK: Encoding (`{"i":{…},"t":{…}}`)

    public init?(json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        self.invitationIds = Self.decodeTable(object["i"])
        self.refusedTaskIds = Self.decodeTable(object["t"])
    }

    public var json: Data {
        let object: [String: Any] = ["i": Self.encodeTable(self.invitationIds), "t": Self.encodeTable(self.refusedTaskIds)]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{\"i\":{},\"t\":{}}".utf8)
    }

    private static func decodeTable(_ value: Any?) -> [String: Int64] {
        guard let table = value as? [String: Any] else { return [:] }
        var out: [String: Int64] = [:]
        for (key, raw) in table {
            guard SGTasksWire.UUID(key) != nil, let number = raw as? NSNumber else { continue }
            out[key] = number.int64Value
        }
        return out
    }

    private static func encodeTable(_ table: [String: Int64]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in table {
            out[key] = NSNumber(value: value)
        }
        return out
    }

    private static func seconds(_ date: Date) -> Int64 {
        return Int64(date.timeIntervalSince1970.rounded(.down))
    }
}

/// The `UserDefaults` persistence of `SGTasksInviteAnswers`, per account. Every read prunes; every
/// write prunes and stores. The key prefix is what WP-I6's `SGTasksLocalMarkers.removeAll()` must
/// skip (revision 2).
public enum SGTasksInviteAnswersStore {
    public static let keyPrefix = "sgtasks.inviteAnswers."

    public static func key(accountPeerId: Int64) -> String {
        return self.keyPrefix + String(accountPeerId)
    }

    public static func load(defaults: UserDefaults, accountPeerId: Int64, now: Date) -> SGTasksInviteAnswers {
        var answers: SGTasksInviteAnswers = .empty
        if let raw = defaults.string(forKey: self.key(accountPeerId: accountPeerId)), let decoded = SGTasksInviteAnswers(json: Data(raw.utf8)) {
            answers = decoded
        }
        answers.prune(now: now)
        return answers
    }

    public static func save(_ answers: SGTasksInviteAnswers, defaults: UserDefaults, accountPeerId: Int64) {
        let key = self.key(accountPeerId: accountPeerId)
        if answers.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(String(decoding: answers.json, as: UTF8.self), forKey: key)
        }
    }

    /// A manual Accept, Decline or Block of `invitationId`; `refusedTaskId` for a Decline (its task).
    public static func recordInvitation(_ invitationId: SGTasksWire.UUID, refusedTaskId: SGTasksWire.UUID? = nil, defaults: UserDefaults, accountPeerId: Int64, now: Date) {
        var answers = self.load(defaults: defaults, accountPeerId: accountPeerId, now: now)
        answers.recordInvitation(invitationId, at: now)
        if let taskId = refusedTaskId {
            answers.recordRefusedTask(taskId, at: now)
        }
        answers.prune(now: now)
        self.save(answers, defaults: defaults, accountPeerId: accountPeerId)
    }

    /// A manual Leave of the task (its accepted epoch's id is recorded too).
    public static func recordRefusedTask(_ taskId: SGTasksWire.UUID, invitationId: SGTasksWire.UUID?, defaults: UserDefaults, accountPeerId: Int64, now: Date) {
        var answers = self.load(defaults: defaults, accountPeerId: accountPeerId, now: now)
        answers.recordRefusedTask(taskId, at: now)
        if let invitationId = invitationId {
            answers.recordInvitation(invitationId, at: now)
        }
        answers.prune(now: now)
        self.save(answers, defaults: defaults, accountPeerId: accountPeerId)
    }
}

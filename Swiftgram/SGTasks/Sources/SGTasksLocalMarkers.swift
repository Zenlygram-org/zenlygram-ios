import Foundation

// MARK: - Zenlygram Tasks wf15 §7.4: the durable per-account markers outside the purgeable store
//
// The device database has no free meta table (F13) and a Telegram logout purges the account's whole
// cloud store file, so the markers that must outlive a logout live in `UserDefaults`, keyed per
// account and content-free (never a title, a name or a Telegram id of anyone else):
//
//   sgtasks.legacyAssignees.<accountPeerId>            = "<record.claimedAt>:<later|done>"   the D4 sheet
//   sgtasks.legacyAssignees.remaining.<accountPeerId>  = Int                                   device-row candidates still unsent
//   sgtasks.legacyAssignees.sent.<accountPeerId>       = [cloud task id]                       the durable sent set
//   sgtasks.assignExplainer.<accountPeerId>, sgtasks.consentPrompted.<accountPeerId>,
//   sgtasks.notice.otherAccount.<accountPeerId>, sgtasks.scopeKeysRemoved                       the other wf15 markers
//
// Two kinds of logout (§7.4): a logout that leaves another account signed in keeps every key (the
// device database with its record, mappings and rows survives too, so a sent legacy assignee stays
// sent and the sheet does not return); the LAST logout wipes the device database (F16) and
// `removeAll()` removes every `sgtasks.*` key next to it — except `sgtasks.inviteAnswers.*`, the
// durable manual invitation answers of §5.3, which survive every logout (revision 2).

public enum SGTasksLocalMarkers {
    /// Every per-account marker of this module starts with it.
    public static let keyPrefix = "sgtasks."
    /// The keys `removeAll()` keeps (`SGTasksInviteAnswersStore.keyPrefix`; spelled out here so the
    /// pure markers compile without the answers' file).
    public static let preservedPrefixes = ["sgtasks.inviteAnswers."]

    // MARK: Keys

    public static func legacyOfferKey(accountPeerId: Int64) -> String {
        return "sgtasks.legacyAssignees.\(accountPeerId)"
    }

    public static func remainingKey(accountPeerId: Int64) -> String {
        return "sgtasks.legacyAssignees.remaining.\(accountPeerId)"
    }

    public static func sentKey(accountPeerId: Int64) -> String {
        return "sgtasks.legacyAssignees.sent.\(accountPeerId)"
    }

    // MARK: The D4 marker (§7.1, §7.3)

    /// How the one-time sheet ended for a migration record: Keyinroq (`later`) or Yuborish (`done`).
    /// Either way the sheet never returns by itself for that record.
    public enum LegacyOfferMarker: String, Equatable {
        case later
        case done
    }

    /// The marker written for the record claimed at `claimedAt`; a value bound to another
    /// `claimedAt` (a withdrawal / erasure voided the record and a re-grant migrated again under new
    /// ids) counts as absent, so the new copy gets its own one-time offer.
    public static func legacyOfferMarker(defaults: UserDefaults = .standard, accountPeerId: Int64, claimedAt: Int64) -> LegacyOfferMarker? {
        guard let raw = defaults.string(forKey: self.legacyOfferKey(accountPeerId: accountPeerId)) else {
            return nil
        }
        return self.parseLegacyOfferMarker(raw, claimedAt: claimedAt)
    }

    /// The pure parse of a stored value (`"<claimedAt>:<later|done>"`).
    public static func parseLegacyOfferMarker(_ raw: String, claimedAt: Int64) -> LegacyOfferMarker? {
        guard let separator = raw.firstIndex(of: ":") else {
            return nil
        }
        guard Int64(raw[..<separator]) == claimedAt else {
            return nil
        }
        return LegacyOfferMarker(rawValue: String(raw[raw.index(after: separator)...]))
    }

    public static func setLegacyOfferMarker(_ marker: LegacyOfferMarker, defaults: UserDefaults = .standard, accountPeerId: Int64, claimedAt: Int64) {
        defaults.set("\(claimedAt):\(marker.rawValue)", forKey: self.legacyOfferKey(accountPeerId: accountPeerId))
    }

    // MARK: `remaining` (§7.4): read synchronously by the logout confirmation

    /// The number of device-row candidates still unsent, as the offer last computed it.
    public static func unsentLegacyAssignees(defaults: UserDefaults = .standard, accountPeerId: Int64) -> Int {
        return max(0, defaults.integer(forKey: self.remainingKey(accountPeerId: accountPeerId)))
    }

    /// Rewritten whenever the offer computes its candidates (board appear, after the sheet's send,
    /// after a per-task Yuborish); 0 removes the key.
    public static func setUnsentLegacyAssignees(_ count: Int, defaults: UserDefaults = .standard, accountPeerId: Int64) {
        let key = self.remainingKey(accountPeerId: accountPeerId)
        if count > 0 {
            if defaults.integer(forKey: key) != count {
                defaults.set(count, forKey: key)
            }
        } else if defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: The durable sent set (§7.2 item 5, §7.4)

    /// The cloud task ids whose legacy assignee was sent from this device (by the sheet or a per-task
    /// Yuborish). A task in the set is never a legacy candidate again, whatever its assignment does.
    public static func legacySentTaskIds(defaults: UserDefaults = .standard, accountPeerId: Int64) -> Set<String> {
        return Set(defaults.stringArray(forKey: self.sentKey(accountPeerId: accountPeerId)) ?? [])
    }

    /// Recorded BEFORE the `invitation.request` is enqueued (§7.3, §4.2 item 7).
    public static func markLegacySent(_ taskIds: [String], defaults: UserDefaults = .standard, accountPeerId: Int64) {
        let key = self.sentKey(accountPeerId: accountPeerId)
        var ids = defaults.stringArray(forKey: key) ?? []
        var changed = false
        for taskId in taskIds where !ids.contains(taskId) {
            ids.append(taskId)
            changed = true
        }
        if changed {
            defaults.set(ids, forKey: key)
        }
    }

    /// A send that queued nothing (a refusal at enqueue) is not a send: the id comes back out.
    public static func unmarkLegacySent(_ taskId: String, defaults: UserDefaults = .standard, accountPeerId: Int64) {
        let key = self.sentKey(accountPeerId: accountPeerId)
        let ids = (defaults.stringArray(forKey: key) ?? []).filter { $0 != taskId }
        if ids.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(ids, forKey: key)
        }
    }

    // MARK: The last logout (§3.3, §7.4)

    /// Removes every `sgtasks.*` key of this spec — explainer, consentPrompted, the three
    /// legacyAssignees keys, notice.otherAccount, scopeKeysRemoved, every account — except the
    /// durable manual invitation answers (`sgtasks.inviteAnswers.*`). Called by `SGAccountCleanup`
    /// next to `TodoStorage.removeAllData()` when the last account logs out. Returns the keys removed.
    @discardableResult
    public static func removeAll(defaults: UserDefaults = .standard) -> [String] {
        let keys = defaults.dictionaryRepresentation().keys.filter { key in
            guard key.hasPrefix(self.keyPrefix) else {
                return false
            }
            return !self.preservedPrefixes.contains { key.hasPrefix($0) }
        }.sorted()
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        return keys
    }
}

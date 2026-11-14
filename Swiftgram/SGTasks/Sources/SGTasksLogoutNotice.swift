import Foundation

// MARK: - Zenlygram Tasks R4: the logout warning (design 30 §5.7; wf15 §7.4)
//
// The logout confirmations (Settings ▸ Log Out, Session Backup ▸ Remove from App, the consent
// flows) say what logging out would cost of an account's cloud tasks, from the repository's unsent
// counts by origin (`SGTasksCloudRepository.unsentChangeCounts`: a local read, no network; the
// deferred assignments of wf15 §12.2 count as user changes) and, wf15 §7.4, from the number of legacy
// device-row Masʼuls the D4 sheet has not sent yet (`SGTasksLocalMarkers.unsentLegacyAssignees`,
// a content-free `UserDefaults` integer the offer rewrites whenever it computes its candidates).
// Nothing waiting → no Tasks line at all; unreadable counts → the generic notice, never a fake
// zero. The decision is the pure `TasksLogoutNotice` (host-tested in run-cloud-model-tests.sh);
// this function only gathers the inputs and renders them — it is not host-compilable (SGTasksL10n
// imports TelegramPresentationData), which is why nothing is decided here. The paragraph's wording
// ("if you log out and no other account stays signed in here, they are lost") is true for a last
// and a non-last logout, so the three call sites need no last-account flag.

/// The Tasks paragraph(s) of a logout confirmation for `accountPeerId` (packed `PeerId.toInt64()`),
/// or nil when nothing is waiting. `genericNotice` is the existing `Tasks.Cloud.LogoutNotice` text
/// (SGStrings is not an SGTasks dependency), shown when the counts cannot be read.
public func sgTasksLogoutNotice(accountPeerId: Int64, languageCode: String, genericNotice: @autoclosure () -> String) -> String? {
    let counts = SGTasksCloudRepository.unsentChangeCounts(accountPeerId: accountPeerId)
    let unsentAssignees = SGTasksLocalMarkers.unsentLegacyAssignees(accountPeerId: accountPeerId)
    guard let notice = TasksLogoutNotice(counts: counts, unsentAssignees: unsentAssignees) else {
        return nil
    }
    let l10n = SGTasksL10n(languageCode: languageCode)
    var lines: [String] = []
    switch notice {
    case .generic:
        lines.append(genericNotice())
    case let .details(unsent, migrationPending, _):
        if unsent > 0 {
            lines.append(l10n.tasks_logout_unsent(unsent))
        }
        if migrationPending {
            lines.append(l10n.tasks_logout_migration)
        }
    }
    if notice.unsentAssignees > 0 {
        lines.append(l10n.tasks_logout_unsentAssignees(notice.unsentAssignees))
    }
    return lines.joined(separator: " ")
}

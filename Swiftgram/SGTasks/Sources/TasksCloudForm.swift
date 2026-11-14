import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext
import TextFormat

// Zenlygram — Cloud Tasks: a small builder for the ItemList screens (task editor, invitations, lists,
// unsent changes, import consent). Each row is identified by a stable string id and compared by an
// explicit content key, so the ItemList diff animates only real changes. Row actions must look up
// current state by id when they run (never capture state that the key does not cover).

struct TasksCloudFormEntry: ItemListNodeEntry {
    let section: ItemListSectionId
    let stableId: String
    let sortIndex: Int
    let contentKey: AnyHashable
    let make: (ItemListPresentationData, ItemListSectionId) -> ListViewItem

    static func ==(lhs: TasksCloudFormEntry, rhs: TasksCloudFormEntry) -> Bool {
        return lhs.stableId == rhs.stableId && lhs.section == rhs.section && lhs.sortIndex == rhs.sortIndex && lhs.contentKey == rhs.contentKey
    }

    static func <(lhs: TasksCloudFormEntry, rhs: TasksCloudFormEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        return self.make(presentationData, self.section)
    }
}

final class TasksCloudForm {
    private(set) var entries: [TasksCloudFormEntry] = []
    private var section: ItemListSectionId = 0

    func newSection() {
        if !self.entries.isEmpty {
            self.section += 1
        }
    }

    func add(_ id: String, key: AnyHashable, _ make: @escaping (ItemListPresentationData, ItemListSectionId) -> ListViewItem) {
        self.entries.append(TasksCloudFormEntry(section: self.section, stableId: id, sortIndex: self.entries.count, contentKey: key, make: make))
    }

    func header(_ id: String, _ text: String) {
        self.add(id, key: text) { presentationData, section in
            ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        }
    }

    func footer(_ id: String, _ text: String) {
        self.add(id, key: text) { presentationData, section in
            ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        }
    }

    func action(_ id: String, _ title: String, kind: ItemListActionKind = .generic, action: @escaping () -> Void) {
        let kindKey: Int
        switch kind {
        case .generic:
            kindKey = 0
        case .destructive:
            kindKey = 1
        case .neutral:
            kindKey = 2
        case .disabled:
            kindKey = 3
        }
        // ItemListActionItem runs its closure even when drawn disabled: a disabled row must be inert.
        let effectiveAction: () -> Void = kind == .disabled ? {} : action
        self.add(id, key: [AnyHashable(title), AnyHashable(kindKey)]) { presentationData, section in
            ItemListActionItem(presentationData: presentationData, title: title, kind: kind, alignment: .natural, sectionId: section, style: .blocks, action: effectiveAction)
        }
    }

    /// A tappable (or, without an action, inert) row. The title wraps instead of truncating (an
    /// attributed title lifts ItemList's one-line limit) and the value sits below it, wrapping too,
    /// so long names and long translated values stay fully visible at large text sizes.
    func disclosure(_ id: String, _ title: String, label: String, enabled: Bool = true, action: (() -> Void)?) {
        self.add(id, key: [AnyHashable(title), AnyHashable(label), AnyHashable(enabled), AnyHashable(action != nil)]) { presentationData, section in
            let titleColor = enabled ? presentationData.theme.list.itemPrimaryTextColor : presentationData.theme.list.itemDisabledTextColor
            let attributedTitle = NSAttributedString(string: title, font: Font.regular(presentationData.fontSize.itemListBaseFontSize), textColor: titleColor)
            return ItemListDisclosureItem(presentationData: presentationData, title: title, attributedTitle: attributedTitle, enabled: enabled, label: label, labelStyle: .multilineDetailText, sectionId: section, style: .blocks, disclosureStyle: action == nil ? .none : .arrow, action: action)
        }
    }

    /// Read-only text inside a block: a short field name above, the (wrapping) content below. Static
    /// for assistive tech (not a button, no highlight) and never turns URLs in other users' text into
    /// links.
    func info(_ id: String, label: String, text: String) {
        self.add(id, key: [AnyHashable(label), AnyHashable(text)]) { presentationData, section in
            ItemListTextWithLabelItem(presentationData: presentationData, label: label, text: text, style: .blocks, enabledEntityTypes: [], multiline: true, sectionId: section, action: nil)
        }
    }
}

/// The repository's state as a Signal (current value first, then every change notification). Delivered
/// on the main queue, where the repository's state may be read.
func tasksCloudStateSignal(_ repository: SGTasksCloudRepository) -> Signal<SGTasksCloudState, NoError> {
    return Signal { [repository] subscriber in
        subscriber.putNext(repository.state)
        let observer = NotificationCenter.default.addObserver(forName: SGTasksCloudRepository.didChangeNotification, object: repository, queue: .main, using: { [weak repository] _ in
            guard let repository else {
                return
            }
            subscriber.putNext(repository.state)
        })
        return ActionDisposable {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    |> runOn(Queue.mainQueue())
}

/// One user-facing message for a refused local cloud action. Never shows ids, SQL or content.
func tasksCloudErrorText(_ error: Error, l10n: SGTasksL10n) -> String {
    guard let error = error as? SGTasksCloudError else {
        return l10n.tasks_error_generic
    }
    switch error {
    case .invalidTitle:
        return l10n.tasks_cloud_error_title
    case .invalidDescription:
        return l10n.tasks_cloud_error_description
    case .notLinked:
        return l10n.tasks_cloud_paused_text
    case .listHasPendingChanges:
        return l10n.tasks_cloud_error_listPending
    case .taskCompleted:
        return l10n.tasks_assign_footer_completedTask
    case .recipientNotConvertible, .annotationNotConvertible:
        return l10n.tasks_cloud_error_recipient
    case .importRequiresCompleteSnapshot, .importSnapshotStale:
        return l10n.tasks_cloud_error_importNotReady
    case .taskNotFound, .listNotFound, .invitationNotFound, .entryNotFound:
        return l10n.tasks_cloud_error_gone
    case .invitationExpired:
        return l10n.tasks_cloud_error_invitationExpired
    case .changedElsewhere:
        return l10n.tasks_cloud_error_changedElsewhere
    case .alreadyPending:
        return l10n.tasks_cloud_error_alreadyPending
    case .laterChangesPending:
        return l10n.tasks_cloud_error_laterChangesPending
    case .notOwner:
        return l10n.tasks_cloud_error_notOwner
    case .notAssignee:
        return l10n.tasks_cloud_error_notAssignee
    case .selfAssignment:
        return l10n.tasks_assign_self
    case let .assignmentLimit(limit):
        switch limit {
        case .perPerson:
            return l10n.tasks_assign_limitPerPerson
        case .perMinute:
            return l10n.tasks_assign_limitPerMinute
        case .total:
            return l10n.tasks_assign_limitTotal
        case .pending:
            return l10n.tasks_assign_limitPending
        }
    default:
        return l10n.tasks_error_generic
    }
}

import Foundation
import UIKit
import Display
import TelegramPresentationData

// Zenlygram — Tasks board table cells. Completion (the circle) and editing (the rest of the row)
// are separate targets, so ticking a task never opens the editor and vice versa.

/// Everything a task row needs; built by the board nodes from their board state.
struct TasksTaskRowModel {
    let taskId: String
    let title: String
    let isCompleted: Bool
    /// The task's list, shown under the title while "All" is selected.
    let listTitle: String?
    /// The local assignee (or a cloud task's owner-only assignee), already formatted; nil when unset.
    let assigneeName: String?
    let deadlineText: String?
    /// Cloud only: sharing and sync state ("Invitation pending", "Waiting for sync confirmation"); nil when nothing to say.
    let statusText: String?
    /// The removal action's title: Delete, or Leave for a task shared with the user.
    let removalTitle: String?
    /// VoiceOver hint for opening the row; nil = the editor hint ("Edits the task").
    let openHint: String?
    /// Cloud rows: the viewer's rights on the task the row was drawn from (role and, for a recipient,
    /// the accepted invitation epoch); the actions carry it back so the presenter can refuse a row
    /// drawn under other rights. nil = a task on this device, where every action is the user's.
    let cloudAccess: TasksCloudTaskPermissions?
    /// wf15 §4.3, synced owner rows: the Masʼul line "Masʼul: Ism · holat" (its own accessibility
    /// element, `sgtasks.task.<id>.assignee`) and the bare state word it ends with (the element's value).
    let assigneeLine: String?
    let assigneeState: String?

    init(taskId: String, title: String, isCompleted: Bool, listTitle: String?, assigneeName: String?, deadlineText: String?, cloudAccess: TasksCloudTaskPermissions?, statusText: String? = nil, removalTitle: String? = nil, openHint: String? = nil, assigneeLine: String? = nil, assigneeState: String? = nil) {
        self.taskId = taskId
        self.title = title
        self.isCompleted = isCompleted
        self.listTitle = listTitle
        self.assigneeName = assigneeName
        self.deadlineText = deadlineText
        self.cloudAccess = cloudAccess
        self.statusText = statusText
        self.removalTitle = removalTitle
        self.openHint = openHint
        self.assigneeLine = assigneeLine
        self.assigneeState = assigneeState
    }

    var canSetCompletion: Bool {
        return self.cloudAccess?.canSetCompletion ?? true
    }

    /// Delete (owner) or Leave (accepted recipient); nothing for a shared row without access.
    var canRemove: Bool {
        return self.cloudAccess.map { $0.canDelete || $0.canLeave } ?? true
    }
}

/// Row callbacks. Completion carries the explicit target state the row showed, never a toggle, and
/// completion/removal carry the rights the row was drawn under (`TasksTaskRowModel.cloudAccess`).
struct TasksRowActions {
    let setCompleted: (_ id: String, _ isCompleted: Bool, _ displayed: TasksCloudTaskPermissions?) -> Void
    let edit: (String) -> Void
    let delete: (_ id: String, _ displayed: TasksCloudTaskPermissions?) -> Void
}

/// A full-size view that is a row's one accessibility element. The cell itself is not an element
/// (and carries no identifier of its own), so assistive tech and UI tests see exactly one copy.
/// Touches pass through to the cell (`isUserInteractionEnabled = false`), whose selection handles
/// taps; VoiceOver activation goes through `activate`.
final class TasksAccessibleRowView: UIView {
    var activate: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isAccessibilityElement = true
        self.isUserInteractionEnabled = false
        self.translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func accessibilityActivate() -> Bool {
        guard let activate = self.activate else {
            return false
        }
        activate()
        return true
    }

    func pin(to container: UIView) {
        container.addSubview(self)
        NSLayoutConstraint.activate([
            self.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            self.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            self.topAnchor.constraint(equalTo: container.topAnchor),
            self.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

final class TasksTaskCell: UITableViewCell {
    static let reuseIdentifier = "TasksTaskCell"

    private let checkButton = UIButton(type: .custom)
    private let bodyView = TasksAccessibleRowView()
    private let titleLabel = UILabel()
    private let metadataLabel = UILabel()
    /// wf15 §4.3: the owner's Masʼul line, an accessibility element of its own beside the row body.
    private let assigneeLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statusLabel = UILabel()
    private let textStack = UIStackView()
    private let highlightView = UIView()
    private var model: TasksTaskRowModel?
    private var actions: TasksRowActions?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.selectedBackgroundView = self.highlightView
        // A container: the check button and the row body are separate elements, never merged.
        self.isAccessibilityElement = false

        self.checkButton.translatesAutoresizingMaskIntoConstraints = false
        self.checkButton.addTarget(self, action: #selector(self.checkPressed), for: .touchUpInside)
        self.contentView.addSubview(self.checkButton)

        // The body spans the full row height right of the check button, so its touch and accessibility
        // frame is at least the 52 pt minimum row (the 44 pt check target plus 4 pt above and below).
        // The text sits beside it in the content view (not inside the element), so the Masʼul line
        // can be an accessibility element of its own (`sgtasks.task.<id>.assignee`, wf15 §4.3)
        // while the body still covers the whole row for touches and VoiceOver.
        self.bodyView.translatesAutoresizingMaskIntoConstraints = false
        self.bodyView.isAccessibilityElement = true
        self.bodyView.accessibilityTraits = .button
        self.bodyView.isUserInteractionEnabled = false

        self.titleLabel.numberOfLines = 0
        self.titleLabel.lineBreakMode = .byWordWrapping
        // Long names and large text wrap instead of being cut off.
        self.metadataLabel.numberOfLines = 0
        self.metadataLabel.lineBreakMode = .byWordWrapping
        self.assigneeLabel.numberOfLines = 0
        self.assigneeLabel.lineBreakMode = .byWordWrapping
        // Wraps: for a shared task this line carries the owner's numeric id, the only way to tell
        // who shared it, so it must never be cut off.
        self.subtitleLabel.numberOfLines = 0
        self.subtitleLabel.lineBreakMode = .byWordWrapping
        self.statusLabel.numberOfLines = 0
        self.statusLabel.lineBreakMode = .byWordWrapping
        self.textStack.axis = .vertical
        self.textStack.spacing = 2.0
        self.textStack.translatesAutoresizingMaskIntoConstraints = false
        self.textStack.isAccessibilityElement = false
        for label in [self.titleLabel, self.metadataLabel, self.assigneeLabel, self.subtitleLabel, self.statusLabel] {
            label.isAccessibilityElement = false
            self.textStack.addArrangedSubview(label)
        }
        self.assigneeLabel.accessibilityTraits = .staticText
        self.contentView.addSubview(self.textStack)
        self.contentView.addSubview(self.bodyView)

        // The text hugs the top (low priority) and is centered; long titles wrap and grow the row.
        let textHugsTop = self.textStack.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 11.0)
        textHugsTop.priority = .defaultLow
        NSLayoutConstraint.activate([
            self.checkButton.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 4.0),
            self.checkButton.topAnchor.constraint(greaterThanOrEqualTo: self.contentView.topAnchor, constant: 4.0),
            self.checkButton.bottomAnchor.constraint(lessThanOrEqualTo: self.contentView.bottomAnchor, constant: -4.0),
            self.checkButton.centerYAnchor.constraint(equalTo: self.contentView.centerYAnchor),
            self.checkButton.widthAnchor.constraint(equalToConstant: tasksMinimumHitSize),
            self.checkButton.heightAnchor.constraint(equalToConstant: tasksMinimumHitSize),

            self.bodyView.leadingAnchor.constraint(equalTo: self.checkButton.trailingAnchor, constant: 4.0),
            self.bodyView.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor),
            self.bodyView.topAnchor.constraint(equalTo: self.contentView.topAnchor),
            self.bodyView.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor),

            self.textStack.leadingAnchor.constraint(equalTo: self.checkButton.trailingAnchor, constant: 4.0),
            self.textStack.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -16.0),
            self.textStack.topAnchor.constraint(greaterThanOrEqualTo: self.contentView.topAnchor, constant: 11.0),
            self.textStack.bottomAnchor.constraint(lessThanOrEqualTo: self.contentView.bottomAnchor, constant: -11.0),
            self.textStack.centerYAnchor.constraint(equalTo: self.contentView.centerYAnchor),
            textHugsTop
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A reused cell starts blank: no previous row's text, ids, enabled circle or actions survive,
    /// even if the next `configure` never comes (a row whose task vanished meanwhile).
    override func prepareForReuse() {
        super.prepareForReuse()
        self.model = nil
        self.actions = nil
        self.bodyView.activate = nil
        self.checkButton.isEnabled = false
        self.checkButton.setImage(nil, for: .normal)
        self.titleLabel.attributedText = nil
        for label in [self.metadataLabel, self.assigneeLabel, self.subtitleLabel, self.statusLabel] {
            label.attributedText = nil
            label.isHidden = true
        }
        self.assigneeLabel.isAccessibilityElement = false
        self.accessibilityIdentifier = nil
        for view in [self.checkButton, self.bodyView, self.assigneeLabel] as [UIView] {
            view.accessibilityIdentifier = nil
            view.accessibilityLabel = nil
            view.accessibilityValue = nil
            view.accessibilityHint = nil
            view.accessibilityCustomActions = nil
        }
    }

    func configure(model: TasksTaskRowModel, actions: TasksRowActions, theme: PresentationTheme, strings: PresentationStrings, fontSize: CGFloat) {
        self.model = model
        self.actions = actions
        let l10n = SGTasksL10n(strings)

        self.backgroundColor = theme.list.itemBlocksBackgroundColor
        self.highlightView.backgroundColor = theme.list.itemHighlightedBackgroundColor

        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: fontSize + 5.0, weight: .regular)
        let symbolName = model.isCompleted ? "checkmark.circle.fill" : "circle"
        self.checkButton.setImage(UIImage(systemName: symbolName, withConfiguration: symbolConfiguration), for: .normal)
        // An open circle uses the secondary text color (≈ 3.3:1, a non-text contrast pass), not the
        // faint disclosure-arrow color.
        self.checkButton.tintColor = model.isCompleted ? theme.list.itemAccentColor : theme.list.itemSecondaryTextColor
        // Disabled (dimmed, and "dimmed" to VoiceOver) when the viewer may not complete this task;
        // same size and place either way.
        self.checkButton.isEnabled = model.canSetCompletion

        var titleAttributes: [NSAttributedString.Key: Any] = [
            .font: Font.regular(fontSize),
            .foregroundColor: model.isCompleted ? theme.list.itemSecondaryTextColor : theme.list.itemPrimaryTextColor
        ]
        if model.isCompleted {
            titleAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        self.titleLabel.attributedText = NSAttributedString(string: model.title, attributes: titleAttributes)

        let secondaryFont = Font.regular(floor(fontSize * 13.0 / 17.0))
        self.subtitleLabel.font = secondaryFont
        self.subtitleLabel.textColor = theme.list.itemSecondaryTextColor
        self.subtitleLabel.text = model.listTitle
        // A hidden arranged subview also drops the stack spacing.
        self.subtitleLabel.isHidden = model.listTitle == nil

        self.metadataLabel.attributedText = TasksTaskCell.metadataText(model: model, font: secondaryFont, theme: theme)
        self.metadataLabel.isHidden = model.assigneeName == nil && model.deadlineText == nil

        // The Masʼul line (wf15 §4.3): secondary text like the metadata, its own element below.
        self.assigneeLabel.font = secondaryFont
        self.assigneeLabel.textColor = theme.list.itemSecondaryTextColor
        self.assigneeLabel.text = model.assigneeLine
        self.assigneeLabel.isHidden = model.assigneeLine == nil

        self.statusLabel.font = secondaryFont
        // Sync state is information the user acts on: readable secondary color (≈ 5:1).
        self.statusLabel.textColor = theme.list.freeTextColor
        self.statusLabel.text = model.statusText
        self.statusLabel.isHidden = model.statusText == nil

        self.configureAccessibility(model: model, l10n: l10n, strings: strings)
    }

    /// "person-icon Name   calendar-icon date": each value carries its own symbol, so assignee and
    /// deadline are told apart without color. The name arrives isolated (FSI…PDI) from the board
    /// node; the date is isolated here, so neither can reorder the other.
    private static func metadataText(model: TasksTaskRowModel, font: UIFont, theme: PresentationTheme) -> NSAttributedString? {
        let parts: [(String, String)] = [
            model.assigneeName.map { ("person.crop.circle", $0) },
            model.deadlineText.map { ("calendar", tasksIsolatedDisplayText($0)) }
        ].compactMap { $0 }
        guard !parts.isEmpty else {
            return nil
        }
        let color = theme.list.itemSecondaryTextColor
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let symbolConfiguration = UIImage.SymbolConfiguration(font: font)
        let result = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "   ", attributes: attributes))
            }
            if let image = UIImage(systemName: part.0, withConfiguration: symbolConfiguration)?.withTintColor(color, renderingMode: .alwaysOriginal) {
                let attachment = NSTextAttachment()
                attachment.image = image
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: "\u{00A0}", attributes: attributes))
            }
            result.append(NSAttributedString(string: part.1, attributes: attributes))
        }
        return result
    }

    private func configureAccessibility(model: TasksTaskRowModel, l10n: SGTasksL10n, strings: PresentationStrings) {
        self.accessibilityIdentifier = TasksBoardAccessibilityId.task(model.taskId)

        let toggleTitle = model.isCompleted ? l10n.tasks_a11y_markNotDone : l10n.tasks_a11y_markDone
        self.checkButton.accessibilityIdentifier = TasksBoardAccessibilityId.taskComplete(model.taskId)
        self.checkButton.accessibilityLabel = toggleTitle
        self.checkButton.accessibilityValue = model.title

        self.bodyView.accessibilityIdentifier = TasksBoardAccessibilityId.taskEdit(model.taskId)
        self.bodyView.accessibilityLabel = model.title
        let state = model.isCompleted ? l10n.tasks_a11y_stateDone : l10n.tasks_a11y_stateOpen
        let assignee = model.assigneeName.map { l10n.tasks_a11y_assigneeValue($0) }
        let deadline = model.deadlineText.map { l10n.tasks_a11y_deadlineValue($0) }
        self.bodyView.accessibilityValue = [assignee, deadline, model.listTitle, model.statusText, state].compactMap { $0 }.joined(separator: ", ")
        self.bodyView.accessibilityHint = model.openHint ?? l10n.tasks_a11y_editHint
        // The Masʼul line is its own element (wf15 §4.3: `sgtasks.task.<id>.assignee`, its value ends
        // with the state word), so the row body does not repeat it.
        if let assigneeLine = model.assigneeLine {
            self.assigneeLabel.isAccessibilityElement = true
            self.assigneeLabel.accessibilityIdentifier = TasksBoardAccessibilityId.taskAssignee(model.taskId)
            self.assigneeLabel.accessibilityLabel = assigneeLine
            self.assigneeLabel.accessibilityValue = model.assigneeState
        } else {
            self.assigneeLabel.isAccessibilityElement = false
            self.assigneeLabel.accessibilityIdentifier = nil
            self.assigneeLabel.accessibilityLabel = nil
            self.assigneeLabel.accessibilityValue = nil
        }
        self.bodyView.activate = { [weak self] in
            self?.openRow()
        }
        // Rebuilt on every configure: only the actions the viewer may take on this task.
        var customActions: [UIAccessibilityCustomAction] = []
        if model.canSetCompletion {
            customActions.append(UIAccessibilityCustomAction(name: toggleTitle, target: self, selector: #selector(self.accessibilityToggle)))
        }
        if model.canRemove {
            customActions.append(UIAccessibilityCustomAction(name: model.removalTitle ?? strings.Common_Delete, target: self, selector: #selector(self.accessibilityDelete)))
        }
        self.bodyView.accessibilityCustomActions = customActions
    }

    private func openRow() {
        guard let model = self.model, let actions = self.actions else {
            return
        }
        actions.edit(model.taskId)
    }

    /// Asks for the opposite of the state this row shows (an explicit target, never a toggle).
    private func requestCompletion() -> Bool {
        guard let model = self.model, model.canSetCompletion, let actions = self.actions else {
            return false
        }
        actions.setCompleted(model.taskId, !model.isCompleted, model.cloudAccess)
        return true
    }

    @objc private func checkPressed() {
        let _ = self.requestCompletion()
    }

    @objc private func accessibilityToggle() -> Bool {
        return self.requestCompletion()
    }

    @objc private func accessibilityDelete() -> Bool {
        guard let model = self.model, model.canRemove, let actions = self.actions else {
            return false
        }
        actions.delete(model.taskId, model.cloudAccess)
        return true
    }
}

final class TasksCompletedHeaderCell: UITableViewCell {
    static let reuseIdentifier = "TasksCompletedHeaderCell"

    private let titleLabel = UILabel()
    private let chevronView = UIImageView()
    private let highlightView = UIView()
    private let accessibleRow = TasksAccessibleRowView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.selectedBackgroundView = self.highlightView
        self.isAccessibilityElement = false

        self.titleLabel.translatesAutoresizingMaskIntoConstraints = false
        self.titleLabel.numberOfLines = 0
        self.titleLabel.isAccessibilityElement = false
        self.chevronView.translatesAutoresizingMaskIntoConstraints = false
        self.chevronView.contentMode = .center
        self.chevronView.isAccessibilityElement = false
        self.contentView.addSubview(self.titleLabel)
        self.contentView.addSubview(self.chevronView)

        self.accessibleRow.accessibilityTraits = .button
        self.accessibleRow.accessibilityIdentifier = TasksBoardAccessibilityId.completedToggle
        self.accessibleRow.pin(to: self.contentView)

        NSLayoutConstraint.activate([
            self.titleLabel.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 16.0),
            self.titleLabel.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 12.0),
            self.titleLabel.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -12.0),
            self.titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: self.chevronView.leadingAnchor, constant: -8.0),
            self.chevronView.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -16.0),
            self.chevronView.centerYAnchor.constraint(equalTo: self.contentView.centerYAnchor),
            self.chevronView.widthAnchor.constraint(equalToConstant: 20.0),
            // 12 pt above and below: at least a 44 pt row.
            self.titleLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: tasksMinimumHitSize - 24.0)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(count: Int, isExpanded: Bool, theme: PresentationTheme, l10n: SGTasksL10n, fontSize: CGFloat, toggle: @escaping () -> Void) {
        self.backgroundColor = theme.list.itemBlocksBackgroundColor
        self.highlightView.backgroundColor = theme.list.itemHighlightedBackgroundColor

        let title = l10n.tasks_completed_header(count)
        self.titleLabel.font = Font.medium(fontSize)
        self.titleLabel.textColor = theme.list.itemAccentColor
        self.titleLabel.text = title

        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: fontSize - 3.0, weight: .semibold)
        self.chevronView.image = UIImage(systemName: isExpanded ? "chevron.down" : "chevron.right", withConfiguration: symbolConfiguration)?.imageFlippedForRightToLeftLayoutDirection()
        self.chevronView.tintColor = theme.list.disclosureArrowColor

        self.accessibleRow.accessibilityLabel = title
        self.accessibleRow.accessibilityValue = isExpanded ? l10n.tasks_a11y_expanded : l10n.tasks_a11y_collapsed
        self.accessibleRow.accessibilityHint = isExpanded ? l10n.tasks_a11y_completedHint_hide : l10n.tasks_a11y_completedHint_show
        self.accessibleRow.activate = toggle
    }
}

final class TasksEmptyCell: UITableViewCell {
    static let reuseIdentifier = "TasksEmptyCell"

    private let titleLabel = UILabel()
    private let textLabelView = UILabel()
    private let accessibleRow = TasksAccessibleRowView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.selectionStyle = .none
        self.backgroundColor = .clear
        self.isAccessibilityElement = false

        for label in [self.titleLabel, self.textLabelView] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.numberOfLines = 0
            label.textAlignment = .center
            label.isAccessibilityElement = false
            self.contentView.addSubview(label)
        }
        self.accessibleRow.accessibilityTraits = .staticText
        self.accessibleRow.accessibilityIdentifier = TasksBoardAccessibilityId.emptyState
        self.accessibleRow.pin(to: self.contentView)
        NSLayoutConstraint.activate([
            self.titleLabel.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 16.0),
            self.titleLabel.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -16.0),
            self.titleLabel.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 32.0),
            self.textLabelView.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 16.0),
            self.textLabelView.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -16.0),
            self.textLabelView.topAnchor.constraint(equalTo: self.titleLabel.bottomAnchor, constant: 6.0),
            self.textLabelView.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -24.0)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, text: String, theme: PresentationTheme, fontSize: CGFloat) {
        self.titleLabel.font = Font.semibold(fontSize + 2.0)
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.titleLabel.text = title
        self.textLabelView.font = Font.regular(fontSize - 2.0)
        self.textLabelView.textColor = theme.list.freeTextColor
        self.textLabelView.text = text
        self.accessibleRow.accessibilityLabel = title + ". " + text
    }
}

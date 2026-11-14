import Foundation
import UIKit
import Display
import TelegramPresentationData

// Zenlygram — Tasks board: the filter chips above the list and the quick-add composer below it.
// Plain UIKit views; the board node positions them (they never set their own frame).

/// Stable accessibility identifiers for UI tests. They carry ids only — never a title.
enum TasksBoardAccessibilityId {
    static let filterAll = "sgtasks.filter.all"
    static let filterNewList = "sgtasks.filter.newList"
    static func filterFolder(_ folderId: String) -> String { "sgtasks.filter.folder.\(folderId)" }
    static let quickAddField = "sgtasks.quickAdd.field"
    static let quickAddSubmit = "sgtasks.quickAdd.submit"
    static let quickAddAssignee = "sgtasks.quickAdd.assignee"
    static let quickAddAssigneeClear = "sgtasks.quickAdd.assignee.clear"
    static let quickAddDeadline = "sgtasks.quickAdd.deadline"
    static let quickAddDeadlineClear = "sgtasks.quickAdd.deadline.clear"
    static let completedToggle = "sgtasks.completed.toggle"
    static let emptyState = "sgtasks.empty"
    static func task(_ taskId: String) -> String { "sgtasks.task.\(taskId)" }
    static func taskComplete(_ taskId: String) -> String { "sgtasks.task.\(taskId).complete" }
    static func taskEdit(_ taskId: String) -> String { "sgtasks.task.\(taskId).edit" }
    /// wf15 §4.3: the owner's Masʼul line of a synced row ("Masʼul: Ism · holat"; its value ends with
    /// the state word) and, in the editor, the Masʼul row with the same value.
    static func taskAssignee(_ taskId: String) -> String { "sgtasks.task.\(taskId).assignee" }
    /// wf15 §4.3: the editor's Qayta yuborish / Yuborish action of that task.
    static func taskAssigneeResend(_ taskId: String) -> String { "sgtasks.task.\(taskId).assignee.resend" }
    /// wf15 §7: the one-time legacy assignee sheet (D4) — its body, Yuborish and Keyinroq.
    static let legacySheet = "sgtasks.legacy.sheet"
    static let legacySheetSend = "sgtasks.legacy.send"
    static let legacySheetLater = "sgtasks.legacy.later"
    static let editTitle = "sgtasks.edit.title"
    static let editAssignee = "sgtasks.edit.assignee"
    static let editAssigneeClear = "sgtasks.edit.assignee.clear"
    static let editDeadline = "sgtasks.edit.deadline"
    static let editDeadlineClear = "sgtasks.edit.deadline.clear"
    static let editSave = "sgtasks.edit.save"
    static let editCancel = "sgtasks.edit.cancel"
    static let deadlinePicker = "sgtasks.deadline.picker"
    static let deadlineClear = "sgtasks.deadline.clear"
    static let deadlineCancel = "sgtasks.deadline.cancel"
    static let deadlineSave = "sgtasks.deadline.save"
}

/// Minimum touch target (Apple HIG), applied to every control on the board.
let tasksMinimumHitSize: CGFloat = 44.0

// MARK: - Filter chips

private final class TasksChipControl: UIControl {
    private let label = UILabel()
    private static let horizontalPadding: CGFloat = 14.0
    private static let maxWidth: CGFloat = 220.0

    var chipFilter: TasksBoardFilter?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.label.lineBreakMode = .byTruncatingTail
        self.label.isUserInteractionEnabled = false
        self.addSubview(self.label)
        self.isAccessibilityElement = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(text: NSAttributedString, isChipSelected: Bool, theme: PresentationTheme) {
        self.label.attributedText = text
        self.isSelected = isChipSelected
        self.backgroundColor = isChipSelected ? theme.list.itemAccentColor : theme.list.itemBlocksBackgroundColor
        self.accessibilityTraits = isChipSelected ? [.button, .selected] : [.button]
    }

    func fittingSize(height: CGFloat) -> CGSize {
        let labelSize = self.label.sizeThatFits(CGSize(width: TasksChipControl.maxWidth, height: height))
        let width = min(TasksChipControl.maxWidth, ceil(labelSize.width)) + TasksChipControl.horizontalPadding * 2.0
        return CGSize(width: max(width, tasksMinimumHitSize), height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.layer.cornerRadius = self.bounds.height / 2.0
        let inset = TasksChipControl.horizontalPadding
        self.label.frame = CGRect(x: inset, y: 0.0, width: max(0.0, self.bounds.width - inset * 2.0), height: self.bounds.height)
    }

    // The pill is drawn shorter than 44 pt; its touch area and its accessibility frame are not.
    private var hitBounds: CGRect {
        let extra = max(0.0, (tasksMinimumHitSize - self.bounds.height) / 2.0)
        return self.bounds.insetBy(dx: 0.0, dy: -extra)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        return self.hitBounds.contains(point)
    }

    override var accessibilityFrame: CGRect {
        get {
            return UIAccessibility.convertToScreenCoordinates(self.hitBounds, in: self)
        }
        set {
            super.accessibilityFrame = newValue
        }
    }
}

final class TasksFilterBarView: UIView {
    private let scrollView = UIScrollView()
    private var chips: [TasksChipControl] = []
    private let newListChip = TasksChipControl()
    private var chipHeight: CGFloat = 36.0
    private var lastSelectedFilter: TasksBoardFilter?

    var selectFilter: ((TasksBoardFilter) -> Void)?
    var createList: (() -> Void)?

    /// The container layout's left/right safe insets (landscape notch), set by the board node.
    var horizontalInsets: (left: CGFloat, right: CGFloat) = (0.0, 0.0) {
        didSet { self.setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.scrollView.showsHorizontalScrollIndicator = false
        self.scrollView.alwaysBounceHorizontal = true
        self.scrollView.scrollsToTop = false
        self.addSubview(self.scrollView)

        self.newListChip.accessibilityIdentifier = TasksBoardAccessibilityId.filterNewList
        self.newListChip.addTarget(self, action: #selector(self.newListPressed), for: .touchUpInside)
        self.scrollView.addSubview(self.newListChip)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Height for the given font size: a 36 pt pill at the default size, growing with the text.
    static func height(fontSize: CGFloat) -> CGFloat {
        return TasksFilterBarView.chipHeight(fontSize: fontSize) + 16.0
    }

    private static func chipHeight(fontSize: CGFloat) -> CGFloat {
        return max(36.0, ceil(Font.medium(fontSize - 2.0).lineHeight) + 16.0)
    }

    func update(chips chipModels: [TasksBoardChip], l10n: SGTasksL10n, theme: PresentationTheme, fontSize: CGFloat) {
        self.backgroundColor = theme.list.blocksBackgroundColor
        self.chipHeight = TasksFilterBarView.chipHeight(fontSize: fontSize)
        let titleFont = Font.medium(fontSize - 2.0)
        let countFont = Font.regular(fontSize - 2.0)

        while self.chips.count < chipModels.count {
            let chip = TasksChipControl()
            chip.addTarget(self, action: #selector(self.chipPressed(_:)), for: .touchUpInside)
            self.scrollView.addSubview(chip)
            self.chips.append(chip)
        }
        while self.chips.count > chipModels.count {
            self.chips.removeLast().removeFromSuperview()
        }

        for (chip, model) in zip(self.chips, chipModels) {
            let title = model.folderTitle ?? l10n.tasks_filter_all
            let titleColor = model.isSelected ? theme.list.itemCheckColors.foregroundColor : theme.list.itemPrimaryTextColor
            let countColor = model.isSelected ? theme.list.itemCheckColors.foregroundColor.withAlphaComponent(0.8) : theme.list.itemSecondaryTextColor
            let text = NSMutableAttributedString(string: title, attributes: [.font: titleFont, .foregroundColor: titleColor])
            if model.activeCount > 0 {
                text.append(NSAttributedString(string: "  \(model.activeCount)", attributes: [.font: countFont, .foregroundColor: countColor]))
            }
            chip.chipFilter = model.filter
            chip.update(text: text, isChipSelected: model.isSelected, theme: theme)
            chip.accessibilityLabel = title
            chip.accessibilityValue = l10n.tasks_a11y_openCount(model.activeCount)
            switch model.filter {
            case .all:
                chip.accessibilityIdentifier = TasksBoardAccessibilityId.filterAll
            case let .folder(id):
                chip.accessibilityIdentifier = TasksBoardAccessibilityId.filterFolder(id)
            }
        }

        let newListText = NSAttributedString(string: "+ " + l10n.tasks_filter_newList, attributes: [.font: titleFont, .foregroundColor: theme.list.itemAccentColor])
        self.newListChip.update(text: newListText, isChipSelected: false, theme: theme)
        self.newListChip.accessibilityLabel = l10n.tasks_filter_newList

        self.setNeedsLayout()
        self.layoutIfNeeded()

        let selected = chipModels.first(where: { $0.isSelected })?.filter
        if selected != self.lastSelectedFilter {
            self.lastSelectedFilter = selected
            if let chip = self.chips.first(where: { $0.chipFilter == selected }) {
                self.scrollView.scrollRectToVisible(chip.frame.insetBy(dx: -16.0, dy: 0.0), animated: true)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.scrollView.frame = self.bounds
        let sideInset: CGFloat = 16.0
        let spacing: CGFloat = 8.0
        let y = floor((self.bounds.height - self.chipHeight) / 2.0)
        var x = sideInset + self.horizontalInsets.left
        for chip in self.chips + [self.newListChip] {
            let size = chip.fittingSize(height: self.chipHeight)
            chip.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width + spacing
        }
        self.scrollView.contentSize = CGSize(width: x - spacing + sideInset + self.horizontalInsets.right, height: self.bounds.height)
    }

    @objc private func chipPressed(_ sender: TasksChipControl) {
        if let filter = sender.chipFilter {
            self.selectFilter?(filter)
        }
    }

    @objc private func newListPressed() {
        self.createList?()
    }
}

// MARK: - Quick-add composer

/// What the composer's metadata row shows; formatted by the board node.
struct TasksComposerMetadata: Equatable {
    var assigneeName: String?
    var deadlineText: String?
}

/// One metadata control under the quick-add field: an SF Symbol plus text (the title while unset, the
/// value once chosen), so the state never depends on color alone. The label is always primary text
/// (it is the control's only visible name); a long value wraps instead of being cut. The pill is
/// drawn inside a row of at least 44 pt, which is the touch area and accessibility frame.
private final class TasksMetadataButton: UIControl {
    private static let leadingInset: CGFloat = 4.0
    private static let trailingInset: CGFloat = 12.0
    private static let textVerticalInset: CGFloat = 6.0
    private static let rowVerticalInset: CGFloat = 2.0

    private let pillView = UIView()
    private let iconView = UIImageView()
    private let label = UILabel()
    private var font = Font.regular(15.0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.pillView.isUserInteractionEnabled = false
        self.iconView.contentMode = .center
        self.iconView.isUserInteractionEnabled = false
        self.label.numberOfLines = 0
        self.label.lineBreakMode = .byWordWrapping
        self.label.isUserInteractionEnabled = false
        self.addSubview(self.pillView)
        self.pillView.addSubview(self.iconView)
        self.pillView.addSubview(self.label)
        self.isAccessibilityElement = true
        self.accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(symbolName: String, text: String, isSet: Bool, theme: PresentationTheme, fontSize: CGFloat) {
        self.font = Font.regular(fontSize - 2.0)
        self.pillView.backgroundColor = theme.list.itemInputField.backgroundColor
        self.iconView.image = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: fontSize - 3.0, weight: .regular))
        self.iconView.tintColor = isSet ? theme.list.itemAccentColor : theme.list.itemSecondaryTextColor
        self.label.font = self.font
        self.label.textColor = theme.list.itemPrimaryTextColor
        self.label.text = text
        self.setNeedsLayout()
    }

    private var lineHeight: CGFloat {
        return ceil(self.font.lineHeight)
    }

    /// The icon column: as wide as a one-line pill is tall.
    private var iconSide: CGFloat {
        return self.lineHeight + TasksMetadataButton.textVerticalInset * 2.0
    }

    private func textWidth(forWidth width: CGFloat) -> CGFloat {
        return max(1.0, width - TasksMetadataButton.leadingInset - self.iconSide - TasksMetadataButton.trailingInset)
    }

    private func textHeight(forWidth width: CGFloat) -> CGFloat {
        let size = self.label.sizeThatFits(CGSize(width: self.textWidth(forWidth: width), height: CGFloat.greatestFiniteMagnitude))
        return max(self.lineHeight, ceil(size.height))
    }

    /// The width that shows the whole text on one line.
    var singleLineWidth: CGFloat {
        let textSize = self.label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: self.lineHeight))
        return TasksMetadataButton.leadingInset + self.iconSide + ceil(textSize.width) + TasksMetadataButton.trailingInset
    }

    /// The row height at `width`, wrapping the text as needed; never below 44 pt.
    func rowHeight(forWidth width: CGFloat) -> CGFloat {
        let pillHeight = self.textHeight(forWidth: width) + TasksMetadataButton.textVerticalInset * 2.0
        return max(tasksMinimumHitSize, pillHeight + TasksMetadataButton.rowVerticalInset * 2.0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let textHeight = self.textHeight(forWidth: self.bounds.width)
        let pillHeight = min(self.bounds.height, textHeight + TasksMetadataButton.textVerticalInset * 2.0)
        self.pillView.frame = CGRect(x: 0.0, y: floor((self.bounds.height - pillHeight) / 2.0), width: self.bounds.width, height: pillHeight)
        self.pillView.layer.cornerRadius = min(pillHeight, self.iconSide) / 2.0
        let iconSide = self.iconSide
        self.iconView.frame = CGRect(x: TasksMetadataButton.leadingInset, y: floor((pillHeight - iconSide) / 2.0), width: iconSide, height: iconSide)
        let labelX = self.iconView.frame.maxX
        self.label.frame = CGRect(x: labelX, y: floor((pillHeight - textHeight) / 2.0), width: self.textWidth(forWidth: self.bounds.width), height: textHeight)
    }

    override var isHighlighted: Bool {
        didSet {
            self.pillView.alpha = self.isHighlighted ? 0.6 : 1.0
        }
    }
}

/// A scroll view so that, when the board gives it less height than its content needs (compact height
/// with the keyboard up, large text), every control stays reachable by scrolling instead of sitting
/// under the keyboard. In normal layouts the content fits and nothing scrolls. Like any view here it
/// never sets its own frame; it only sizes its content to `self.bounds`.
final class TasksComposerView: UIScrollView, UITextFieldDelegate {
    private let separator = UIView()
    private let fieldBackground = UIView()
    let textField = UITextField()
    private let submitButton = UIButton(type: .system)
    /// The keyboard's own Done bar: puts the keyboard away without adding the draft (Return adds).
    /// A non-zero starting width avoids UIKit's zero-width constraint warning; the keyboard sizes it.
    private let keyboardToolbar = UIToolbar(frame: CGRect(x: 0.0, y: 0.0, width: 320.0, height: 44.0))
    private let keyboardDoneItem = UIBarButtonItem(title: nil, style: .done, target: nil, action: nil)
    private let assigneeButton = TasksMetadataButton()
    private let assigneeClearButton = UIButton(type: .system)
    private let deadlineButton = TasksMetadataButton()
    private let deadlineClearButton = UIButton(type: .system)
    private var fontSize: CGFloat = 17.0
    /// The container layout's left/right safe insets (landscape notch), set by the board node.
    var horizontalInsets: (left: CGFloat, right: CGFloat) = (0.0, 0.0) {
        didSet { self.setNeedsLayout() }
    }

    /// Returns true once the task is stored; only then is the draft cleared. After Return or Add the
    /// keyboard stays up either way, so the next task can be typed immediately; Done puts it away.
    var submit: ((String) -> Bool)?
    var pickAssignee: (() -> Void)?
    var clearAssignee: (() -> Void)?
    var pickDeadline: (() -> Void)?
    var clearDeadline: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.contentInsetAdjustmentBehavior = .never
        self.showsHorizontalScrollIndicator = false
        self.alwaysBounceVertical = false
        // The status-bar tap belongs to the task table.
        self.scrollsToTop = false
        self.addSubview(self.separator)
        self.addSubview(self.fieldBackground)

        self.textField.delegate = self
        self.textField.returnKeyType = .default
        self.textField.enablesReturnKeyAutomatically = true
        self.textField.autocapitalizationType = .sentences
        self.textField.clearButtonMode = .never
        self.textField.accessibilityIdentifier = TasksBoardAccessibilityId.quickAddField
        self.textField.addTarget(self, action: #selector(self.textChanged), for: .editingChanged)
        self.addSubview(self.textField)

        // Built once here, so repeated `update` calls only restyle and retitle the same item.
        self.keyboardDoneItem.target = self
        self.keyboardDoneItem.action = #selector(self.dismissKeyboardPressed)
        self.keyboardToolbar.items = [UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil), self.keyboardDoneItem]
        self.keyboardToolbar.isTranslucent = false
        self.keyboardToolbar.sizeToFit()
        self.textField.inputAccessoryView = self.keyboardToolbar

        self.submitButton.accessibilityIdentifier = TasksBoardAccessibilityId.quickAddSubmit
        self.submitButton.addTarget(self, action: #selector(self.submitPressed), for: .touchUpInside)
        self.addSubview(self.submitButton)

        self.assigneeButton.accessibilityIdentifier = TasksBoardAccessibilityId.quickAddAssignee
        self.assigneeButton.addTarget(self, action: #selector(self.assigneePressed), for: .touchUpInside)
        self.addSubview(self.assigneeButton)
        self.assigneeClearButton.accessibilityIdentifier = TasksBoardAccessibilityId.quickAddAssigneeClear
        self.assigneeClearButton.addTarget(self, action: #selector(self.assigneeClearPressed), for: .touchUpInside)
        self.addSubview(self.assigneeClearButton)

        self.deadlineButton.accessibilityIdentifier = TasksBoardAccessibilityId.quickAddDeadline
        self.deadlineButton.addTarget(self, action: #selector(self.deadlinePressed), for: .touchUpInside)
        self.addSubview(self.deadlineButton)
        self.deadlineClearButton.accessibilityIdentifier = TasksBoardAccessibilityId.quickAddDeadlineClear
        self.deadlineClearButton.addTarget(self, action: #selector(self.deadlineClearPressed), for: .touchUpInside)
        self.addSubview(self.deadlineClearButton)

        self.updateSubmitEnabled()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func fieldRowHeight(fontSize: CGFloat) -> CGFloat {
        return max(tasksMinimumHitSize, ceil(Font.regular(fontSize).lineHeight) + 20.0) + 16.0
    }

    /// Where the assignee and deadline slots go (relative to the top of the metadata area) and how
    /// tall that area is. Side by side only when both texts — plus the 44 pt remove button of a
    /// chosen value — fit on one line in half the width; stacked otherwise, each wrapping as needed,
    /// so a chosen date and time or a long name is always shown in full.
    private func metadataLayout(width: CGFloat) -> (assignee: CGRect, deadline: CGRect, height: CGFloat) {
        let left = 16.0 + self.horizontalInsets.left
        let right = 8.0 + self.horizontalInsets.right
        let rowWidth = max(0.0, width - left - right)
        let assigneeClear = self.assigneeClearButton.isHidden ? 0.0 : tasksMinimumHitSize
        let deadlineClear = self.deadlineClearButton.isHidden ? 0.0 : tasksMinimumHitSize
        let spacing: CGFloat = 8.0
        let halfWidth = floor((rowWidth - spacing) / 2.0)
        let otherHalfWidth = max(0.0, rowWidth - halfWidth - spacing)
        if self.assigneeButton.singleLineWidth + assigneeClear <= halfWidth && self.deadlineButton.singleLineWidth + deadlineClear <= otherHalfWidth {
            let height = max(self.assigneeButton.rowHeight(forWidth: halfWidth - assigneeClear), self.deadlineButton.rowHeight(forWidth: otherHalfWidth - deadlineClear))
            return (
                CGRect(x: left, y: 0.0, width: halfWidth, height: height),
                CGRect(x: left + halfWidth + spacing, y: 0.0, width: otherHalfWidth, height: height),
                height
            )
        }
        let assigneeHeight = self.assigneeButton.rowHeight(forWidth: rowWidth - assigneeClear)
        let deadlineHeight = self.deadlineButton.rowHeight(forWidth: rowWidth - deadlineClear)
        return (
            CGRect(x: left, y: 0.0, width: rowWidth, height: assigneeHeight),
            CGRect(x: left, y: assigneeHeight, width: rowWidth, height: deadlineHeight),
            assigneeHeight + deadlineHeight
        )
    }

    /// The field row plus the assignee/deadline area below it (and a little air under it), for the
    /// current texts, font size and `horizontalInsets`. The board node sets those before asking.
    func preferredHeight(width: CGFloat) -> CGFloat {
        return TasksComposerView.fieldRowHeight(fontSize: self.fontSize) + self.metadataLayout(width: width).height + 4.0
    }

    /// True while the title field has the keyboard; pickers restore it after they close.
    var isEditingTitle: Bool {
        return self.textField.isFirstResponder
    }

    /// `assigneeHint` is the assignee control's VoiceOver hint; nil is the device board's (saved on
    /// this device only). The cloud board passes its own, since its assignee goes to Cloud with the task.
    func update(placeholder: String, submitTitle: String, doneTitle: String, metadata: TasksComposerMetadata, assigneeHint: String? = nil, l10n: SGTasksL10n, theme: PresentationTheme, fontSize: CGFloat) {
        self.fontSize = fontSize
        self.backgroundColor = theme.list.plainBackgroundColor
        self.separator.backgroundColor = theme.list.itemPlainSeparatorColor
        self.fieldBackground.backgroundColor = theme.list.itemInputField.backgroundColor
        self.textField.font = Font.regular(fontSize)
        self.textField.textColor = theme.list.itemInputField.primaryColor
        self.textField.tintColor = theme.list.itemAccentColor
        self.textField.keyboardAppearance = theme.rootController.keyboardColor.keyboardAppearance
        self.textField.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.font: Font.regular(fontSize), .foregroundColor: theme.list.itemInputField.placeholderColor])
        self.textField.accessibilityLabel = placeholder

        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: max(28.0, fontSize + 11.0), weight: .regular)
        self.submitButton.setImage(UIImage(systemName: "plus.circle.fill", withConfiguration: symbolConfiguration), for: .normal)
        self.submitButton.tintColor = theme.list.itemAccentColor
        self.submitButton.accessibilityLabel = submitTitle

        self.keyboardToolbar.barTintColor = theme.rootController.navigationBar.opaqueBackgroundColor
        self.keyboardToolbar.tintColor = theme.rootController.navigationBar.buttonColor
        self.keyboardDoneItem.title = doneTitle
        self.keyboardDoneItem.accessibilityLabel = doneTitle

        self.assigneeButton.update(symbolName: metadata.assigneeName == nil ? "person.crop.circle.badge.plus" : "person.crop.circle", text: metadata.assigneeName ?? l10n.tasks_assignee_title, isSet: metadata.assigneeName != nil, theme: theme, fontSize: fontSize)
        self.assigneeButton.accessibilityLabel = l10n.tasks_assignee_title
        self.assigneeButton.accessibilityValue = metadata.assigneeName ?? l10n.tasks_metadata_none
        self.assigneeButton.accessibilityHint = assigneeHint ?? l10n.tasks_a11y_pickAssigneeHint

        self.deadlineButton.update(symbolName: "calendar", text: metadata.deadlineText ?? l10n.tasks_deadline_title, isSet: metadata.deadlineText != nil, theme: theme, fontSize: fontSize)
        self.deadlineButton.accessibilityLabel = l10n.tasks_deadline_title
        self.deadlineButton.accessibilityValue = metadata.deadlineText ?? l10n.tasks_metadata_none
        self.deadlineButton.accessibilityHint = l10n.tasks_a11y_pickDeadlineHint

        let clearConfiguration = UIImage.SymbolConfiguration(pointSize: fontSize, weight: .regular)
        for (button, title) in [(self.assigneeClearButton, l10n.tasks_assignee_remove), (self.deadlineClearButton, l10n.tasks_deadline_remove)] {
            button.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: clearConfiguration), for: .normal)
            button.tintColor = theme.list.itemSecondaryTextColor
            button.accessibilityLabel = title
        }
        self.assigneeClearButton.isHidden = metadata.assigneeName == nil
        self.deadlineClearButton.isHidden = metadata.deadlineText == nil
        self.setNeedsLayout()
    }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        // A drag starting on a metadata button must still scroll a clipped composer.
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fieldRowHeight = TasksComposerView.fieldRowHeight(fontSize: self.fontSize)
        let left = 16.0 + self.horizontalInsets.left
        let right = 8.0 + self.horizontalInsets.right

        // Scroll only when clipped. A shrinking content is clamped, but never while the user drags.
        let contentHeight = self.preferredHeight(width: self.bounds.width)
        let contentSize = CGSize(width: self.bounds.width, height: contentHeight)
        if self.contentSize != contentSize {
            self.contentSize = contentSize
        }
        self.isScrollEnabled = contentHeight > self.bounds.height
        let maxOffsetY = max(0.0, contentHeight - self.bounds.height)
        if !self.isTracking && !self.isDecelerating && self.contentOffset.y > maxOffsetY {
            self.contentOffset = CGPoint(x: 0.0, y: maxOffsetY)
        }
        // The top separator stays at the visible top edge while the content scrolls.
        self.separator.frame = CGRect(x: 0.0, y: max(0.0, self.contentOffset.y), width: self.bounds.width, height: UIScreenPixel)

        let buttonFrame = CGRect(x: self.bounds.width - right - tasksMinimumHitSize, y: floor((fieldRowHeight - tasksMinimumHitSize) / 2.0), width: tasksMinimumHitSize, height: tasksMinimumHitSize)
        self.submitButton.frame = buttonFrame

        let fieldHeight = fieldRowHeight - 16.0
        let fieldFrame = CGRect(x: left, y: 8.0, width: max(0.0, buttonFrame.minX - 4.0 - left), height: fieldHeight)
        self.fieldBackground.frame = fieldFrame
        self.fieldBackground.layer.cornerRadius = min(18.0, fieldHeight / 2.0)
        self.textField.frame = fieldFrame.insetBy(dx: 12.0, dy: 0.0)

        let rowY = fieldRowHeight - 4.0
        let metadataLayout = self.metadataLayout(width: self.bounds.width)
        self.layoutMetadataHalf(button: self.assigneeButton, clearButton: self.assigneeClearButton, frame: metadataLayout.assignee.offsetBy(dx: 0.0, dy: rowY))
        self.layoutMetadataHalf(button: self.deadlineButton, clearButton: self.deadlineClearButton, frame: metadataLayout.deadline.offsetBy(dx: 0.0, dy: rowY))
    }

    private func layoutMetadataHalf(button: UIView, clearButton: UIView, frame: CGRect) {
        if clearButton.isHidden {
            button.frame = frame
            return
        }
        let clearWidth = min(tasksMinimumHitSize, frame.width)
        button.frame = CGRect(x: frame.minX, y: frame.minY, width: max(0.0, frame.width - clearWidth), height: frame.height)
        clearButton.frame = CGRect(x: frame.maxX - clearWidth, y: frame.minY, width: clearWidth, height: frame.height)
    }

    @objc private func assigneePressed() {
        self.pickAssignee?()
    }

    // After a remove, VoiceOver focus moves to the surviving select control (the remove button hides).
    @objc private func assigneeClearPressed() {
        self.clearAssignee?()
        UIAccessibility.post(notification: .layoutChanged, argument: self.assigneeButton)
    }

    @objc private func deadlinePressed() {
        self.pickDeadline?()
    }

    @objc private func deadlineClearPressed() {
        self.clearDeadline?()
        UIAccessibility.post(notification: .layoutChanged, argument: self.deadlineButton)
    }

    /// Gives the keyboard back to the title field (after a picker closed).
    func focusTitle() {
        self.textField.becomeFirstResponder()
    }

    /// The keyboard bar's Done: only puts the keyboard away. The draft, assignee and deadline stay,
    /// and nothing is submitted — the same as VoiceOver's escape gesture below.
    @objc private func dismissKeyboardPressed() {
        self.textField.resignFirstResponder()
    }

    /// VoiceOver's escape gesture (two-finger Z) puts the keyboard away, which also brings back the
    /// filter chips / scope switch that step aside in compact height. The draft is kept.
    override func accessibilityPerformEscape() -> Bool {
        guard self.textField.isFirstResponder else {
            return false
        }
        self.textField.resignFirstResponder()
        return true
    }

    @objc private func textChanged() {
        self.updateSubmitEnabled()
    }

    private func updateSubmitEnabled() {
        // Same rule as storage: invisible-only text never enables Add. An over-limit title stays
        // submittable so the user is told why it was refused.
        let text = self.textField.text ?? ""
        self.submitButton.isEnabled = tasksValidateTitle(text, limit: TasksTitleLimit.task) != .empty
    }

    @objc private func submitPressed() {
        self.performSubmit()
    }

    private func performSubmit() {
        let text = self.textField.text ?? ""
        guard let submit = self.submit, submit(text) else {
            return
        }
        self.textField.text = ""
        self.updateSubmitEnabled()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        self.performSubmit()
        // Keep the keyboard for rapid entry.
        return false
    }

    // Typing or pasting past the task-title limit is refused; dictation that bypasses this is caught
    // by the submit-time validation instead.
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let current = textField.text ?? ""
        let updated = (current as NSString).replacingCharacters(in: range, with: string)
        return tasksAcceptsDraftEdit(current: current, updated: updated)
    }
}

import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData

// Zenlygram — Tasks: the one board's root node (wf15 §3.3). Exactly one board is visible under the
// navigation bar — the device board or the account's synced board, as `TasksBoardSourceResolver`
// decides — and under the visible board, above its composer, at most one status line
// (`TasksSyncLine` rendered as `TasksSyncLineContent`): "Sinxronlash oʻchiq", "Akkaunt bogʻlangach
// sinxronlash boshlanadi" with Bogʻlash, the older rows' progress, the offer to sync older rows, the
// one-time other-account notice. Both boards keep their drafts and scroll positions while hidden.
// The read-only "Eski vazifalar" / "Sinxronlangan nusxa" screens reuse the node with one board and a
// plain footer. Like every node here it lays out its children against the layout it is given and
// never sets its own frame.

/// Stable accessibility identifiers of the status line (ids only, never content).
enum TasksSyncLineAccessibilityId {
    /// S2: the one footer line "Sinxronlash oʻchiq".
    static let syncOff = "sgtasks.sync.off"
    /// Every other status line of the single board.
    static let line = "sgtasks.sync.line"
    /// The footer of the read-only "Eski vazifalar" screen.
    static let olderFooter = "sgtasks.older.footer"
    static func action(_ name: String) -> String { "sgtasks.sync.action.\(name)" }
}

struct TasksSyncLineAction {
    let title: String
    let identifier: String
    let isPrimary: Bool
    let action: () -> Void
}

/// What the status line shows: one or two lines of text, optionally tappable as a whole (with a
/// chevron and a VoiceOver hint), and up to a few explicit buttons under it.
struct TasksSyncLineContent {
    let identifier: String
    let text: String
    let secondaryText: String?
    let hint: String?
    let tap: (() -> Void)?
    let actions: [TasksSyncLineAction]

    init(identifier: String, text: String, secondaryText: String? = nil, hint: String? = nil, tap: (() -> Void)? = nil, actions: [TasksSyncLineAction] = []) {
        self.identifier = identifier
        self.text = text
        self.secondaryText = secondaryText
        self.hint = hint
        self.tap = tap
        self.actions = actions
    }
}

private func tasksTextHeight(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
    guard width > 0.0, !text.isEmpty else {
        return 0.0
    }
    let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
    return ceil(rect.height)
}

/// The text row of the status line: one accessibility element, a button only while tappable.
private final class TasksSyncLineRow: UIControl {
    private let textLabel = UILabel()
    private let secondaryLabel = UILabel()
    private let chevronView = UIImageView()
    private var content: TasksSyncLineContent?
    private var fontSize: CGFloat = 17.0
    var horizontalInsets: (left: CGFloat, right: CGFloat) = (0.0, 0.0)

    static let verticalPadding: CGFloat = 10.0
    static let chevronWidth: CGFloat = 20.0
    static let chevronGap: CGFloat = 8.0
    static let lineSpacing: CGFloat = 2.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        for label in [self.textLabel, self.secondaryLabel] {
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.textAlignment = .natural
            label.isAccessibilityElement = false
            self.addSubview(label)
        }
        self.chevronView.contentMode = .center
        self.chevronView.isAccessibilityElement = false
        self.addSubview(self.chevronView)
        self.isAccessibilityElement = true
        self.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func textFont(_ fontSize: CGFloat) -> UIFont {
        return Font.regular(fontSize - 2.0)
    }

    private static func secondaryFont(_ fontSize: CGFloat) -> UIFont {
        return Font.regular(fontSize - 3.0)
    }

    func update(content: TasksSyncLineContent, theme: PresentationTheme, fontSize: CGFloat) {
        self.content = content
        self.fontSize = fontSize
        let tappable = content.tap != nil
        self.isUserInteractionEnabled = tappable
        self.textLabel.font = TasksSyncLineRow.textFont(fontSize)
        self.textLabel.textColor = tappable ? theme.list.itemPrimaryTextColor : theme.list.freeTextColor
        self.textLabel.text = content.text
        self.secondaryLabel.font = TasksSyncLineRow.secondaryFont(fontSize)
        self.secondaryLabel.textColor = theme.list.freeTextColor
        self.secondaryLabel.text = content.secondaryText
        self.secondaryLabel.isHidden = content.secondaryText == nil
        // Points forward in the reading direction (flips for right-to-left languages).
        self.chevronView.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: fontSize - 3.0, weight: .semibold))?.imageFlippedForRightToLeftLayoutDirection()
        self.chevronView.tintColor = theme.list.disclosureArrowColor
        self.chevronView.isHidden = !tappable
        self.accessibilityIdentifier = content.identifier
        self.accessibilityLabel = [content.text, content.secondaryText].compactMap { $0 }.joined(separator: ". ")
        self.accessibilityHint = tappable ? content.hint : nil
        self.accessibilityTraits = tappable ? .button : .staticText
        self.setNeedsLayout()
    }

    private func textWidth(_ width: CGFloat) -> CGFloat {
        let tappable = self.content?.tap != nil
        let chevron = tappable ? TasksSyncLineRow.chevronWidth + TasksSyncLineRow.chevronGap : 0.0
        return max(0.0, width - 16.0 - self.horizontalInsets.left - 16.0 - self.horizontalInsets.right - chevron)
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        guard let content = self.content else {
            return 0.0
        }
        let textWidth = self.textWidth(width)
        var height = tasksTextHeight(content.text, font: TasksSyncLineRow.textFont(self.fontSize), width: textWidth)
        if let secondary = content.secondaryText {
            height += TasksSyncLineRow.lineSpacing + tasksTextHeight(secondary, font: TasksSyncLineRow.secondaryFont(self.fontSize), width: textWidth)
        }
        return max(tasksMinimumHitSize, height + 2.0 * TasksSyncLineRow.verticalPadding)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let content = self.content else {
            return
        }
        let width = self.bounds.width
        let left = 16.0 + self.horizontalInsets.left
        let textWidth = self.textWidth(width)
        let textHeight = tasksTextHeight(content.text, font: TasksSyncLineRow.textFont(self.fontSize), width: textWidth)
        let secondaryHeight = content.secondaryText.map { tasksTextHeight($0, font: TasksSyncLineRow.secondaryFont(self.fontSize), width: textWidth) } ?? 0.0
        let contentHeight = textHeight + (content.secondaryText == nil ? 0.0 : TasksSyncLineRow.lineSpacing + secondaryHeight)
        let top = max(TasksSyncLineRow.verticalPadding, floor((self.bounds.height - contentHeight) / 2.0))
        // The text leads and the chevron trails: mirrored for right-to-left languages (the chevron
        // image is already flipped there, and the labels align naturally).
        let rightToLeft = self.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let right = width - 16.0 - self.horizontalInsets.right
        let textX = rightToLeft ? right - textWidth : left
        self.textLabel.frame = CGRect(x: textX, y: top, width: textWidth, height: textHeight)
        self.secondaryLabel.frame = CGRect(x: textX, y: top + textHeight + TasksSyncLineRow.lineSpacing, width: textWidth, height: secondaryHeight)
        let chevronX = rightToLeft ? left : right - TasksSyncLineRow.chevronWidth
        self.chevronView.frame = CGRect(x: chevronX, y: 0.0, width: TasksSyncLineRow.chevronWidth, height: self.bounds.height)
    }

    override var isHighlighted: Bool {
        didSet {
            self.alpha = self.isHighlighted && self.isUserInteractionEnabled ? 0.6 : 1.0
        }
    }

    @objc private func pressed() {
        self.content?.tap?()
    }
}

/// The status line: a hairline on top, the (tappable) text row, the explicit buttons under it. The
/// host sizes it with `preferredHeight(width:)` and places it between the visible board's table and
/// its composer; `update(content: nil, …)` hides it (height 0).
final class TasksSyncLineView: UIView {
    private let separator = UIView()
    private let row = TasksSyncLineRow()
    private var buttons: [TasksCloudCardButton] = []
    private var content: TasksSyncLineContent?
    private var fontSize: CGFloat = 17.0
    var horizontalInsets: (left: CGFloat, right: CGFloat) = (0.0, 0.0) {
        didSet {
            self.row.horizontalInsets = self.horizontalInsets
            self.setNeedsLayout()
        }
    }

    private static let separatorHeight: CGFloat = 0.5
    private static let buttonPadding: CGFloat = 10.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.separator.isAccessibilityElement = false
        self.addSubview(self.separator)
        self.addSubview(self.row)
        self.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func buttonFont(_ fontSize: CGFloat, isPrimary: Bool) -> UIFont {
        return isPrimary ? Font.semibold(fontSize - 1.0) : Font.regular(fontSize - 1.0)
    }

    func update(content: TasksSyncLineContent?, theme: PresentationTheme, fontSize: CGFloat) {
        self.content = content
        self.fontSize = fontSize
        self.backgroundColor = theme.list.itemBlocksBackgroundColor
        self.separator.backgroundColor = theme.list.itemBlocksSeparatorColor
        for button in self.buttons {
            button.removeFromSuperview()
        }
        self.buttons = []
        guard let content else {
            self.isHidden = true
            self.accessibilityElementsHidden = true
            return
        }
        self.isHidden = false
        self.accessibilityElementsHidden = false
        self.row.update(content: content, theme: theme, fontSize: fontSize)
        for (index, action) in content.actions.enumerated() {
            let button = TasksCloudCardButton()
            button.tag = index
            button.update(title: action.title, font: TasksSyncLineView.buttonFont(fontSize, isPrimary: action.isPrimary), color: theme.list.itemAccentColor)
            button.accessibilityIdentifier = action.identifier
            button.addTarget(self, action: #selector(self.buttonPressed(_:)), for: .touchUpInside)
            self.addSubview(button)
            self.buttons.append(button)
        }
        self.setNeedsLayout()
    }

    private func buttonWidth(_ width: CGFloat) -> CGFloat {
        return max(0.0, width - 16.0 - self.horizontalInsets.left - 16.0 - self.horizontalInsets.right)
    }

    private func buttonHeight(_ action: TasksSyncLineAction, width: CGFloat) -> CGFloat {
        let textHeight = tasksTextHeight(action.title, font: TasksSyncLineView.buttonFont(self.fontSize, isPrimary: action.isPrimary), width: self.buttonWidth(width))
        return max(tasksMinimumHitSize, textHeight + 2.0 * TasksSyncLineView.buttonPadding)
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        guard let content = self.content else {
            return 0.0
        }
        var height = TasksSyncLineView.separatorHeight + self.row.preferredHeight(width: width)
        for action in content.actions {
            height += self.buttonHeight(action, width: width)
        }
        return height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = self.bounds.width
        self.separator.frame = CGRect(x: 0.0, y: 0.0, width: width, height: TasksSyncLineView.separatorHeight)
        guard let content = self.content else {
            return
        }
        var y = TasksSyncLineView.separatorHeight
        let rowHeight = self.row.preferredHeight(width: width)
        self.row.frame = CGRect(x: 0.0, y: y, width: width, height: rowHeight)
        y += rowHeight
        let left = 16.0 + self.horizontalInsets.left
        for (index, button) in self.buttons.enumerated() where index < content.actions.count {
            let height = self.buttonHeight(content.actions[index], width: width)
            button.frame = CGRect(x: left, y: y, width: self.buttonWidth(width), height: height)
            y += height
        }
    }

    @objc private func buttonPressed(_ sender: UIControl) {
        guard let content = self.content, sender.tag >= 0, sender.tag < content.actions.count else {
            return
        }
        content.actions[sender.tag].action()
    }
}

final class TasksBoardHostNode: ASDisplayNode {
    private(set) var localNode: TasksBoardNode?
    private(set) var cloudNode: TasksCloudBoardNode?
    private(set) var source: TasksBoardSource
    private let lineView = TasksSyncLineView()
    private var lineContent: TasksSyncLineContent?
    private var lineHeight: CGFloat = 0.0
    private var presentationData: PresentationData
    private var validLayout: (layout: ContainerViewLayout, navigationHeight: CGFloat)?

    /// `localNode`: the device board (nil for the synced-copy screen); `cloudNode`: the synced board,
    /// or nil until the host sets it (`setCloudNode`) the first time the source is `synced`.
    init(localNode: TasksBoardNode?, cloudNode: TasksCloudBoardNode?, source: TasksBoardSource, presentationData: PresentationData) {
        self.localNode = localNode
        self.cloudNode = cloudNode
        self.source = source
        self.presentationData = presentationData
        super.init()
        if let localNode {
            self.addSubnode(localNode)
        }
        if let cloudNode {
            self.addSubnode(cloudNode)
        }
    }

    override func didLoad() {
        super.didLoad()
        self.view.addSubview(self.lineView)
        self.applySource()
        self.applyLine()
    }

    /// The synced board, created the first time the source is `synced`; kept afterwards so its
    /// drafts and scroll position survive a flip back.
    func setCloudNode(_ node: TasksCloudBoardNode) {
        guard self.cloudNode == nil else {
            return
        }
        if let localNode = self.localNode {
            self.insertSubnode(node, aboveSubnode: localNode)
        } else {
            self.insertSubnode(node, at: 0)
        }
        self.cloudNode = node
        if self.isNodeLoaded {
            // The status line stays above both boards.
            self.view.bringSubviewToFront(self.lineView)
            self.applySource()
        }
        self.relayout()
    }

    func update(source: TasksBoardSource) {
        self.source = source
        if self.isNodeLoaded {
            self.applySource()
        }
        self.relayout()
    }

    func update(line: TasksSyncLineContent?) {
        self.lineContent = line
        if self.isNodeLoaded {
            self.applyLine()
        }
        self.relayout()
    }

    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        self.localNode?.updatePresentationData(presentationData)
        self.cloudNode?.updatePresentationData(presentationData)
        if self.isNodeLoaded {
            self.applySource()
            self.applyLine()
        }
        self.relayout()
    }

    private var showsCloud: Bool {
        if case .synced = self.source, self.cloudNode != nil {
            return true
        }
        return false
    }

    private var visibleBottomOccupiedHeight: CGFloat? {
        if self.showsCloud {
            return self.cloudNode?.bottomOccupiedHeight
        }
        return self.localNode?.bottomOccupiedHeight
    }

    private func applySource() {
        self.backgroundColor = self.presentationData.theme.list.blocksBackgroundColor
        let showsCloud = self.showsCloud
        self.localNode?.isHidden = showsCloud
        self.localNode?.accessibilityElementsHidden = showsCloud
        self.cloudNode?.isHidden = !showsCloud
        self.cloudNode?.accessibilityElementsHidden = !showsCloud
    }

    private func applyLine() {
        self.lineView.update(content: self.lineContent, theme: self.presentationData.theme, fontSize: self.presentationData.listsFontSize.itemListBaseFontSize)
    }

    private func relayout() {
        if let validLayout = self.validLayout {
            self.containerLayoutUpdated(validLayout.layout, navigationHeight: validLayout.navigationHeight, transition: .immediate)
        }
    }

    /// The visible board's keyboard / tab-bar inset plus its composer plus the status line: the Undo
    /// toast sits above all three.
    var bottomOccupiedHeight: CGFloat {
        let boardHeight: CGFloat
        if let visible = self.visibleBottomOccupiedHeight {
            boardHeight = visible
        } else if let layout = self.validLayout?.layout {
            boardHeight = max(layout.intrinsicInsets.bottom, layout.inputHeight ?? 0.0)
        } else {
            boardHeight = 0.0
        }
        return boardHeight + self.lineHeight
    }

    func scrollToTop() {
        if self.showsCloud {
            self.cloudNode?.scrollToTop()
        } else {
            self.localNode?.scrollToTop()
        }
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        self.validLayout = (layout, navigationHeight)
        let size = layout.size
        self.lineView.horizontalInsets = (layout.safeInsets.left, layout.safeInsets.right)
        let lineHeight = self.lineView.preferredHeight(width: size.width)
        self.lineHeight = lineHeight

        // Both boards get the whole area and keep the line's strip free above their composer.
        let childFrame = CGRect(origin: CGPoint(), size: size)
        if let localNode = self.localNode {
            transition.updateFrame(node: localNode, frame: childFrame)
            localNode.containerLayoutUpdated(layout, navigationHeight: navigationHeight, footerHeight: lineHeight, transition: transition)
        }
        if let cloudNode = self.cloudNode {
            transition.updateFrame(node: cloudNode, frame: childFrame)
            cloudNode.containerLayoutUpdated(layout, navigationHeight: navigationHeight, footerHeight: lineHeight, transition: transition)
        }

        // The line sits right above the visible board's composer (or above the tab bar / keyboard
        // when the board has no composer) and never above the navigation bar.
        let occupied = self.visibleBottomOccupiedHeight ?? max(layout.intrinsicInsets.bottom, layout.inputHeight ?? 0.0)
        let lineY = max(navigationHeight, size.height - occupied - lineHeight)
        transition.updateFrame(view: self.lineView, frame: CGRect(x: 0.0, y: lineY, width: size.width, height: lineHeight))
    }
}

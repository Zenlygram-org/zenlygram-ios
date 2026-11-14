import Foundation
import UIKit
import Display
import TelegramPresentationData

// Zenlygram — synced Tasks board cells: gate / sync banner / notice cards with explicit action
// buttons, and disclosure rows (unsent changes, invitations). Every control is at least 44 pt and
// text wraps at any Dynamic Type size; nothing depends on color alone. The status line under the
// board (wf15 §3) reuses the card button (`TasksCloudCardButton`, TasksBoardHostNode.swift).

/// Stable accessibility identifiers for the synced board (ids only, never content).
enum TasksCloudAccessibilityId {
    static let gate = "sgtasks.cloud.gate"
    static let banner = "sgtasks.cloud.banner"
    static let unsent = "sgtasks.cloud.unsent"
    static let invitations = "sgtasks.cloud.invitations"
    static let privacy = "sgtasks.cloud.privacy"
    /// The footer of the read-only "Sinxronlangan nusxa" view.
    static let syncedCopy = "sgtasks.cloud.syncedCopy"
    static func notice(_ id: Int64) -> String { "sgtasks.cloud.notice.\(id)" }
    static func action(_ name: String) -> String { "sgtasks.cloud.action.\(name)" }
}

struct TasksCloudCardAction {
    let title: String
    let identifier: String
    let isPrimary: Bool
    let action: () -> Void
}

/// A card action: wrapping body text that grows the control with it (a system button keeps a
/// one-line height and lets wrapped text spill out), at least 44 pt tall, leading-aligned. Same
/// pattern as the deadline sheet's remove button. Also the status line's buttons.
final class TasksCloudCardButton: UIControl {
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.titleLabel.numberOfLines = 0
        self.titleLabel.lineBreakMode = .byWordWrapping
        self.titleLabel.textAlignment = .natural
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = false
        self.titleLabel.isAccessibilityElement = false
        self.addSubview(self.titleLabel)
        NSLayoutConstraint.activate([
            self.titleLabel.topAnchor.constraint(equalTo: self.topAnchor, constant: 10.0),
            self.titleLabel.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -10.0),
            self.titleLabel.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.titleLabel.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.heightAnchor.constraint(greaterThanOrEqualToConstant: tasksMinimumHitSize)
        ])
        self.isAccessibilityElement = true
        self.accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, font: UIFont, color: UIColor) {
        self.titleLabel.text = title
        self.titleLabel.font = font
        self.titleLabel.textColor = color
        self.accessibilityLabel = title
    }

    override var isHighlighted: Bool {
        didSet {
            self.alpha = self.isHighlighted ? 0.6 : 1.0
        }
    }
}

/// A card: optional title, wrapping text and up to a few buttons (each its own accessibility element).
final class TasksCloudCardCell: UITableViewCell {
    static let reuseIdentifier = "TasksCloudCardCell"

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let textStack = UIStackView()
    private let buttonStack = UIStackView()
    private let outerStack = UIStackView()
    private var actions: [TasksCloudCardAction] = []

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.selectionStyle = .none
        // A container, never one merged element: the text and each button are reached separately.
        self.isAccessibilityElement = false

        self.iconView.contentMode = .center
        self.iconView.isAccessibilityElement = false
        self.iconView.setContentHuggingPriority(.required, for: .horizontal)
        self.iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        for label in [self.titleLabel, self.bodyLabel] {
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
        }
        self.textStack.axis = .vertical
        self.textStack.spacing = 4.0
        self.textStack.addArrangedSubview(self.titleLabel)
        self.textStack.addArrangedSubview(self.bodyLabel)
        // Title and text read as one element; buttons stay separate elements after it.
        self.textStack.isAccessibilityElement = true
        self.textStack.accessibilityTraits = .staticText

        let header = UIStackView(arrangedSubviews: [self.iconView, self.textStack])
        header.axis = .horizontal
        header.alignment = .top
        header.spacing = 10.0

        self.buttonStack.axis = .vertical
        self.buttonStack.spacing = 0.0
        // Buttons take the card's full width, so their text wraps instead of overflowing.
        self.buttonStack.alignment = .fill

        self.outerStack.axis = .vertical
        self.outerStack.spacing = 4.0
        self.outerStack.translatesAutoresizingMaskIntoConstraints = false
        self.outerStack.addArrangedSubview(header)
        self.outerStack.addArrangedSubview(self.buttonStack)
        self.contentView.addSubview(self.outerStack)

        NSLayoutConstraint.activate([
            self.outerStack.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 16.0),
            self.outerStack.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -16.0),
            self.outerStack.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 12.0),
            self.outerStack.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -6.0)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(symbolName: String?, title: String?, text: String, actions: [TasksCloudCardAction], identifier: String, isPlain: Bool, theme: PresentationTheme, fontSize: CGFloat) {
        self.actions = actions
        self.backgroundColor = isPlain ? .clear : theme.list.itemBlocksBackgroundColor
        self.textStack.accessibilityIdentifier = identifier

        if let symbolName {
            self.iconView.image = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: fontSize, weight: .semibold))
            self.iconView.tintColor = theme.list.itemAccentColor
            self.iconView.isHidden = false
        } else {
            self.iconView.image = nil
            self.iconView.isHidden = true
        }

        self.titleLabel.font = Font.semibold(fontSize)
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.titleLabel.text = title
        self.titleLabel.isHidden = title == nil

        self.bodyLabel.font = Font.regular(isPlain ? fontSize - 3.0 : fontSize - 2.0)
        // Body text uses the readable secondary color (freeTextColor ≈ 5:1), not the decorative one.
        self.bodyLabel.textColor = theme.list.freeTextColor
        self.bodyLabel.text = text
        self.textStack.accessibilityLabel = [title, text].compactMap { $0 }.joined(separator: ". ")

        for view in self.buttonStack.arrangedSubviews {
            self.buttonStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, action) in actions.enumerated() {
            let button = TasksCloudCardButton()
            button.tag = index
            button.update(title: action.title, font: action.isPrimary ? Font.semibold(fontSize) : Font.regular(fontSize), color: theme.list.itemAccentColor)
            button.accessibilityIdentifier = action.identifier
            button.addTarget(self, action: #selector(self.buttonPressed(_:)), for: .touchUpInside)
            self.buttonStack.addArrangedSubview(button)
        }
        self.buttonStack.isHidden = actions.isEmpty
    }

    @objc private func buttonPressed(_ sender: UIControl) {
        guard sender.tag >= 0, sender.tag < self.actions.count else {
            return
        }
        self.actions[sender.tag].action()
    }
}

/// A tappable row with a title, an optional trailing value and a chevron; at least 44 pt tall.
final class TasksCloudDisclosureCell: UITableViewCell {
    static let reuseIdentifier = "TasksCloudDisclosureCell"

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let chevronView = UIImageView()
    private let highlightView = UIView()
    private let accessibleRow = TasksAccessibleRowView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.selectedBackgroundView = self.highlightView
        self.isAccessibilityElement = false

        for view in [self.iconView, self.titleLabel, self.chevronView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isAccessibilityElement = false
            self.contentView.addSubview(view)
        }
        self.iconView.contentMode = .center
        self.chevronView.contentMode = .center
        self.titleLabel.numberOfLines = 0
        self.accessibleRow.accessibilityTraits = .button
        self.accessibleRow.pin(to: self.contentView)

        NSLayoutConstraint.activate([
            self.iconView.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 16.0),
            self.iconView.centerYAnchor.constraint(equalTo: self.contentView.centerYAnchor),
            self.iconView.widthAnchor.constraint(equalToConstant: 28.0),
            self.titleLabel.leadingAnchor.constraint(equalTo: self.iconView.trailingAnchor, constant: 8.0),
            self.titleLabel.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 12.0),
            self.titleLabel.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -12.0),
            self.titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: self.chevronView.leadingAnchor, constant: -8.0),
            self.titleLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: tasksMinimumHitSize - 24.0),
            self.chevronView.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -16.0),
            self.chevronView.centerYAnchor.constraint(equalTo: self.contentView.centerYAnchor),
            self.chevronView.widthAnchor.constraint(equalToConstant: 20.0)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(symbolName: String, title: String, hint: String?, identifier: String, theme: PresentationTheme, fontSize: CGFloat, activate: @escaping () -> Void) {
        self.backgroundColor = theme.list.itemBlocksBackgroundColor
        self.highlightView.backgroundColor = theme.list.itemHighlightedBackgroundColor
        self.iconView.image = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: fontSize, weight: .regular))
        self.iconView.tintColor = theme.list.itemAccentColor
        self.titleLabel.font = Font.regular(fontSize)
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.titleLabel.text = title
        // Points forward in the reading direction (flips for right-to-left languages).
        self.chevronView.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: fontSize - 3.0, weight: .semibold))?.imageFlippedForRightToLeftLayoutDirection()
        self.chevronView.tintColor = theme.list.disclosureArrowColor
        self.accessibleRow.accessibilityIdentifier = identifier
        self.accessibleRow.accessibilityLabel = title
        self.accessibleRow.accessibilityHint = hint
        self.accessibleRow.activate = activate
    }
}

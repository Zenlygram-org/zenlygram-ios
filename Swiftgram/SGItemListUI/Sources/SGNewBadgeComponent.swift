import Foundation
import UIKit
import ComponentFlow

// A small green capsule "NEW" pill used as the titleBadgeComponent for
// ItemListSwitchItem / ItemListDisclosureItem rows that carry a new-feature badge.
//
// Usage:
//   let badge: AnyComponent<Empty>? = isNew ? AnyComponent(SGNewBadgeComponent(langCode: langCode)) : nil
//   ItemListSwitchItem(... titleBadgeComponent: badge ...)
//
// Lifecycle: the isNew flag is computed per row via SGNewBadgeTracker.shouldShow(key)
// (SGSimpleSettings module), which persists a first-seen timestamp in UserDefaults.
// The badge retires automatically when the user interacts with the row
// (SGNewBadgeTracker.markInteracted — the switch is toggled / the disclosure is opened)
// or 30 days after it was first seen; call sites do not need to be edited by hand.

// Localised label text for the badge pill.
private enum SGNewBadgeLabel {
    static func text(langCode: String) -> String {
        switch langCode {
        case "uz": return "YANGI"
        case "ru": return "НОВОЕ"
        default:   return "NEW"
        }
    }
}

// Matches the settings row-icon green (SGSettingsIconColor.green, #34C759 — see
// SGSettingsIcons.swift) so every green "new" affordance in settings shares one color.
private let sgNewBadgeGreen = SGSettingsIconColor.green.uiColor

public final class SGNewBadgeComponent: Component {

    public typealias EnvironmentType = Empty

    let langCode: String

    public init(langCode: String) {
        self.langCode = langCode
    }

    /// The badge's localized text — used as the VoiceOver suffix for rows that carry
    /// the badge (the pill itself is decorative and invisible to accessibility).
    public static func accessibilityLabel(langCode: String) -> String {
        return SGNewBadgeLabel.text(langCode: langCode)
    }

    public static func == (lhs: SGNewBadgeComponent, rhs: SGNewBadgeComponent) -> Bool {
        return lhs.langCode == rhs.langCode
    }

    public final class View: UIView {
        private let label = UILabel()

        override init(frame: CGRect) {
            super.init(frame: frame)
            // Pill background — green capsule drawn at layout time via cornerRadius
            backgroundColor = sgNewBadgeGreen
            clipsToBounds = true

            // Decorative for VoiceOver: the row announces the badge itself (`titleBadgeAccessibilityLabel`,
            // "<title>, NEW"). The pill is a sibling of the row's accessibility area, not a child of it, and
            // a UILabel is an accessibility element by default — without this VoiceOver stopped on "NEW" a
            // second time after every badged row (seven on a fresh Settings hub).
            isAccessibilityElement = false
            accessibilityElementsHidden = true

            label.textColor = .white
            label.isAccessibilityElement = false
            label.font = UIFont.systemFont(ofSize: 11, weight: .bold)
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        required init?(coder: NSCoder) { nil }

        func update(component: SGNewBadgeComponent, availableSize: CGSize) -> CGSize {
            label.text = SGNewBadgeLabel.text(langCode: component.langCode)

            // Measure text to size the pill
            let textSize = label.sizeThatFits(CGSize(width: 60, height: 20))
            let pillW = ceil(textSize.width) + 10  // 5pt padding each side
            let pillH: CGFloat = 18
            layer.cornerRadius = pillH / 2
            return CGSize(width: pillW, height: pillH)
        }
    }

    public func makeView() -> View {
        return View()
    }

    public func update(
        view: View,
        availableSize: CGSize,
        state: EmptyComponentState,
        environment: Environment<Empty>,
        transition: ComponentTransition
    ) -> CGSize {
        return view.update(component: self, availableSize: availableSize)
    }
}

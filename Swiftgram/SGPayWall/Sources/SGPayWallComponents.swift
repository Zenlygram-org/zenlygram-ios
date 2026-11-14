import Foundation
import SwiftUI
import UIKit
import SGSwiftUI

// MARK: Zenlygram — the shared visual vocabulary of the paywall, the status screen and the link
// screen.
//
// Presentation only. Nothing here decides what is shown, what a button does or what a state means:
// every string arrives localized and every action arrives as a closure owned by the screen. The
// pieces exist so the three screens share one hierarchy — a grouped neutral surface, one accent,
// status that is told by symbol shape AND words, never by colour alone — and so every tappable row
// keeps at least a 44 pt target.
//
// iOS 13 is the floor: no `Label`, no `ScaledMetric`, no materials required for legibility. Text
// uses text styles only, so all of it follows Dynamic Type and wraps instead of clipping.

/// The deep brand blue behind a filled control's white label — the darker shade of the existing
/// palette, so the white label does not depend on a large-text contrast allowance at any Dynamic
/// Type size.
let sgPayWallAccentFill = Color(hex: "0A5BD6")

/// The brand blue for text and symbols drawn ON a neutral surface: a step deeper in light mode and a
/// step lighter in dark mode, so footnote-sized accent text keeps 4.5:1 against the grouped surfaces
/// of either appearance.
let sgPayWallAccentText = Color(UIColor { traits in
    if traits.userInterfaceStyle == .dark {
        return UIColor(red: 0x4A / 255.0, green: 0xA3 / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
    }
    return UIColor(red: 0x0A / 255.0, green: 0x5B / 255.0, blue: 0xD6 / 255.0, alpha: 1.0)
})

/// Red for destructive text and symbols on a neutral surface: a deeper red in light mode, the
/// system red in dark mode.
private let sgPayWallDestructiveText = Color(UIColor { traits in
    if traits.userInterfaceStyle == .dark {
        return UIColor.systemRed.resolvedColor(with: traits)
    }
    return UIColor(red: 0xD7 / 255.0, green: 0x00 / 255.0, blue: 0x15 / 255.0, alpha: 1.0)
})

private let sgPayWallGroupCornerRadius: CGFloat = 14

private struct SGPayWallSecondaryTextKey: EnvironmentKey {
    static let defaultValue: Color = .secondary
}

private struct SGPayWallGroupedCardKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// Secondary text in the shared views. The system's, except where a cosmic screen — the paywall,
    /// the status screen — sets `SGPayWallPalette.secondaryText` (the day ink by day, the system's at
    /// night). The link screen never sets it.
    var sgPayWallSecondaryText: Color {
        get { return self[SGPayWallSecondaryTextKey.self] }
        set { self[SGPayWallSecondaryTextKey.self] = newValue }
    }

    /// Grouped blocks drawn as the cosmic design's cards (`SGPayWallPalette`) instead of the system's
    /// grey: set by the paywall by day, and by the status screen night and day.
    var sgPayWallGroupedCard: Bool {
        get { return self[SGPayWallGroupedCardKey.self] }
        set { self[SGPayWallGroupedCardKey.self] = newValue }
    }
}

/// The surface every grouped block sits on: one neutral step above the screen background, in light
/// and dark alike. Where a screen sets `sgPayWallGroupedCard` it is the design's own card instead —
/// white by day, since the system's grey is no step at all above the pale sky, and the dark glass at
/// night. The paywall sets it by day only; the status screen, night and day.
struct SGPayWallGroupBackground: ViewModifier {
    @Environment(\.sgPayWallGroupedCard) private var groupedCard: Bool
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    func body(content: Content) -> some View {
        let card = SGPayWallPalette(self.colorScheme)
        return content
            .background(
                Group {
                    if self.groupedCard {
                        RoundedRectangle(cornerRadius: sgPayWallGroupCornerRadius, style: .continuous)
                            .fill(card.cardFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: sgPayWallGroupCornerRadius, style: .continuous)
                                    .stroke(card.cardStroke, lineWidth: 1)
                            )
                            .shadow(color: card.cardShadow, radius: 14, x: 0, y: 4)
                    } else {
                        RoundedRectangle(cornerRadius: sgPayWallGroupCornerRadius, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    }
                }
            )
    }
}

extension View {
    func sgPayWallGrouped() -> some View {
        return self.modifier(SGPayWallGroupBackground())
    }
}

/// A section title. VoiceOver's rotor lists it as a heading.
struct SGPayWallSectionHeader: View {
    let title: String
    var font: Font = .headline
    var color: Color = .primary

    var body: some View {
        HStack {
            Text(title)
                .font(font)
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibility(addTraits: .isHeader)
            Spacer(minLength: 0)
        }
    }
}

/// The one filled button of a screen. At least 50 pt tall, and the label wraps instead of clipping
/// at the accessibility text sizes. Dims itself when the enclosing button is disabled — except
/// while busy, when the spinner and the title ("Purchasing…") are the thing to read.
struct SGPayWallPrimaryButtonLabel: View {
    @Environment(\.isEnabled) private var isEnabled: Bool

    let title: String
    var isBusy: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            if isBusy {
                // The spinner sits on the brand fill in either appearance; the dark variant is the
                // light-on-dark one.
                SGPayWallSpinner()
                    .environment(\.colorScheme, .dark)
                    .accessibility(hidden: true)
            }
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .foregroundColor(.white)
        .background(
            RoundedRectangle(cornerRadius: sgPayWallGroupCornerRadius, style: .continuous)
                .fill(sgPayWallAccentFill)
        )
        .opacity(isEnabled || isBusy ? 1.0 : 0.5)
        .contentShape(RoundedRectangle(cornerRadius: sgPayWallGroupCornerRadius, style: .continuous))
    }
}

/// A secondary action in a grouped list: symbol, title, optional explanation, and a trailing glyph
/// that says whether it opens a screen here (chevron) or leaves the app (arrow).
struct SGPayWallActionRow: View {
    @Environment(\.sgPayWallSecondaryText) private var secondaryText: Color

    enum Trailing {
        case none
        case chevron
        case external
    }

    let symbol: String
    let title: String
    var detail: String? = nil
    var trailing: Trailing = .chevron
    var isBusy: Bool = false
    var isEnabled: Bool = true
    /// Words carry the meaning ("Unlink This Device"); the red only repeats it.
    var isDestructive: Bool = false
    let action: () -> Void

    private var tint: Color {
        return isDestructive ? sgPayWallDestructiveText : sgPayWallAccentText
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol)
                    .font(Font.body.weight(.medium))
                    .foregroundColor(tint)
                    .frame(minWidth: 28, minHeight: 28)
                    .accessibility(hidden: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundColor(tint)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundColor(secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailingView
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!isEnabled)
        // A row that is busy is disabled too, but it is the one thing happening: keep it legible.
        .opacity(isEnabled || isBusy ? 1.0 : 0.5)
    }

    @ViewBuilder
    private var trailingView: some View {
        if isBusy {
            SGPayWallSpinner()
                .accessibility(hidden: true)
        } else {
            switch trailing {
            case .none:
                EmptyView()
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(Font.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                    .accessibility(hidden: true)
            case .external:
                Image(systemName: "arrow.up.right")
                    .font(Font.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                    .accessibility(hidden: true)
            }
        }
    }
}

/// A hairline between rows of one group, inset past the row symbol.
struct SGPayWallRowDivider: View {
    var leadingInset: CGFloat = 56

    var body: some View {
        Divider()
            .padding(.leading, leadingInset)
    }
}

/// What a message next to the purchase options is. The tone picks a symbol of a DIFFERENT SHAPE for
/// each kind, so pending, done, informational and needs-attention are told apart without colour.
enum SGPayWallNoticeTone: Equatable {
    case info
    case success
    case pending
    case warning

    var symbol: String {
        switch self {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .pending:
            return "clock.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info:
            return .secondary
        case .success:
            return Color(.systemGreen)
        case .pending:
            return sgPayWallAccentText
        case .warning:
            return Color(.systemOrange)
        }
    }
}

/// A localized message, an optional second line, and its tone. The screens decide all three; this
/// only carries them.
struct SGPayWallNotice: Equatable {
    let text: String
    var detail: String? = nil
    let tone: SGPayWallNoticeTone
}

struct SGPayWallNoticeView: View {
    @Environment(\.sgPayWallSecondaryText) private var secondaryText: Color

    let notice: SGPayWallNotice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.tone.symbol)
                .font(Font.subheadline.weight(.semibold))
                .foregroundColor(notice.tone.tint)
                .padding(.top, 1)
                .accessibility(hidden: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.text)
                    .font(notice.detail == nil ? Font.footnote : Font.subheadline)
                    .fontWeight(notice.detail == nil ? Font.Weight.regular : Font.Weight.medium)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = notice.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundColor(secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .sgPayWallGrouped()
        .accessibilityElement(children: .combine)
    }
}

/// The current status under the status screen's hero ("Active until …"): a symbol and the words in
/// the glowing brand outline of the paywall's stats strip. The symbol's shape differs per state; the
/// tint only repeats it. A rounded rectangle that reads as a capsule on one line, so a long status
/// wraps, centred, instead of being cut.
struct SGPayWallStatusPill: View {
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        let palette = SGPayWallPalette(self.colorScheme)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(Font.subheadline.weight(.semibold))
                .foregroundColor(tint)
                .accessibility(hidden: true)
            Text(text)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(palette.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.stripFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(sgPayWallBrandGradient, lineWidth: 1.5)
        )
        .shadow(color: sgPayWallCosmicViolet.opacity(0.35 * palette.glowScale), radius: 12, x: 0, y: 0)
        .accessibilityElement(children: .combine)
    }
}

/// The close glyph: a small filled circle, drawn inside a fixed 44 pt target the caller positions.
/// The glyph keeps a fixed size on purpose — it must never outgrow the target it sits in.
struct SGPayWallCloseGlyph: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.secondary)
            .frame(width: 30, height: 30)
            .background(
                Circle()
                    .fill(Color(.tertiarySystemFill))
            )
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

/// A spinner that exists on iOS 13 as well as on iOS 14+.
struct SGPayWallSpinner: View {
    var body: some View {
        if #available(iOS 14.0, *) {
            ProgressView()
        } else {
            SGPayWallLegacySpinner()
        }
    }
}

struct SGPayWallLegacySpinner: UIViewRepresentable {
    func makeUIView(context: Context) -> UIActivityIndicatorView {
        let view = UIActivityIndicatorView(style: .medium)
        view.startAnimating()
        return view
    }

    func updateUIView(_ uiView: UIActivityIndicatorView, context: Context) {
    }
}

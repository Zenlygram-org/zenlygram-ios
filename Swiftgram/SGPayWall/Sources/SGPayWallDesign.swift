import Foundation
import SwiftUI
import UIKit
import SGSwiftUI

// MARK: Zenlygram — the paywall's "cosmic" look: a starry blue–violet backdrop, the glowing Z mark
// with its orbit, a gradient "Pro", a stats strip, glass cards, and a gradient purchase button.
//
// Presentation only, like `SGPayWallComponents`: every string arrives localized and every action
// arrives as a closure owned by `SGPayWallView`. Nothing here decides what is sold or at what
// price — prices are StoreKit's `displayPrice` strings, passed through untouched.
//
// iOS 13 is the floor: gradients, masks, shadows and SF Symbols only. A symbol missing on an older
// OS simply draws nothing; every text next to it still names the thing.

// MARK: - Palette

let sgPayWallCosmicBlue = Color(hex: "3D7BFF")
let sgPayWallCosmicViolet = Color(hex: "9B5CFF")
let sgPayWallCosmicDeep = Color(hex: "05040D")

/// The brand gradient: blue on the leading edge, violet on the trailing one.
let sgPayWallBrandGradient = LinearGradient(
    gradient: Gradient(colors: [sgPayWallCosmicBlue, sgPayWallCosmicViolet]),
    startPoint: .leading,
    endPoint: .trailing
)

private let sgPayWallCardRadius: CGFloat = 22

/// `Font.title3` with a weight: 20 pt at the default text size, scaled with Dynamic Type like every
/// other text on the paywall. `title3` is iOS 14+; on iOS 13 the closest style is `headline`.
private func sgPayWallTitle3(_ weight: Font.Weight) -> Font {
    if #available(iOS 14.0, *) {
        return Font.title3.weight(weight)
    } else {
        return Font.headline.weight(weight)
    }
}

// MARK: - Day and night

/// The paywall's colours for night or day. At night it is the cosmic dark design exactly as drawn;
/// by day the same layout on a pale violet-white sky with deep violet-navy ink. The brand pieces
/// (the blue-violet gradient, the purchase button, the feature tiles, the Z tile) are the same in
/// both. The dark values below are the design's own; changing one changes the night design.
struct SGPayWallPalette {
    let isDark: Bool

    init(isDark: Bool) {
        self.isDark = isDark
    }

    init(_ colorScheme: ColorScheme) {
        self.isDark = colorScheme == .dark
    }

    /// Day ink: text and glyphs by day.
    private static let ink = Color(hex: "17152F")

    // Sky
    var backdrop: Color { return self.isDark ? sgPayWallCosmicDeep : Color(hex: "F6F5FD") }
    var nebulaTop: [Color] {
        return self.isDark
            ? [sgPayWallCosmicViolet.opacity(0.55), sgPayWallCosmicBlue.opacity(0.18), Color.clear]
            : [sgPayWallCosmicViolet.opacity(0.20), sgPayWallCosmicBlue.opacity(0.08), Color.clear]
    }
    var nebulaSide: Color { return sgPayWallCosmicBlue.opacity(self.isDark ? 0.22 : 0.10) }
    var star: Color { return self.isDark ? Color.white : sgPayWallCosmicViolet }
    var starOpacityScale: Double { return self.isDark ? 1.0 : 0.35 }
    /// Glows and coloured shadows: full at night, softer by day, where they would read as smudges.
    var glowScale: Double { return self.isDark ? 1.0 : 0.45 }

    // Text
    var textPrimary: Color { return self.isDark ? Color.white : SGPayWallPalette.ink }
    var heroSubtitle: Color { return self.isDark ? Color.white.opacity(0.72) : SGPayWallPalette.ink.opacity(0.68) }
    /// Secondary text: the system's at night, as drawn. By day the system's grey is about 3.3:1 on
    /// the pale sky, so it is the ink at 66% (about 5.5:1).
    var secondaryText: Color { return self.isDark ? Color.secondary : SGPayWallPalette.ink.opacity(0.66) }
    var proGradient: [Color] {
        return self.isDark ? [Color(hex: "8FA8FF"), sgPayWallCosmicViolet] : [Color(hex: "3D6BFF"), Color(hex: "8A45F5")]
    }

    // Stats strip
    var pillText: Color { return self.isDark ? Color(hex: "C9B5FF") : Color(hex: "6A3BD8") }
    var pillFill: Color { return sgPayWallCosmicViolet.opacity(self.isDark ? 0.22 : 0.12) }
    var pillStroke: Color { return sgPayWallCosmicViolet.opacity(self.isDark ? 0.7 : 0.45) }
    var stripFill: Color { return self.isDark ? Color.white.opacity(0.04) : Color.white.opacity(0.8) }
    var stripDivider: Color { return self.isDark ? Color.white.opacity(0.14) : SGPayWallPalette.ink.opacity(0.12) }
    var statSymbol: Color { return self.isDark ? Color(hex: "B49BFF") : Color(hex: "7A4CF0") }
    var statSubtitle: Color { return self.isDark ? Color.white.opacity(0.65) : SGPayWallPalette.ink.opacity(0.66) }

    // Cards
    var cardFill: Color { return self.isDark ? Color(hex: "14131F").opacity(0.92) : Color.white.opacity(0.96) }
    var cardStroke: Color { return self.isDark ? Color.white.opacity(0.08) : SGPayWallPalette.ink.opacity(0.08) }
    /// By day a white card on a pale sky needs a lift; the dark glass has none.
    var cardShadow: Color { return self.isDark ? Color.clear : sgPayWallCosmicViolet.opacity(0.10) }
    var hairline: Color { return self.isDark ? Color.white.opacity(0.08) : SGPayWallPalette.ink.opacity(0.08) }

    // Plans
    /// By day 50% ink (3.4:1 on the white card): an unselected radio needs 3:1, as the night ring has.
    var radioStroke: Color { return self.isDark ? Color.white.opacity(0.35) : SGPayWallPalette.ink.opacity(0.5) }
    /// By day a solid violet: white on the night's 55% violet over white would be unreadable.
    var badgeFill: Color { return self.isDark ? sgPayWallCosmicViolet.opacity(0.55) : Color(hex: "7A3FF2") }
    var badgeStroke: Color { return self.isDark ? sgPayWallCosmicViolet : Color(hex: "7A3FF2") }
    var planSummary: Color { return self.isDark ? Color.white.opacity(0.6) : SGPayWallPalette.ink.opacity(0.62) }
    var priceUnselected: Color { return self.isDark ? Color.white.opacity(0.75) : SGPayWallPalette.ink.opacity(0.72) }
    var selectedTintOpacity: Double { return self.isDark ? 0.16 : 0.10 }

    // Features
    var featureTileStroke: Color { return Color.white.opacity(self.isDark ? 0.18 : 0.35) }
    var featureSubtitle: Color { return self.isDark ? Color.white.opacity(0.62) : SGPayWallPalette.ink.opacity(0.62) }
    /// By day 50% ink (3.4:1 on the white card), still quieter than the subtitle.
    var chevron: Color { return self.isDark ? Color.white.opacity(0.45) : SGPayWallPalette.ink.opacity(0.5) }
    /// The feature-details page dots: the system draws them at night; by day the sheet draws them in ink.
    var pageDot: Color { return self.isDark ? Color.white : SGPayWallPalette.ink }

    // Back button
    var backGlyphInk: Color { return self.isDark ? Color.white : SGPayWallPalette.ink }
    var backGlyphFill: Color { return self.isDark ? Color.white.opacity(0.12) : Color.white.opacity(0.9) }
    var backGlyphStroke: Color { return self.isDark ? Color.white.opacity(0.12) : SGPayWallPalette.ink.opacity(0.10) }
}

// MARK: - Backdrop

/// The sky behind everything: near-black with a violet nebula and faint white stars at night, a
/// pale violet-white with a softer nebula and faint violet specks by day. The stars come from a
/// fixed seed, so the sky does not reshuffle on every redraw.
struct SGPayWallCosmicBackground: View {
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    private struct Star {
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let opacity: Double
    }

    private static let stars: [Star] = {
        var seed: UInt64 = 0x5A3E_9C21_77B1_0F4D
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 10_000) / 10_000.0
        }
        var result: [Star] = []
        for _ in 0 ..< 70 {
            let x = next()
            let y = next()
            let size = 0.8 + next() * 1.8
            let opacity = Double(0.25 + next() * 0.65)
            result.append(Star(x: x, y: y, size: size, opacity: opacity))
        }
        return result
    }()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                palette.backdrop

                RadialGradient(
                    gradient: Gradient(colors: palette.nebulaTop),
                    center: UnitPoint(x: 0.5, y: 0.08),
                    startRadius: 0,
                    endRadius: max(geometry.size.width, 1) * 0.95
                )

                RadialGradient(
                    gradient: Gradient(colors: [palette.nebulaSide, Color.clear]),
                    center: UnitPoint(x: 0.1, y: 0.3),
                    startRadius: 0,
                    endRadius: max(geometry.size.width, 1) * 0.7
                )

                ForEach(0 ..< SGPayWallCosmicBackground.stars.count, id: \.self) { index in
                    SGPayWallCosmicBackground.starView(SGPayWallCosmicBackground.stars[index], in: geometry.size, palette: palette)
                }
            }
        }
        .edgesIgnoringSafeArea(.all)
        .accessibility(hidden: true)
    }

    private var palette: SGPayWallPalette {
        return SGPayWallPalette(self.colorScheme)
    }

    /// One star, placed in the top 60% of the screen and fading toward the bottom of that band.
    private static func starView(_ star: Star, in size: CGSize, palette: SGPayWallPalette) -> some View {
        return Circle()
            .fill(palette.star)
            .frame(width: star.size, height: star.size)
            .opacity(star.opacity * Double(1.0 - star.y * 0.7) * palette.starOpacityScale)
            .position(x: star.x * size.width, y: star.y * size.height * 0.6)
    }
}

// MARK: - Hero

/// The Z mark in a glowing rounded square with a tilted orbit ring around it.
struct SGPayWallHeroMark: View {
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    var body: some View {
        ZStack {
            Ellipse()
                .stroke(
                    LinearGradient(
                        gradient: Gradient(colors: [sgPayWallCosmicBlue.opacity(0.0), sgPayWallCosmicViolet.opacity(0.9), sgPayWallCosmicBlue.opacity(0.0)]),
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1.5
                )
                .frame(width: 230, height: 62)
                .rotationEffect(.degrees(-14))
                .offset(y: 6)

            Image("pro")
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [sgPayWallCosmicViolet, sgPayWallCosmicBlue.opacity(0.6)]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                )
                .shadow(color: sgPayWallCosmicViolet.opacity(0.75 * SGPayWallPalette(self.colorScheme).glowScale), radius: 22, x: 0, y: 0)
                .shadow(color: sgPayWallCosmicBlue.opacity(0.45 * SGPayWallPalette(self.colorScheme).glowScale), radius: 40, x: 0, y: 6)
        }
        .frame(height: 124)
        .accessibility(hidden: true)
    }
}

/// "Zenlygram" in the text colour and "Pro" in the brand gradient, on one line.
struct SGPayWallHeroTitle: View {
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    private var font: Font {
        return Font.system(size: 38, weight: .heavy, design: .default)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("Zenlygram")
                .font(font)
                .foregroundColor(SGPayWallPalette(self.colorScheme).textPrimary)
            Text("Pro")
                .font(font)
                .foregroundColor(.clear)
                .overlay(
                    LinearGradient(
                        gradient: Gradient(colors: SGPayWallPalette(self.colorScheme).proGradient),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .mask(
                        Text("Pro")
                            .font(font)
                    )
                )
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .ignore)
        .accessibility(label: Text("Zenlygram Pro"))
        .accessibility(addTraits: .isHeader)
    }
}

/// The strip under the title: the product with its PREMIUM pill, the feature count, and "unlimited
/// freedom", separated by hairlines inside a glowing outlined card.
struct SGPayWallStatsStrip: View {
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    let premiumLabel: String
    let featureCountTitle: String
    let featureCountSubtitle: String
    let freedomTitle: String
    let freedomSubtitle: String
    /// A screen too narrow for one line (under 375 pt: the 320 pt iPhone SE, Display Zoom, Slide
    /// Over): the product goes on top and the two stats share the line under it. On one line each
    /// stat gets about 47 pt there, and every label in every language is cut.
    var isCompact: Bool = false

    var body: some View {
        Group {
            if isCompact {
                VStack(spacing: 12) {
                    product
                    HStack(spacing: 0) {
                        stat(symbol: "laurel.leading", title: featureCountTitle, subtitle: featureCountSubtitle)

                        stripDivider

                        stat(symbol: "bolt.fill", title: freedomTitle, subtitle: freedomSubtitle)
                    }
                }
            } else {
                HStack(spacing: 0) {
                    product
                        // The product's name and its pill are never truncated; the two stats share
                        // what is left.
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)

                    stripDivider

                    stat(symbol: "laurel.leading", title: featureCountTitle, subtitle: featureCountSubtitle)

                    stripDivider

                    stat(symbol: "bolt.fill", title: freedomTitle, subtitle: freedomSubtitle)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: sgPayWallCardRadius, style: .continuous)
                .fill(palette.stripFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: sgPayWallCardRadius, style: .continuous)
                .stroke(sgPayWallBrandGradient, lineWidth: 1.5)
        )
        .shadow(color: sgPayWallCosmicViolet.opacity(0.35 * palette.glowScale), radius: 14, x: 0, y: 0)
        .accessibilityElement(children: .combine)
    }

    private var palette: SGPayWallPalette {
        return SGPayWallPalette(self.colorScheme)
    }

    /// The Z tile, "Zenlygram Pro" and the PREMIUM pill.
    private var product: some View {
        HStack(spacing: 10) {
            Image("pro")
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(sgPayWallCosmicBlue.opacity(0.6), lineWidth: 1)
                )
                .accessibility(hidden: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Zenlygram Pro")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(palette.textPrimary)
                HStack(spacing: 4) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 9, weight: .bold))
                        .accessibility(hidden: true)
                    Text(premiumLabel)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                }
                .foregroundColor(palette.pillText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(palette.pillFill))
                .overlay(Capsule().stroke(palette.pillStroke, lineWidth: 1))
            }
        }
    }

    private var stripDivider: some View {
        Rectangle()
            .fill(palette.stripDivider)
            .frame(width: 1, height: 34)
            .padding(.horizontal, 4)
    }

    private func stat(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(palette.statSymbol)
                .accessibility(hidden: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(palette.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(palette.statSubtitle)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Glass cards

/// The translucent card the plans, the features and the account rows sit on.
struct SGPayWallGlassCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    func body(content: Content) -> some View {
        let palette = SGPayWallPalette(self.colorScheme)
        return content
            .background(
                RoundedRectangle(cornerRadius: sgPayWallCardRadius, style: .continuous)
                    .fill(palette.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: sgPayWallCardRadius, style: .continuous)
                    .stroke(palette.cardStroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: sgPayWallCardRadius, style: .continuous))
            // The day shadow, outside the clip. At night the shape is clear and casts nothing, so the
            // dark glass draws exactly as before.
            .background(
                RoundedRectangle(cornerRadius: sgPayWallCardRadius, style: .continuous)
                    .fill(palette.isDark ? Color.clear : palette.cardFill)
                    .shadow(color: palette.cardShadow, radius: 14, x: 0, y: 4)
            )
    }
}

extension View {
    func sgPayWallGlassCard() -> some View {
        return self.modifier(SGPayWallGlassCard())
    }
}

// MARK: - Plans

/// One plan as a row: a radio, the period with an optional badge pill and a summary line on the
/// leading side, the billed amount on the trailing side. The selected row is outlined in the brand
/// gradient.
///
/// The billed amount is the row's most prominent price (guideline 3.1.2) and never the part that
/// gives way: it is laid out first, the badge drops under the title where it would be cut beside it,
/// and at the accessibility text sizes (`stacksPrice`) the price moves under the title instead of
/// shrinking past legibility.
struct SGPayWallPlanRow: View {
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    let title: String
    let badge: String?
    let summary: String?
    let price: String
    let isSelected: Bool
    var stacksPrice: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                radio

                if stacksPrice {
                    VStack(alignment: .leading, spacing: 6) {
                        titleColumn
                        priceText
                    }
                    Spacer(minLength: 0)
                } else {
                    titleColumn

                    Spacer(minLength: 8)

                    priceText
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        isSelected
                            ? LinearGradient(gradient: Gradient(colors: [sgPayWallCosmicBlue.opacity(palette.selectedTintOpacity), sgPayWallCosmicViolet.opacity(palette.selectedTintOpacity)]), startPoint: .leading, endPoint: .trailing)
                            : LinearGradient(gradient: Gradient(colors: [Color.clear, Color.clear]), startPoint: .leading, endPoint: .trailing)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(sgPayWallBrandGradient, lineWidth: 1.5)
                    .opacity(isSelected ? 1.0 : 0.0)
            )
            .shadow(color: sgPayWallCosmicViolet.opacity(isSelected ? 0.35 * palette.glowScale : 0.0), radius: 10, x: 0, y: 0)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
        .accessibility(addTraits: isSelected ? .isSelected : [])
    }

    private var palette: SGPayWallPalette {
        return SGPayWallPalette(self.colorScheme)
    }

    private var radio: some View {
        ZStack {
            if isSelected {
                Circle()
                    .fill(sgPayWallCosmicBlue)
                    .frame(width: 26, height: 26)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Circle()
                    .stroke(palette.radioStroke, lineWidth: 1.5)
                    .frame(width: 26, height: 26)
            }
        }
        .accessibility(hidden: true)
    }

    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            titleAndBadge
            if let summary {
                Text(summary)
                    .font(.footnote)
                    .foregroundColor(palette.planSummary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The badge beside the title, as designed, wherever it fits there; under the title where it
    /// would be cut ("7 дней бесплатно", "Rejalashtirilgan" on most phones, any badge at 320 pt).
    /// Choosing needs `ViewThatFits` (iOS 16); before that the badge always goes under the title.
    @ViewBuilder
    private var titleAndBadge: some View {
        if let badge {
            if #available(iOS 16.0, *) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        titleText
                        badgePill(badge)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        titleText
                        badgePill(badge)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    titleText
                    badgePill(badge)
                }
            }
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(title)
            .font(sgPayWallTitle3(.semibold))
            .foregroundColor(palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Wraps rather than truncates when even its own line is too narrow, so the corners are a
    /// rounded rectangle that reads as a capsule on one line.
    private func badgePill(_ text: String) -> some View {
        Text(text)
            .font(Font.caption.weight(.bold))
            .foregroundColor(.white)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.badgeFill))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(palette.badgeStroke, lineWidth: 1))
    }

    private var priceText: some View {
        Text(price)
            .font(Font.headline.weight(isSelected ? .bold : .regular))
            .foregroundColor(isSelected ? palette.textPrimary : palette.priceUnselected)
            // A price is one token: shrink it rather than break it mid-number.
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

// MARK: - Features

extension SGProFeature {
    /// The tile's two-stop gradient, matching the feature's Settings colour family.
    var iconGradientColors: [Color] {
        switch self.id {
        case .vault:
            return [Color(hex: "8E6CFF"), Color(hex: "5A3BD6")]
        case .chatLock:
            return [Color(hex: "4C9BFF"), Color(hex: "245BDB")]
        case .tasks:
            return [Color(hex: "3FD57A"), Color(hex: "1E9A4E")]
        case .editHistory:
            return [Color(hex: "F6A54A"), Color(hex: "C9671C")]
        }
    }
}

/// One Pro feature in the cosmic list: a glossy gradient tile, the name, the one-line value and a
/// chevron that opens its details page (iOS 14+).
struct SGPayWallCosmicFeatureRow: View {
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    /// Row padding + tile + spacing: where the hairline between two rows starts.
    static let dividerInset: CGFloat = 16 + 52 + 16

    let feature: SGProFeature
    let action: () -> Void

    private var palette: SGPayWallPalette {
        return SGPayWallPalette(self.colorScheme)
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: feature.iconName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: feature.iconGradientColors),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(palette.featureTileStroke, lineWidth: 1)
                    )
                    .shadow(color: (feature.iconGradientColors.first ?? .clear).opacity(0.45 * palette.glowScale), radius: 8, x: 0, y: 2)
                    .accessibility(hidden: true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(feature.title)
                        .font(Font.body.weight(.semibold))
                        .foregroundColor(palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(feature.subtitle)
                        .font(.footnote)
                        .foregroundColor(palette.featureSubtitle)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if #available(iOS 14.0, *) {
                    Image(systemName: "chevron.right")
                        .font(Font.footnote.weight(.semibold))
                        .foregroundColor(palette.chevron)
                        .accessibility(hidden: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct SGPayWallCosmicDivider: View {
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    var leadingInset: CGFloat = 16

    var body: some View {
        Rectangle()
            .fill(SGPayWallPalette(self.colorScheme).hairline)
            .frame(height: 1.0 / UIScreen.main.scale)
            .padding(.leading, leadingInset)
            .padding(.trailing, 16)
            .accessibility(hidden: true)
    }
}

// MARK: - Purchase button

/// The pill-shaped purchase button: the Z mark, the title and an arrow on the brand gradient, with
/// a soft glow. Dims when disabled, except while busy, when the spinner and title are what to read.
struct SGPayWallCosmicButtonLabel: View {
    @Environment(\.isEnabled) private var isEnabled: Bool
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    let title: String
    var isBusy: Bool = false
    var showsArrow: Bool = true
    /// The Z tile before the title; a screen may give its width to the title instead.
    var showsMark: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            if isBusy {
                SGPayWallSpinner()
                    .environment(\.colorScheme, .dark)
                    .accessibility(hidden: true)
            } else if showsMark {
                // `.original`: inside a default-styled Button an image is drawn as a template, and
                // in this white label the Z tile would become a flat white square.
                Image("pro")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibility(hidden: true)
            }
            Text(title)
                .font(sgPayWallTitle3(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
            if showsArrow && !isBusy {
                Image(systemName: "arrow.right")
                    .font(Font.headline.weight(.bold))
                    .accessibility(hidden: true)
            }
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, minHeight: 62)
        .padding(.horizontal, 18)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [Color(hex: "2F6BFF"), Color(hex: "6E5BFF"), Color(hex: "A35CFF")]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: sgPayWallCosmicViolet.opacity(0.55 * SGPayWallPalette(self.colorScheme).glowScale), radius: 16, x: 0, y: 4)
        // A disabled button fades to half at night, as drawn. By day a half-faded gradient melts into
        // the pale sky and takes its white title (the reason nothing can be bought) with it, so it
        // turns grey instead and stays readable.
        .saturation(!(isEnabled || isBusy) && !SGPayWallPalette(self.colorScheme).isDark ? 0.0 : 1.0)
        .opacity(isEnabled || isBusy || !SGPayWallPalette(self.colorScheme).isDark ? 1.0 : 0.5)
        .contentShape(Capsule())
    }
}

// MARK: - Back button

/// The round back button in the top-leading corner.
struct SGPayWallBackGlyph: View {
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    var body: some View {
        let palette = SGPayWallPalette(self.colorScheme)
        return Image(systemName: "chevron.left")
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(palette.backGlyphInk)
            .frame(width: 44, height: 44)
            .background(Circle().fill(palette.backGlyphFill))
            .overlay(Circle().stroke(palette.backGlyphStroke, lineWidth: 1))
    }
}

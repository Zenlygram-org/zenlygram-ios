import Foundation
import SwiftUI
import UIKit
import SGCustomerSyncCore

// MARK: Zenlygram — the renderer of a consent text (design 40 §4.3): the blocks `SGConsentDocument` parsed from the
// CANONICAL text, so what is shown is exactly what `text_sha256` hashes. Headings carry the header trait; `**bold**`
// is bold; an https link is tappable and opens through `openURL` (the app: Safari via the application bindings,
// unaffected by the wall's deep-link guard). iOS 15 renders a paragraph as one `AttributedString` with inline
// links; iOS 13/14 concatenates `Text` runs and puts each link as a button under its paragraph.

/// The blocks of a consent text, top to bottom.
struct SGConsentTextView: View {
    let blocks: [SGConsentBlock]
    let openURL: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(self.blocks.enumerated()), id: \.offset) { item in
                SGConsentBlockView(block: item.element, openURL: self.openURL)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One heading, paragraph or bullet list.
struct SGConsentBlockView: View {
    let block: SGConsentBlock
    let openURL: (URL) -> Void

    var body: some View {
        switch self.block {
        case let .heading(level, runs):
            return AnyView(
                SGConsentRunsText(runs: runs, openURL: self.openURL)
                    .font(level == 1 ? .title : .headline)
                    .padding(.top, level == 1 ? 0 : 6)
                    .accessibility(addTraits: .isHeader)
            )
        case let .paragraph(runs):
            return AnyView(SGConsentRunsText(runs: runs, openURL: self.openURL))
        case let .list(items):
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: "•")
                                .accessibility(hidden: true)
                            SGConsentRunsText(runs: item.element, openURL: self.openURL)
                        }
                    }
                }
            )
        }
    }
}

/// A link of an iOS 13/14 paragraph, shown as a button under it.
private struct SGConsentLink {
    let text: String
    let url: URL
}

/// The runs of one block as text.
struct SGConsentRunsText: View {
    let runs: [SGConsentRun]
    let openURL: (URL) -> Void

    var body: some View {
        if #available(iOS 15.0, *) {
            return AnyView(
                Text(SGConsentRunsText.attributed(self.runs))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.openURL, OpenURLAction { [openURL = self.openURL] url in
                        openURL(url)
                        return .handled
                    })
            )
        }
        let links = self.runs.compactMap { run -> SGConsentLink? in
            return run.link.map { SGConsentLink(text: run.text, url: $0) }
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                SGConsentRunsText.concatenated(self.runs)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(links.enumerated()), id: \.offset) { item in
                    Button(action: {
                        self.openURL(item.element.url)
                    }) {
                        Text(verbatim: item.element.text)
                            .foregroundColor(.accentColor)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        )
    }

    /// iOS 15+: bold as strong emphasis, links as link attributes.
    @available(iOS 15.0, *)
    static func attributed(_ runs: [SGConsentRun]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            if run.isBold {
                part.inlinePresentationIntent = .stronglyEmphasized
            }
            if let link = run.link {
                part.link = link
            }
            result.append(part)
        }
        return result
    }

    /// iOS 13/14: one `Text` of every run (a link reads in the accent color; its button follows the paragraph).
    static func concatenated(_ runs: [SGConsentRun]) -> Text {
        var result = Text(verbatim: "")
        for run in runs {
            var part = Text(verbatim: run.text)
            if run.isBold {
                part = part.bold()
            }
            if run.link != nil {
                part = part.foregroundColor(.accentColor)
            }
            result = result + part
        }
        return result
    }
}

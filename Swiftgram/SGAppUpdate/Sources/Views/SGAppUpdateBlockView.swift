import Foundation
import SwiftUI
import UIKit
import SGStrings

// MARK: Zenlygram — the "Update required" screen (update_policy_spec §4f): the title, the text, the
// device note, the primary store button ("Open App Store", or "Open TestFlight" on a sandbox-receipt
// build, with the App Store as the fallback when TestFlight is not installed) and the Help link to
// zenlygram.org. Not a dead end: the store button and Help always work, and the note says why the
// store may not offer the update yet (a device below the release's iOS floor — 15.0, and it may
// rise — or the store's own delay).
//
// The copy sits in a scroll view; the buttons are a fixed bar under it, so Help is reachable without
// scrolling at any text size and on any device. Captions are in the app language (`lang`); the
// identifiers `zg.update.*` are stable. Pure (SwiftUI, UIKit, SGStrings), as the consent wall's views
// are: every effect leaves through `actions`.

final class SGAppUpdateBlockViewModel: ObservableObject {
    enum StoreButton: Equatable {
        case appStore
        case testFlight
    }

    struct Actions {
        var openStore: () -> Void = {}
        var openHelp: () -> Void = {}
    }

    /// The Help link's target (§4f).
    static let helpURL = URL(string: "https://zenlygram.org")!

    let lang: String
    let storeButton: StoreButton
    var actions = Actions()
    /// The root's safe insets (the hosting view ignores the safe area, as `SGSwiftUIView` content does).
    @Published var insets = EdgeInsets()

    init(lang: String, storeButton: StoreButton) {
        self.lang = lang
        self.storeButton = storeButton
    }

    /// `AppUpdate.Required.Button`, or `.TestFlightButton` on a TestFlight build.
    var storeButtonTitleKey: String {
        switch self.storeButton {
        case .appStore:
            return "AppUpdate.Required.Button"
        case .testFlight:
            return "AppUpdate.Required.TestFlightButton"
        }
    }
}

/// The whole screen: opaque, full screen.
struct SGAppUpdateBlockRoot: View {
    @ObservedObject var model: SGAppUpdateBlockViewModel

    /// The content column on iPad and in wide windows.
    static let maxWidth: CGFloat = 520

    private func caption(_ key: String) -> String {
        return key.i18n(self.model.lang)
    }

    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground)
                .edgesIgnoringSafeArea(.all)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(Font.system(size: 56))
                            .foregroundColor(.accentColor)
                            .padding(.top, 40)
                            .accessibility(hidden: true)
                        Text(verbatim: self.caption("AppUpdate.Required.Title"))
                            .font(.title)
                            .bold()
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibility(addTraits: .isHeader)
                            .accessibility(identifier: "zg.update.title")
                        Text(verbatim: self.caption("AppUpdate.Required.Text"))
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibility(identifier: "zg.update.text")
                        Text(verbatim: self.caption("AppUpdate.Required.DeviceNote"))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibility(identifier: "zg.update.devicenote")
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .frame(maxWidth: SGAppUpdateBlockRoot.maxWidth)
                    .frame(maxWidth: .infinity)
                }
                VStack(spacing: 4) {
                    Button(action: self.model.actions.openStore) {
                        Text(verbatim: self.caption(self.model.storeButtonTitleKey))
                    }
                    .buttonStyle(SGAppUpdateFilledButtonStyle())
                    .accessibility(identifier: "zg.update.store")
                    Button(action: self.model.actions.openHelp) {
                        Text(verbatim: self.caption("AppUpdate.Required.Help"))
                            .font(.footnote)
                            .foregroundColor(.accentColor)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibility(identifier: "zg.update.help")
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .frame(maxWidth: SGAppUpdateBlockRoot.maxWidth)
                .frame(maxWidth: .infinity)
            }
            .padding(self.model.insets)
        }
        .accessibilityElement(children: .contain)
        .accessibility(identifier: "zg.update.block")
    }
}

/// The filled primary button.
struct SGAppUpdateFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font.body.weight(.semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1.0))
            .cornerRadius(12)
            .contentShape(Rectangle())
    }
}

import Foundation
import SwiftUI
import UIKit
import SGCustomerSyncCore

// MARK: Zenlygram — "My data" (design 40 §11.3, ui-strings §6): what our server holds for this Telegram account, from
// `GET /v1/profile/me` — asked by the user, in every consent state (the data subject's own channel). Values are shown
// unmasked, kept in memory only, times in the device time zone. Not linked on this device → `MyData.NotLinked` and no
// call. Reached from Data & consent and from the wall's rights rows (`zg.mydata.*`).

final class SGMyDataViewModel: ObservableObject {
    enum Failure: Equatable {
        case offline
        case unavailable
        case rateLimited
        case failed
    }

    enum State: Equatable {
        case loading
        case notLinked
        case loaded(SGProfileMe)
        case failed(Failure)
    }

    @Published var state: State
    let lang: String
    let timeZone: TimeZone
    /// Fetches again (the app: `SGCustomerSync.fetchMyData`).
    var reload: () -> Void = {}
    var appeared: () -> Void = {}
    /// What the app keeps alive with this screen (observers, a request in flight).
    var lifetime: [AnyObject] = []

    init(lang: String, state: State = .loading, timeZone: TimeZone = .current) {
        self.lang = lang
        self.state = state
        self.timeZone = timeZone
    }

    func retry() {
        self.reload()
    }
}

struct SGMyDataView: View {
    @ObservedObject var model: SGMyDataViewModel
    /// Inside the wall: its own back control and title (the wall shows nothing of the app's navigation).
    var back: SGCustomerBack?

    var body: some View {
        let c = SGCustomerCaptions(self.model.lang)
        return SGCustomerPage(identifier: "zg.mydata") {
            if let back = self.back {
                SGCustomerBackButton(back: back)
                SGCustomerTitle(text: c("MyData.Title"))
            }
            SGMyDataContent(model: self.model)
        }
        .onAppear(perform: self.model.appeared)
    }
}

private struct SGMyDataContent: View {
    @ObservedObject var model: SGMyDataViewModel

    var body: some View {
        let c = SGCustomerCaptions(self.model.lang)
        switch self.model.state {
        case .loading:
            return AnyView(
                HStack(spacing: 10) {
                    SGCustomerSpinner()
                    Text(verbatim: c("MyData.Loading"))
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibility(identifier: "zg.mydata.loading")
            )
        case .notLinked:
            return AnyView(SGCustomerParagraph(text: c("MyData.NotLinked"), identifier: "zg.mydata.notlinked"))
        case let .failed(failure):
            let key: String
            switch failure {
            case .offline:
                key = "MyData.Error.Offline"
            case .unavailable:
                key = "MyData.Error.Unavailable"
            case .rateLimited:
                key = "MyData.Error.RateLimited"
            case .failed:
                key = "MyData.Unavailable"
            }
            return AnyView(
                VStack(alignment: .leading, spacing: 12) {
                    SGCustomerParagraph(text: c(key), identifier: "zg.mydata.error")
                    SGCustomerSection {
                        SGCustomerRowButton(title: c("MyData.Retry"), identifier: "zg.mydata.retry", role: .link, action: self.model.retry)
                    }
                }
            )
        case let .loaded(me):
            return AnyView(SGMyDataSections(me: me, c: c, timeZone: self.model.timeZone))
        }
    }
}

/// Every section of a loaded answer; a section the server left out is not shown.
private struct SGMyDataSections: View {
    let me: SGProfileMe
    let c: SGCustomerCaptions
    let timeZone: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let account = self.me.account {
                SGCustomerSection(header: self.c("MyData.Section.Account")) {
                    SGCustomerValueRow(title: self.c("MyData.Field.Id"), value: account.id ?? "—")
                    SGCustomerRowDivider()
                    SGCustomerValueRow(title: self.c("MyData.Field.TelegramId"), value: account.tgUserId.map { "\($0)" } ?? "—", valueIdentifier: "zg.mydata.tgid")
                    SGCustomerRowDivider()
                    SGCustomerValueRow(title: self.c("MyData.Field.Created"), value: self.time(account.createdAt) ?? "—")
                }
            }
            SGCustomerSection(header: self.c("MyData.Section.Consent")) {
                SGCustomerValueRow(title: self.consentState(self.me.consent?.state), value: self.time(self.me.consent?.effectiveAt) ?? "", detail: self.consentDetail(self.me.consent), titleIdentifier: "zg.mydata.consent")
            }
            if !self.history.isEmpty {
                SGCustomerSection(header: self.c("MyData.Section.History")) {
                    ForEach(Array(self.history.enumerated()), id: \.offset) { item in
                        if item.offset > 0 {
                            SGCustomerRowDivider()
                        }
                        SGCustomerValueRow(title: self.action(item.element.action), value: self.time(item.element.recordedAt) ?? "—", detail: self.historyDetail(item.element))
                    }
                }
            }
            if let profile = self.me.profile {
                SGMyDataProfileSection(profile: profile, c: self.c, timeZone: self.timeZone)
            }
            if !self.me.devices.isEmpty {
                SGMyDataDevicesSection(devices: self.me.devices, c: self.c, timeZone: self.timeZone)
            }
            if let activity = self.me.activity {
                SGCustomerSection(header: self.c("MyData.Section.Activity")) {
                    SGCustomerValueRow(title: self.c("MyData.Field.FirstActive"), value: self.time(activity.firstActiveAt) ?? "—")
                    SGCustomerRowDivider()
                    SGCustomerValueRow(title: self.c("MyData.Field.LastActive"), value: self.time(activity.lastActiveAt) ?? "—")
                    SGCustomerRowDivider()
                    SGCustomerValueRow(title: self.c("MyData.Field.ActiveDays"), value: activity.activeDays.map { "\($0)" } ?? "—")
                    SGCustomerRowDivider()
                    SGCustomerValueRow(title: self.c("MyData.Field.Sessions30"), value: activity.sessions30d.map { "\($0)" } ?? "—")
                    SGCustomerRowDivider()
                    SGCustomerValueRow(title: self.c("MyData.Field.Seconds30"), value: activity.sessionSeconds30d.map { SGCustomerSyncFormat.duration(seconds: $0, lang: self.c.lang) } ?? "—")
                }
            }
            if let events = self.me.events {
                SGMyDataEventsSection(events: events, c: self.c, timeZone: self.timeZone)
            }
            if let subscription = self.me.subscription {
                SGCustomerSection(header: self.c("MyData.Section.Subscription")) {
                    SGCustomerValueRow(title: subscription.status ?? subscription.reason ?? "—", value: self.time(subscription.until) ?? "—", detail: subscription.source)
                }
            }
            if let retention = self.me.retention {
                SGMyDataRetentionSection(retention: retention, c: self.c)
            }
        }
    }

    /// Newest first, at most 50 (design 40 §11.3).
    private var history: [SGProfileMe.ConsentHistoryItem] {
        let sorted = self.me.consentHistory.sorted { lhs, rhs in
            (SGCustomerSyncFormat.serverDate(lhs.recordedAt) ?? .distantPast) > (SGCustomerSyncFormat.serverDate(rhs.recordedAt) ?? .distantPast)
        }
        return Array(sorted.prefix(50))
    }

    private func time(_ text: String?) -> String? {
        return SGCustomerSyncFormat.serverTime(text, lang: self.c.lang, timeZone: self.timeZone)
    }

    /// The server's state as the Settings row names it.
    private func consentState(_ state: String?) -> String {
        switch state {
        case "granted"?:
            return self.c("Settings.Data.State.Granted")
        case "withdrawn"?:
            return self.c("Settings.Data.State.Withdrawn")
        case "none"?, nil:
            return self.c("Settings.Data.State.None")
        case let other?:
            return other
        }
    }

    private func consentDetail(_ consent: SGProfileMe.Consent?) -> String? {
        guard let consent = consent else {
            return nil
        }
        let parts = [consent.textVersion.map { "v\($0)" }, consent.locale, consent.consentMode].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func action(_ action: String?) -> String {
        switch action {
        case "grant"?:
            return self.c("Settings.Data.State.Granted")
        case "withdraw"?:
            return self.c("Settings.Data.State.Withdrawn")
        default:
            return action ?? "—"
        }
    }

    private func historyDetail(_ item: SGProfileMe.ConsentHistoryItem) -> String? {
        let parts = [item.textVersion.map { "v\($0)" }, item.locale, item.platform, item.appVersion, item.outcome].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Where a profile value came from (ui-strings §6).
private func sgMyDataSource(_ source: String?, observedAt: String?, c: SGCustomerCaptions, timeZone: TimeZone) -> String? {
    var parts: [String] = []
    if let source = source {
        switch source {
        case "telegram_attest", "telegram_bot", "client", "telegram_session":
            parts.append(c("MyData.Source.\(source)"))
        default:
            parts.append(source)
        }
    }
    if let time = SGCustomerSyncFormat.serverTime(observedAt, lang: c.lang, timeZone: timeZone) {
        parts.append(time)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

private struct SGMyDataProfileSection: View {
    let profile: SGProfileMe.Profile
    let c: SGCustomerCaptions
    let timeZone: TimeZone

    private struct Row {
        let title: String
        let value: String
        let detail: String?
    }

    var body: some View {
        let rows = self.rows
        return SGCustomerSection(header: self.c("MyData.Section.Profile")) {
            ForEach(Array(rows.enumerated()), id: \.offset) { item in
                if item.offset > 0 {
                    SGCustomerRowDivider()
                }
                SGCustomerValueRow(title: item.element.title, value: item.element.value, detail: item.element.detail)
            }
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        func add<Value>(_ key: String, _ field: SGProfileMe.Field<Value>?, _ value: (Value) -> String) {
            guard let field = field else {
                return
            }
            rows.append(Row(title: self.c(key), value: value(field.value), detail: sgMyDataSource(field.source, observedAt: field.observedAt, c: self.c, timeZone: self.timeZone)))
        }
        add("MyData.Field.Phone", self.profile.phone) { $0 }
        if let country = self.profile.country {
            rows.append(Row(title: self.c("MyData.Field.Country"), value: country, detail: nil))
        }
        add("MyData.Field.Usernames", self.profile.usernames) { $0.map { "@" + $0 }.joined(separator: ", ") }
        add("MyData.Field.FirstName", self.profile.firstName) { $0 }
        add("MyData.Field.LastName", self.profile.lastName) { $0 }
        add("MyData.Field.Language", self.profile.languageCode) { $0 }
        add("MyData.Field.Premium", self.profile.isPremium) { $0 ? "✓" : "—" }
        return rows
    }
}

private struct SGMyDataDevicesSection: View {
    let devices: [SGProfileMe.Device]
    let c: SGCustomerCaptions
    let timeZone: TimeZone

    var body: some View {
        SGCustomerSection(header: self.c("MyData.Section.Devices")) {
            ForEach(Array(self.devices.enumerated()), id: \.offset) { item in
                if item.offset > 0 {
                    Divider()
                }
                SGMyDataDeviceRows(device: item.element, c: self.c, timeZone: self.timeZone)
            }
        }
    }
}

private struct SGMyDataDeviceRows: View {
    let device: SGProfileMe.Device
    let c: SGCustomerCaptions
    let timeZone: TimeZone

    var body: some View {
        let device = self.device
        let os = [device.platform, device.osVersion].compactMap { $0 }.joined(separator: " ")
        let app = [device.appVersion, device.appBuild.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        return VStack(alignment: .leading, spacing: 0) {
            SGCustomerValueRow(title: self.c("MyData.Field.Model"), value: [device.deviceModel, device.deviceClass].compactMap { $0 }.joined(separator: " · "))
            SGCustomerValueRow(title: self.c("MyData.Field.Os"), value: os.isEmpty ? "—" : os)
            SGCustomerValueRow(title: self.c("MyData.Field.App"), value: app.isEmpty ? "—" : app)
            SGCustomerValueRow(title: self.c("MyData.Field.Locale"), value: device.locale ?? "—")
            SGCustomerValueRow(title: self.c("MyData.Field.TimeZone"), value: device.timezone ?? "—")
            SGCustomerValueRow(title: self.c("MyData.Field.Distribution"), value: device.distribution ?? "—")
            SGCustomerValueRow(title: self.c("MyData.Field.FirstSeen"), value: SGCustomerSyncFormat.serverTime(device.firstSeenAt, lang: self.c.lang, timeZone: self.timeZone) ?? "—")
            SGCustomerValueRow(title: self.c("MyData.Field.LastSeen"), value: SGCustomerSyncFormat.serverTime(device.lastSeenAt, lang: self.c.lang, timeZone: self.timeZone) ?? "—")
        }
    }
}

private struct SGMyDataEventsSection: View {
    let events: SGProfileMe.Events
    let c: SGCustomerCaptions
    let timeZone: TimeZone

    var body: some View {
        SGCustomerSection(header: self.c("MyData.Section.Events")) {
            SGCustomerValueRow(title: self.c("MyData.Field.Total"), value: self.events.total.map { "\($0)" } ?? "—")
            if let days = self.events.retentionDays {
                SGCustomerRowDivider()
                SGCustomerValueRow(title: self.c("MyData.Field.Retained"), value: SGCustomerSyncFormat.span(days, .day, lang: self.c.lang))
            }
            ForEach(Array(self.events.byName.enumerated()), id: \.offset) { item in
                SGCustomerRowDivider()
                SGCustomerValueRow(title: item.element.name, value: "\(item.element.count)")
            }
            ForEach(Array(self.events.recent.enumerated()), id: \.offset) { item in
                SGCustomerRowDivider()
                SGCustomerValueRow(title: item.element.name, value: SGCustomerSyncFormat.serverTime(item.element.ts, lang: self.c.lang, timeZone: self.timeZone) ?? "—")
            }
        }
    }
}

private struct SGMyDataRetentionSection: View {
    let retention: SGProfileMe.Retention
    let c: SGCustomerCaptions

    var body: some View {
        SGCustomerSection(header: self.c("MyData.Section.Retention")) {
            SGCustomerValueRow(title: self.c("MyData.Section.Profile"), value: self.retention.profile ?? "—")
            SGCustomerRowDivider()
            SGCustomerValueRow(title: self.c("MyData.Section.Events"), value: self.retention.eventsDays.map { SGCustomerSyncFormat.span($0, .day, lang: self.c.lang) } ?? "—")
            SGCustomerRowDivider()
            SGCustomerValueRow(title: self.c("MyData.Section.Activity"), value: self.retention.activityMonths.map { SGCustomerSyncFormat.span($0, .month, lang: self.c.lang) } ?? "—")
            SGCustomerRowDivider()
            SGCustomerValueRow(title: self.c("MyData.Section.Consent"), value: self.retention.consentLogYearsAfterErasure.map { SGCustomerSyncFormat.span($0, .year, lang: self.c.lang) } ?? "—")
        }
    }
}

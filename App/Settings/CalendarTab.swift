import EarshotKit
import SwiftUI
import UserNotifications

/// The calendar, profiles, noticing calls and the consent line (spec 5, 7 and 7.4).
struct CalendarTab: View {
    @Bindable var model: AppModel
    @State private var calendar: CalendarAuthorization?
    @State private var notificationsAllowed = false

    var body: some View {
        Form {
            calendarSection
            Section("Profiles") {
                TextField("My company domains", text: $model.settings.myDomains, prompt: Text("acme.com, acme.co.uk"))
                Caption("Your own address's domain counts too. Personal domains such as gmail.com never do.")
                Picker("External meetings", selection: $model.settings.externalMode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Caption("Notes + Do is used only when a Do target is on; otherwise Notes.")
                Picker("Internal meetings", selection: $model.settings.internalMode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("Sales words in titles", text: $model.settings.salesKeywords, axis: .vertical)
                    .lineLimit(1...3)
                Toggle("Show a short brief when a meeting starts", isOn: $model.settings.briefEnabled)
            }
            .disabled(!model.settings.useCalendar)
            callsSection
            Section("Consent") {
                Toggle("Remind me to tell everyone I'm recording", isOn: $model.settings.consentReminder)
                TextField("Line to copy", text: $model.settings.consentLine, axis: .vertical).lineLimit(2...4)
                Caption("Copied as: \(ConsentPolicy.line(settings: model.settings))")
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    var calendarSection: some View {
        Section("Calendar") {
            Toggle("Use my calendar", isOn: $model.settings.useCalendar)
                .onChange(of: model.settings.useCalendar) { _, on in
                    if on, calendar == .notDetermined { Task { calendar = await model.requestCalendarAccess() } }
                }
            HStack {
                Text(calendar?.canRead == true ? "Calendar access is on" : "Calendar access is off")
                    .foregroundStyle(calendar?.canRead == true ? Color.secondary : Brand.orangeText)
                Spacer()
                if calendar == .notDetermined {
                    Button("Request access") { Task { calendar = await model.requestCalendarAccess() } }
                } else if calendar?.canRead == false {
                    Button("Open System Settings") { model.openPrivacy("Privacy_Calendars") }
                }
            }
            .controlSize(.small)
            Caption("Earshot reads the event happening now to name the meeting, see who is in it and write a brief. "
                + "It never changes your calendar.")
        }
    }

    var callsSection: some View {
        Section("Noticing calls") {
            Toggle("Notice when a call app uses the microphone", isOn: $model.settings.noticeCalls)
            Toggle("Start recording automatically", isOn: $model.settings.autoRecordCalls)
                .disabled(!model.settings.noticeCalls || !canAutoRecord)
            if !canAutoRecord {
                Caption("Allow notifications or show the panel during calls to start automatically.")
            }
            Toggle("Stop when the call ends", isOn: $model.settings.autoStopCalls)
                .disabled(!model.settings.noticeCalls)
            Caption("Earshot asks before recording unless you start automatically. That only applies to call apps "
                + "such as Zoom, or a browser during a calendar event with a video link.")
        }
    }

    var canAutoRecord: Bool {
        CallNoticePolicy.canTurnOnAutoRecord(notificationsAuthorized: notificationsAllowed,
                                             panelOn: model.settings.showLivePanel)
    }

    func refresh() async {
        calendar = await model.calendarAuthorization()
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsAllowed = status == .authorized || status == .provisional
    }
}

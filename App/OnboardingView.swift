import AVFoundation
import CoreGraphics
import EarshotKit
import SwiftUI
import UserNotifications

extension AppModel {
    /// v1's flag for a finished first onboarding.
    static let onboardedKey = "onboarded"
    /// Set once the one-time offer to move to Restricted is answered, or settled by a welcome sheet (spec 14.2).
    static let restrictedNoticeKey = "restrictedNoticeDismissed"

    /// Onboarding for a new user, "New in Earshot 0.3" once for an upgrading one (spec 15).
    func showWelcomeIfNeeded() {
        let onboarded = UserDefaults.standard.bool(forKey: Self.onboardedKey)
        switch WelcomeSheet.which(onboarded: onboarded, onboardedVersion: settings.onboardedVersion) {
        case .onboarding?: showOnboarding()
        case .whatsNew?: showWhatsNew()
        case nil: break
        }
    }

    func showOnboarding() { windows.show("onboarding", title: "Set up Earshot") { OnboardingView(model: self) } }

    /// A new user who finishes onboarding has seen everything "New in Earshot 0.3" would show.
    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)
        settings.onboardedVersion = max(settings.onboardedVersion, WelcomeSheet.currentVersion)
        settleRestrictedNotice(after: .onboarding)
        windows.close("onboarding")
    }

    /// The Restricted offer is for modes saved before v0.2 only: once a welcome sheet is done without one, choosing
    /// Auto later by hand never brings it up.
    func settleRestrictedNotice(after sheet: WelcomeSheet) {
        guard PermissionNotice.answeredByWelcome(sheet, permissionMode: settings.permissionMode) else { return }
        UserDefaults.standard.set(true, forKey: Self.restrictedNoticeKey)
    }
}

struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var callAudio: Bool?
    @State private var testing = false
    @State private var speech = "Not checked yet"
    @State private var notifications = UNAuthorizationStatus.notDetermined

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up Earshot").font(.title2.bold())
            ClaudeSetupRow(model: model)
            Divider()
            micRow
            callAudioRow
            speechRow
            notificationsRow
            Divider()
            Text("Optional").font(.headline)
            OptInRows(model: model)
            HStack {
                Spacer()
                Button("Done") { model.finishOnboarding() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { notifications = await AppModel.notificationStatus() }
        // Back from System Settings: show what changed there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { notifications = await AppModel.notificationStatus() }
        }
    }

    /// Already allowed on an earlier run: ticked. Denied before: macOS won't ask again, so it opens System Settings.
    var notificationsRow: some View {
        let ok = notifications == .authorized || notifications == .provisional
        let denied = notifications == .denied
        return SetupRow(title: "Notifications", ok: ok,
                        detail: denied ? PermissionText.deniedBefore
                            : "Tells you when notes are ready and when a call starts.") {
            if denied {
                Button(PermissionText.openSettings) { model.openNotificationSettings() }
            } else if !ok {
                Button("Allow") {
                    Task {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                        notifications = await AppModel.notificationStatus()
                    }
                }
            }
        }
    }

    var micRow: some View {
        SetupRow(title: "Microphone", ok: mic == .authorized,
                 detail: mic == .denied ? "Denied. Allow Earshot under Privacy & Security, Microphone." : "Records your side.") {
            if mic == .notDetermined {
                Button("Allow") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                        mic = AVCaptureDevice.authorizationStatus(for: .audio)
                        model.refresh()
                    }
                }
            } else if mic != .authorized {
                Button("Open Settings") { model.openPrivacy("Privacy_Microphone") }
            }
        }
    }

    var callAudioRow: some View {
        SetupRow(title: "Call audio", ok: callAudio == true,
                 detail: callAudio == false
                     ? "Earshot heard nothing. Check your Mac isn't muted, allow Earshot under Privacy & Security, "
                         + "Screen & System Audio Recording, then test again."
                     : "Records the other people on the call. Test plays a short sound.") {
            Button(testing ? "Testing…" : "Test") {
                testing = true
                Task {
                    callAudio = await SystemAudioCheck.run()
                    testing = false
                }
            }
            .disabled(testing)
            if callAudio == false { Button("Open Settings") { model.openPrivacy("Privacy_AudioCapture") } }
        }
    }

    var speechRow: some View {
        SetupRow(title: "Speech model", ok: speech == "Ready", detail: speech) {
            Button("Check") {
                Task {
                    speech = "Checking…"
                    do {
                        try await AppleSpeechTranscriber.prepare(locale: Locale(identifier: model.settings.localeIdentifier))
                        speech = "Ready"
                    } catch {
                        speech = error.localizedDescription
                    }
                }
            }
        }
    }
}

/// One checklist row: a tick, a title, a line of detail and the buttons that fix it.
struct SetupRow<Actions: View>: View {
    let title: String
    let ok: Bool
    let detail: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? Color.green : Color.secondary)
                .accessibilityLabel(ok ? "Done" : "Not done")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actions()
        }
    }
}

/// Claude: the status, and the choice between the subscription, an API key and a local model (spec 3.1 and 22). On a
/// Pro plan it suggests Sonnet for notes and leaves the live assistant off.
struct ClaudeSetupRow: View {
    @Bindable var model: AppModel
    var checker = ClaudeStatusChecker.shared
    var local = LocalModelChecker.shared

    var body: some View {
        switch model.settings.provider {
        case .local: localRow
        case .claudeAPI: apiKeyRow
        case .claudeCode: claudeCodeRows
        }
    }

    /// The local model server: ready when it lists the chosen model. Settings has the address and the model.
    var localRow: some View {
        SetupRow(title: "Local model", ok: local.isReady, detail: localLine) {
            Button("Check") { Task { await local.check(model) } }.disabled(local.checking)
            SettingsTabButton("Set up", tab: .claude, model: model)
        }
        .task {
            // Again unless the last check found this address and model ready, so an old "Can't reach" never stays.
            if LocalModelSetup.checksOnAppear(last: local.status, address: model.settings.localURL,
                                              model: model.settings.localModel) {
                await local.check(model)
            }
        }
    }

    var apiKeyRow: some View {
        let keyProblem = model.settings.notesSetupProblem(secrets: model.keychain)
        return SetupRow(title: "Claude", ok: keyProblem == nil, detail: keyProblem ?? "Uses your Anthropic API key.") {
            Button("Use my Claude subscription") {
                model.settings.provider = .claudeCode
                Task { await checker.check(model) }
            }
            SettingsTabButton("Add key", tab: .claude, model: model)
            useLocalButton
        }
    }

    @ViewBuilder var claudeCodeRows: some View {
        SetupRow(title: "Claude", ok: checker.isReady, detail: statusLine) {
            Button("Check") { Task { await checker.check(model) } }.disabled(checker.checking)
            Button("Use an API key") { model.settings.provider = .claudeAPI }
            useLocalButton
        }
        .task { if checker.status == nil { await checker.check(model) } }
        if needsInstall {
            // Not found or too old: point at an installed claude, or install it (same as Settings > Claude).
            HStack {
                Button("Choose claude…") { Task { await checker.choose(model) } }
                Link("Install Claude Code", destination: ClaudeStatusChecker.installURL)
                Spacer()
            }
            .controlSize(.small)
            .padding(.leading, 24)
        }
        if ClaudeAdvice.isProPlan(checker.status) {
            HStack {
                Caption(ClaudeAdvice.proHint)
                Spacer()
                Button("Use Sonnet for notes") {
                    model.settings.model = "claude-sonnet-5-5"
                    model.settings.claudeCodeModel = ""
                }
                .disabled(model.settings.model(for: .notes) == "claude-sonnet-5-5")
                .controlSize(.small)
            }
            .padding(.leading, 24)
        }
    }

    var useLocalButton: some View {
        Button("Use a local model") {
            model.settings.provider = .local
            Task { await local.check(model) }
        }
    }

    var localLine: String {
        if let status = local.status { return status.summary }
        return local.checking ? "Checking the local model server…"
            : "Notes are written by a model on your own server, such as Ollama or LM Studio."
    }

    /// Claude Code wasn't found, or is older than Earshot needs.
    var needsInstall: Bool {
        switch checker.status?.state {
        case .notFound?, .tooOld?: true
        default: false
        }
    }

    var statusLine: String {
        if let status = checker.status { return status.summary + "." }
        return checker.checking ? "Checking Claude Code…" : "Earshot uses your own Claude Code and your Claude plan."
    }
}

/// The four features that stay off until the user turns them on (spec 2), shared with "New in Earshot 0.3".
struct OptInRows: View {
    @Bindable var model: AppModel
    @State private var calendar: CalendarAuthorization?
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()
    @State private var screenAsked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            optIn("Calendar", "Names the meeting, knows who is in it and shows a short brief.",
                  isOn: $model.settings.useCalendar) { on in
                if on, calendar != .fullAccess { Task { calendar = await model.requestCalendarAccess() } }
            }
            // Asking again shows no prompt once the user said no, so the row points at System Settings. Only while
            // the switch is on: a user who doesn't want the calendar isn't sent there.
            if model.settings.useCalendar, calendar?.deniedBefore == true {
                DeniedBeforeRow { model.openPrivacy("Privacy_Calendars") }.padding(.leading, 44)
            } else if model.settings.useCalendar, calendar == .restricted {
                DeniedBeforeRow(text: PermissionText.calendarBlocked, open: nil).padding(.leading, 44)
            }
            optIn("Live assistant", "Finds to-dos during the call and lets you start them with one click.",
                  isOn: $model.settings.liveAssistant) { _ in }
            optIn("Notice calls", "Offers to record when Zoom, Teams, Meet or another call app uses the microphone.",
                  isOn: $model.settings.noticeCalls) { _ in }
            optIn("Screen reading", "Reads text shared on screen during calls, on this Mac. Needs Screen Recording.",
                  isOn: $model.settings.readScreen) { on in
                // The first ask shows the system prompt; an ask after that shows nothing, so the row appears.
                let askedBefore = model.screenAccessAsked
                if on, !CGPreflightScreenCaptureAccess() { model.requestScreenAccess() }
                if askedBefore { refreshScreen() }
            }
            if model.settings.readScreen, !screenAllowed, screenAsked {
                DeniedBeforeRow(text: PermissionText.screenOff) { model.openPrivacy("Privacy_ScreenCapture") }
                    .padding(.leading, 44)
            }
        }
        .task {
            calendar = await model.calendarAuthorization()
            refreshScreen()
        }
        // Back from System Settings: show what changed there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { calendar = await model.calendarAuthorization() }
            refreshScreen()
        }
    }

    /// Screen Recording can't be read as "denied": a past ask that still finds no access counts as denied before.
    func refreshScreen() {
        screenAllowed = CGPreflightScreenCaptureAccess()
        screenAsked = model.screenAccessAsked
    }

    func optIn(_ title: String, _ detail: String, isOn: Binding<Bool>,
               changed: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Caption(detail)
            }
        }
        .toggleStyle(.switch)
        .onChange(of: isOn.wrappedValue) { _, on in changed(on) }
    }
}

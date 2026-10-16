import CoreGraphics
import EarshotKit
import SwiftUI

/// The live assistant, the panel, flags, Start and screen reading (spec 4, 8 and 9).
struct LiveTab: View {
    @Bindable var model: AppModel
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()

    static let targets: [(id: String, label: String)] = [
        ("", "The first Do target that is on"), ("claude-code", "Claude Code"), ("webhook", "Webhook"),
        ("command", "Command"), ("routine", "Claude Code routine"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Find to-dos during the call", isOn: $model.settings.liveAssistant)
                Picker("Check every", selection: $model.settings.liveInterval) {
                    ForEach(ClaudeAdvice.liveIntervals, id: \.self) { Text("\($0) seconds").tag($0) }
                }
                if model.settings.provider == .local {
                    Caption(LocalModelSetup.liveCaption)
                    Caption(LocalModelSetup.liveIntervalHint)
                } else {
                    ModelField(title: "Live model", text: $model.settings.liveModel, prompt: "claude-sonnet-5-5")
                }
                Caption("\(ClaudeAdvice.callsLine(interval: model.settings.liveInterval)) of talk. "
                    + "Works in Notes and Notes + Do.")
            } header: {
                Text("Live assistant")
            }
            Section("Panel") {
                Toggle("Show the panel during calls", isOn: $model.settings.showLivePanel)
                Toggle("Try to hide the panel when I share my screen", isOn: $model.settings.hidePanelFromCapture)
                Caption("Some call apps may still show it. The Sharing button (⌃⌥⌘H) shrinks it to a small pill "
                    + "that shows only the recording dot and timer.")
                if model.settings.showLivePanel, let problem = model.liveController.sharingHotkeyProblem {
                    Caption(problem, color: Brand.redText)
                }
            }
            Section("Flags") {
                Toggle("Flag a moment with ⌃⌥⌘F", isOn: $model.settings.flagHotkey)
                if model.settings.flagHotkey, let problem = model.liveController.flagHotkeyProblem {
                    Caption(problem, color: Brand.redText)
                }
                Toggle("Flag by saying \"flag that\"", isOn: $model.settings.voiceFlags)
                    .disabled(!model.settings.liveAssistant)
                Caption("Saying it needs the live assistant. The notes cover every flagged moment.")
            }
            startSection
            screenSection
        }
        .formStyle(.grouped)
        .onAppear { screenAllowed = CGPreflightScreenCaptureAccess() }
    }

    /// Spec 4.4 as adopted: a chosen target that is off gives way to the first working one, and a note says which.
    var startSection: some View {
        Section("Start") {
            Picker("Start sends to", selection: $model.settings.liveTarget) {
                ForEach(Self.targets, id: \.id) { Text($0.label).tag($0.id) }
            }
            Toggle("Allow Start during calls for routines", isOn: $model.settings.allowRoutineLiveStart)
            let choice = LiveTargetChoice.make(settings: model.settings,
                                               targets: model.settings.targets(secrets: model.keychain))
            if let note = choice.settingsNote { Caption(note, color: Brand.orangeText) }
            Caption(Self.startLine(choice.decision))
        }
    }

    /// How Start behaves with the live target.
    static func startLine(_ decision: LiveStartPolicy.Decision) -> String {
        switch decision {
        case .oneClick: return "Start sends in one click, with 3 seconds to cancel. Only in Notes + Do."
        case .confirmSheet: return "Start shows exactly what will be sent, and a second click sends it."
        case let .unavailable(reason): return reason
        }
    }

    var screenSection: some View {
        Section("Screen") {
            Toggle("Read my screen during calls", isOn: $model.settings.readScreen)
                .onChange(of: model.settings.readScreen) { _, on in
                    if on, !CGPreflightScreenCaptureAccess() { model.requestScreenAccess() }
                }
            Toggle("Read the whole display, not just the call app", isOn: $model.settings.screenWholeDisplay)
                .disabled(!model.settings.readScreen)
            Toggle("Keep screenshots (never sent)", isOn: $model.settings.keepScreenshots)
                .disabled(!model.settings.readScreen)
            HStack {
                Text(screenAllowed ? "Screen Recording is on" : "Screen Recording is off")
                    .foregroundStyle(screenAllowed ? Color.secondary : Brand.orangeText)
                Spacer()
                if !screenAllowed {
                    Button("Allow…") { model.requestScreenAccess() }
                    Button("Open System Settings") { model.openPrivacy("Privacy_ScreenCapture") }
                }
                Button("Check") { screenAllowed = CGPreflightScreenCaptureAccess() }
            }
            .controlSize(.small)
            Caption("Earshot reads text in the call app's windows on this Mac. Screenshots never leave it. macOS shows "
                + "a purple dot while it reads, asks you to confirm again every month, and Earshot must be reopened "
                + "after you allow it.")
        }
    }
}

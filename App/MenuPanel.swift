import EarshotKit
import SwiftUI

struct MenuPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // v2: the calendar event happening now (B3)
            if let now = model.context.nowLine { Text(now).font(.callout).lineLimit(1).help(now) }
            Picker("Mode", selection: $model.mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isRecording || model.isStarting)

            if model.isRecording {
                HStack {
                    Text(Self.clock(model.elapsed)).font(.system(.title2, design: .monospaced))
                    Spacer()
                    Button("Stop") { model.stopRecording() }.keyboardShortcut(.defaultAction)
                }
                LevelRow(label: "Me", level: model.levels.me)
                LevelRow(label: "Them", level: model.levels.them)
            } else {
                // v2: a blank title uses the event's (B3)
                TextField(model.context.titlePlaceholder ?? "Title (optional)", text: $model.title).disabled(model.isStarting)
                // An unstructured task: nothing cancels a start that is waiting on a permission prompt.
                Button { Task { await model.startRecording() } } label: {
                    Label(model.isStarting ? "Starting…" : "Record", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.micDenied || model.isStarting)
                if model.micDenied {
                    Button("Grant microphone access") { model.openPrivacy("Privacy_Microphone") }
                }
            }

            if let banner = model.banner {
                Text(banner).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.bannerNeedsSetup { SettingsTabButton("Set up notes", tab: .claude, model: model) }
            }
            CallPromptRow(model: model)  // v2: a call question when notifications are off, with the menu bar badge

            Divider()
            Text("Recent").font(.caption).foregroundStyle(.secondary)
            if model.sessions.isEmpty { Text("No meetings yet.").foregroundStyle(.secondary) }
            ForEach(model.sessions) { session in SessionRow(model: model, session: session) }

            Divider()
            HStack {
                Button("Import audio…") { model.importAudio() }
                Spacer()
                SettingsLink { Text("Settings…") }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            model.refresh()
            model.context.menuOpened()  // v2: read the calendar as the menu opens (B3)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}

struct LevelRow: View {
    let label: String
    let level: Float

    var body: some View {
        HStack {
            Text(label).font(.caption).frame(width: 36, alignment: .leading)
            ProgressView(value: Double(min(1, level * 4)))  // speech RMS rarely passes 0.25
                .accessibilityLabel(label == "Me" ? "My level" : "Their level")
        }
    }
}

struct SessionRow: View {
    let model: AppModel
    let session: Session

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title ?? session.folderName).lineLimit(1)
                Text(model.statusText(session))
                    .font(.caption)
                    .foregroundStyle(session.failedStage == nil ? Color.secondary : Brand.redText)
                    .lineLimit(2)
                // The latest thing the meeting should know about, such as "Sending was skipped."; all of them on hover.
                if let warning = session.warnings.last {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Brand.orangeText)
                        .lineLimit(2)
                        .help(session.warnings.joined(separator: "\n"))
                }
            }
            Spacer()
            if session.failedStage != nil { Button("Retry") { model.retry(session) }.controlSize(.small) }
            // v2: Ask and Fix, only for meetings with a transcript (spec 8).
            if AskRules.canAsk(session, hasTranscript: model.hasTranscript(session)) {
                Button("Ask…") { model.showAsk(session) }.controlSize(.small)
            } else if RecordingNotes.canWrite(
                session, busy: model.activity[session.id] != nil || model.writingNotes.contains(session.id)) {
                // v2: a Record meeting has no transcript to ask about; Write notes makes it a Notes meeting.
                Button(RecordingNotes.buttonLabel) { model.writeNotes(for: session) }.controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.open(session) }
    }
}

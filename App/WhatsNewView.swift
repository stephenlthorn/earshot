import EarshotKit
import SwiftUI

extension AppModel {
    /// Closing the window counts as seen too, so it opens on its own only once.
    func showWhatsNew() {
        windows.show("whatsnew", title: "New in Earshot", onClose: { [weak self] in self?.markWhatsNewSeen() }) {
            WhatsNewView(model: self)
        }
    }

    func finishWhatsNew() {
        markWhatsNewSeen()
        windows.close("whatsnew")
    }

    /// Seen: it won't open on its own again (spec 15).
    func markWhatsNewSeen() {
        guard settings.onboardedVersion < WelcomeSheet.currentVersion else { return }
        settings.onboardedVersion = WelcomeSheet.currentVersion
        settleRestrictedNotice(after: .whatsNew)
    }
}

/// "New in Earshot 0.3", shown once to users upgrading from 0.1 or 0.2 (spec 15): what's new, what 0.2 added (only for
/// a user coming from 0.1), the notes setup and the opt-in features.
struct WhatsNewView: View {
    @Bindable var model: AppModel
    @AppStorage(AppModel.restrictedNoticeKey) private var noticeDismissed = false

    static let points = [
        ("desktopcomputer", "Write notes with a local model through Ollama, LM Studio or llama.cpp. With a local "
            + "server, your transcripts and notes stay on your Mac."),
    ]

    static let pointsFrom02 = [
        ("sparkles", "Uses your Claude plan through Claude Code. No API key needed."),
        ("checklist", "Correct items before they go out. Earshot learns from your edits."),
        ("questionmark.bubble", "Ask a meeting a question, or tell Earshot what to fix in its notes."),
        ("doc.richtext", "Each meeting gets a page with a timeline, decisions and who owes what."),
        ("puzzlepiece.extension", "Claude Code and Claude Desktop can read your meetings. See Settings, AI apps."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New in Earshot 0.3").font(.title2.bold())
            ForEach(Self.points, id: \.1) { icon, text in
                Label(text, systemImage: icon).fixedSize(horizontal: false, vertical: true)
            }
            // Only for users coming from 0.1; the setting changes only when the sheet is marked seen.
            if WelcomeSheet.shows02Points(onboardedVersion: model.settings.onboardedVersion) {
                Text("Also new in 0.2").font(.headline)
                ForEach(Self.pointsFrom02, id: \.1) { icon, text in
                    Label(text, systemImage: icon).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            ClaudeSetupRow(model: model)
            if PermissionNotice.shouldOffer(permissionMode: model.settings.permissionMode, dismissed: noticeDismissed) {
                noticeRow
            }
            Divider()
            Text("Turn on what you want. Each one stays off until you do.").font(.headline)
            OptInRows(model: model)
            HStack {
                SettingsTabButton("Open Settings", tab: .claude, model: model)
                Spacer()
                Button("Done") { model.finishWhatsNew() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    var noticeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(PermissionNotice.text, systemImage: "lock.shield").fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Use Restricted") {
                    model.settings.permissionMode = ClaudeCodeTarget.restricted
                    noticeDismissed = true
                }
                Button("Keep my setting") { noticeDismissed = true }
            }
            .controlSize(.small)
        }
    }
}

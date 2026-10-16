import AppKit
import EarshotKit
import Observation
import SwiftUI

/// The Claude Code status line shared by Settings, onboarding and "New in v0.2" (spec 3.1). It runs only
/// `claude --version` and `claude auth status`, never a model.
@MainActor @Observable
final class ClaudeStatusChecker {
    static let shared = ClaudeStatusChecker()
    static let installURL = URL(string: "https://code.claude.com/docs/en/setup")!

    private(set) var status: ClaudeCodeStatus?
    private(set) var checking = false
    /// The `claude` the login shell found, kept once found. Not finding it isn't kept, so a `claude` installed later
    /// is found by the next Check.
    @ObservationIgnored private var shellPath: String?
    /// Asked for while a check was running, for example after "Choose claude…": the running check goes round again.
    @ObservationIgnored private var checkAgain = false

    /// Finds `claude` (the chosen path, the usual places, then the login shell) and checks it. A `claude` found only
    /// through the login shell is saved as the Claude Code path, so notes and Do use the same one. A call while a
    /// check runs makes that check run again when it ends, so the status always matches the saved path.
    func check(_ model: AppModel) async {
        guard !checking else {
            checkAgain = true
            return
        }
        checking = true
        defer { checking = false }
        repeat {
            checkAgain = false
            status = await checkOnce(model)
        } while checkAgain
    }

    private func checkOnce(_ model: AppModel) async -> ClaudeCodeStatus {
        var path = ClaudeLocator.find(override: model.settings.claudePath)
        if path == nil {
            if shellPath == nil { shellPath = await ClaudeLocator.findViaShell() }
            path = shellPath
            if let path, model.settings.claudePath.isEmpty { model.settings.claudePath = path }
        }
        return await ClaudeCodeStatus.check(path: path)
    }

    /// "Choose claude…": the user points at their `claude`, which is saved and checked.
    func choose(_ model: AppModel) async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the claude program"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.claudePath = url.path
        await check(model)
    }

    var isReady: Bool { status?.state == .ready }

    // v2: screenshots. A sample status, so the renderer never runs `claude`.
    func showSample(_ status: ClaudeCodeStatus) { self.status = status }
}

/// One line with the Claude Code status, an icon and the buttons that fix it.
struct ClaudeStatusRow: View {
    @Bindable var model: AppModel
    var checker = ClaudeStatusChecker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)  // the line says it
                Text(verbatim: line).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if checker.checking { ProgressView().controlSize(.small) }
            }
            HStack {
                Button("Check") { Task { await checker.check(model) } }.disabled(checker.checking)
                Button("Choose claude…") { Task { await checker.choose(model) } }
                if checker.status?.state == .notFound { Link("Install", destination: ClaudeStatusChecker.installURL) }
            }
            .controlSize(.small)
        }
        .task { if checker.status == nil { await checker.check(model) } }
    }

    var line: String {
        if let status = checker.status { return status.summary }
        return checker.checking ? "Checking Claude Code…" : "Not checked yet"
    }

    var icon: String {
        guard let status = checker.status else { return "circle.dotted" }
        return status.state == .ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    var tint: Color {
        guard let status = checker.status else { return .secondary }
        return status.state == .ready ? .green : .orange
    }
}

import EarshotKit
import SwiftUI

/// Connecting Claude Code, Claude Desktop and the shell to Earshot's meetings (spec 11.4).
struct AIAppsTab: View {
    @Bindable var model: AppModel
    @State private var adding = false
    @State private var addResult: String?
    @State private var copied: String?

    // v2: screenshots pass a sample app path and helper check; the app uses these defaults.
    var setup = AIAppsSetup(appURL: Bundle.main.bundleURL)
    var helperExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }

    var body: some View {
        let problem = setup.problem(isExecutable: helperExists)
        Form {
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Brand.orangeText) }
            }
            Section("Claude Code") {
                HStack {
                    Button(adding ? "Adding…" : "Add to Claude Code") { Task { await add() } }
                        .disabled(adding || problem != nil)
                    if adding { ProgressView().controlSize(.small) }
                }
                if let addResult { Text(addResult).font(.caption.monospaced()).textSelection(.enabled) }
                Caption("Claude Code can then search your meetings, read notes and list who owes what, in every project.")
            }
            Section("Claude Desktop") {
                copyButton("Copy for Claude Desktop", setup.claudeDesktopJSON, disabled: problem != nil)
                Caption("In Claude Desktop, open Settings, Developer, Edit Config. Add the copied entry to "
                    + "claude_desktop_config.json, then quit and reopen Claude.")
            }
            Section("Command line") {
                Text(setup.installCommandLine).font(.caption.monospaced()).textSelection(.enabled)
                copyButton("Copy the install line", setup.installCommandLine, disabled: problem != nil)
                Caption("Paste it in Terminal. Then `earshot list`, `earshot search` and `earshot help` work there.",
                        markdown: true)
            }
            Section("Claude Code plugins") {
                Text(AIAppsSetup.pluginLines.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                copyButton("Copy plugin lines", AIAppsSetup.pluginLines.joined(separator: "\n"), disabled: problem != nil)
                Caption("Type these in Claude Code. The reminders plugin is optional: it adds your open items from the "
                    + "last week when a session starts.")
            }
            Section {
                Caption("Meeting text reaches these apps as quoted content, never as instructions. The apps read a copy "
                    + "in Application Support, so they don't need access to your Documents folder.")
            }
        }
        .formStyle(.grouped)
    }

    func copyButton(_ title: String, _ text: String, disabled: Bool) -> some View {
        Button(copied == title ? "Copied" : title) {
            model.copyToPasteboard(text)
            copied = title
        }
        .disabled(disabled)
    }

    func add() async {
        guard let claude = ClaudeLocator.find(override: model.settings.claudePath) else {
            addResult = NotesError.claudeNotFound.errorDescription
            return
        }
        adding = true
        defer { adding = false }
        addResult = await setup.addToClaudeCode(claudePath: claude)
    }
}

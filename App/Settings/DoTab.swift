import EarshotKit
import SwiftUI

/// Where confirmed action items go (spec 4.4, 12 and 14.2).
struct DoTab: View {
    @Bindable var model: AppModel
    /// The one-time offer to switch to Restricted, once answered.
    @AppStorage(AppModel.restrictedNoticeKey) private var noticeDismissed = false
    /// Bumped after a token is saved, so the setup problems are read again.
    @State private var tokenVersion = 0
    static let blankCommand = "Type the command to run. Until then nothing is run."

    var body: some View {
        Form {
            Section {
                Toggle("Ask before sending", isOn: Binding(get: { !model.settings.sendWithoutAsking },
                                                           set: { model.settings.sendWithoutAsking = !$0 }))
                Caption("Meetings with people outside your company, and recordings Earshot started on its own, "
                    + "always ask.")
            }
            if PermissionNotice.shouldOffer(permissionMode: model.settings.permissionMode, dismissed: noticeDismissed) {
                PermissionNoticeView(model: model, dismissed: $noticeDismissed)
            }
            claudeCodeSection
            RoutineSection(model: model, tokenVersion: $tokenVersion)
            Section("Webhook") {
                Toggle("POST to a webhook", isOn: $model.settings.webhookOn)
                TextField("URL", text: $model.settings.webhookURL, prompt: Text("https://…"))
                KeychainField(model: model, title: "Bearer token (optional)", item: .webhookToken,
                              saved: { tokenVersion += 1 })
                // Why the webhook can't run, for example a plain http URL to a public host.
                if model.settings.webhookOn, let problem = problem(for: "webhook") { Caption(problem, color: Brand.redText) }
            }
            Section("Command") {
                Toggle("Run a command", isOn: $model.settings.commandOn)
                TextField("Command", text: $model.settings.command, prompt: Text("Gets the meeting JSON on stdin"))
                // EarshotSettings leaves a blank command out of the targets, so say it here.
                if model.settings.commandOn, model.settings.command.trimmingCharacters(in: .whitespaces).isEmpty {
                    Caption(Self.blankCommand, color: Brand.redText)
                }
            }
        }
        .formStyle(.grouped)
    }

    var claudeCodeSection: some View {
        Section("Claude Code") {
            Toggle("Hand action items to Claude Code", isOn: $model.settings.claudeCodeTargetOn)
            HStack {
                TextField("Work folder", text: $model.settings.claudeCodeFolder)
                Button("Choose…") { model.chooseFolder { model.settings.claudeCodeFolder = $0 } }
            }
            if model.settings.claudeCodeTargetOn, let problem = problem(for: "claude-code") {
                Caption(problem, color: Brand.redText)
            }
            Picker("Permissions", selection: $model.settings.permissionMode) {
                Text("Restricted (recommended): files in the work folder only").tag(ClaudeCodeTarget.restricted)
                Text("Edit files").tag("acceptEdits")
                Text("Auto").tag("auto")
                Text("Everything, no prompts").tag("bypassPermissions")
            }
            switch model.settings.permissionMode {
            case ClaudeCodeTarget.restricted:
                Caption("Claude Code can read and write files in the work folder and nothing else. It can't run commands.")
            case "bypassPermissions":
                Caption("Claude Code will run any command without asking, anywhere your account can reach. Choosing a "
                    + "folder doesn't limit it.", color: Brand.redText)
            default:
                Caption("Claude Code runs with your own setup: hooks, plugins, MCP servers and CLAUDE.md.")
            }
        }
    }

    func problem(for id: String) -> String? {
        _ = tokenVersion
        return model.settings.unavailableTargets(secrets: model.keychain).first { $0.id == id }?.reason
    }
}

/// The one-time offer to move to Restricted (spec 14.2).
struct PermissionNoticeView: View {
    @Bindable var model: AppModel
    @Binding var dismissed: Bool

    var body: some View {
        Section {
            Label(PermissionNotice.text, systemImage: "lock.shield")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Use Restricted") {
                    model.settings.permissionMode = ClaudeCodeTarget.restricted
                    dismissed = true
                }
                .buttonStyle(.borderedProminent)
                Button("Keep my setting") { dismissed = true }
            }
        }
    }
}

/// The Claude Code routine target (spec 12).
struct RoutineSection: View {
    @Bindable var model: AppModel
    @Binding var tokenVersion: Int
    @State private var copied = false

    static let routinesURL = URL(string: "https://claude.ai/code/routines")!
    static let tokenWarning = "This is the routine's API trigger token from claude.ai/code/routines, not the token "
        + "from `claude setup-token`."
    static let clickPath = "In claude.ai/code/routines, open the routine, then Add trigger, API, Generate token. "
        + "Paste its URL and token here."
    static let advice = "Give the routine only the connectors it needs, ideally read-only or able to make drafts. "
        + "Set network access to None or Trusted. Protect important branches. A routine needs at least one repository."
    static let limits = "Limits: 30 runs an hour per routine and 100 per account. Pro and Max plans may also have "
        + "daily run limits."

    var body: some View {
        Section("Claude Code routine") {
            Toggle("Start a routine in the cloud", isOn: $model.settings.routineOn)
            TextField("Routine URL", text: $model.settings.routineURL,
                      prompt: Text("https://api.anthropic.com/v1/claude_code/routines/trig_…/fire"))
            KeychainField(model: model, title: "Routine token", item: .routineToken, saved: { tokenVersion += 1 })
            Caption(Self.tokenWarning, markdown: true)
            if model.settings.routineOn, let problem = problem {
                Caption(problem, color: Brand.redText)
            }
            Caption(Self.clickPath)
            HStack {
                Button(copied ? "Copied" : "Copy suggested routine prompt") {
                    model.copyToPasteboard(RoutineTarget.suggestedPrompt)
                    copied = true
                }
                Link("Open claude.ai/code/routines", destination: Self.routinesURL)
            }
            .controlSize(.small)
            Caption(Self.advice)
            Caption(Self.limits)
        }
    }

    var problem: String? {
        _ = tokenVersion
        return model.settings.unavailableTargets(secrets: model.keychain).first { $0.id == "routine" }?.reason
    }
}

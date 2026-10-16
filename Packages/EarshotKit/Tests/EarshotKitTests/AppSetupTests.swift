import Foundation
import Testing
@testable import EarshotKit

/// The decisions behind Settings, onboarding, the meeting rows and Ask (spec 3.1, 3.3, 8, 10, 11.4, 14.2, 15).
struct AppSetupTests {}

extension AppSetupTests {
    struct AIApps {
        let app = AIAppsSetup(appURL: URL(fileURLWithPath: "/Applications/Earshot.app"))

        @Test func theHelperIsInsideTheApp() {
            #expect(app.helperPath == "/Applications/Earshot.app/Contents/Helpers/earshot")
        }

        @Test func addToClaudeCodeRunsMcpAddAtUserScope() {
            #expect(app.mcpAddArguments == ["mcp", "add", "--scope", "user", "earshot", "--",
                                            "/Applications/Earshot.app/Contents/Helpers/earshot", "mcp"])
        }

        @Test func aTranslocatedAppIsRefusedWithTheSpecLine() {
            let moved = AIAppsSetup(appURL: URL(fileURLWithPath:
                "/private/var/folders/ab/T/AppTranslocation/1234-ABCD/d/Earshot.app"))
            #expect(moved.isTranslocated)
            #expect(!app.isTranslocated)
            #expect(moved.problem(isExecutable: { _ in true }) == "Move Earshot to Applications first")
            #expect(app.problem(isExecutable: { _ in true }) == nil)
        }

        @Test func aMissingHelperIsAProblem() {
            #expect(app.problem(isExecutable: { _ in false }) == AIAppsSetup.helperMissing)
        }

        @Test func claudeDesktopGetsAnMcpServersEntry() throws {
            let object = try JSONSerialization.jsonObject(with: Data(app.claudeDesktopJSON.utf8)) as? [String: Any]
            let servers = object?["mcpServers"] as? [String: Any]
            let earshot = servers?["earshot"] as? [String: Any]
            #expect(earshot?["command"] as? String == "/Applications/Earshot.app/Contents/Helpers/earshot")
            #expect(earshot?["args"] as? [String] == ["mcp"])
        }

        @Test func theCommandLineToolLineLinksIntoLocalBin() {
            #expect(app.installCommandLine
                == "mkdir -p ~/.local/bin && ln -sf '/Applications/Earshot.app/Contents/Helpers/earshot' ~/.local/bin/earshot")
        }

        @Test func aPathWithAQuoteIsQuotedForTheShell() {
            let odd = AIAppsSetup(appURL: URL(fileURLWithPath: "/Users/x/Bob's Apps/Earshot.app"))
            #expect(odd.installCommandLine.contains(#"'/Users/x/Bob'\''s Apps/Earshot.app/Contents/Helpers/earshot'"#))
        }

        @Test func pluginLinesInstallBothPlugins() {
            #expect(AIAppsSetup.pluginLines == ["/plugin marketplace add stephenlthorn/earshot",
                                                "/plugin install earshot@earshot",
                                                "/plugin install earshot-reminders@earshot"])
        }

        @Test func addToClaudeCodeUsesTheChildEnvironmentAndShowsTheOutput() async {
            let runner = FakeRunner(ProcessOutput(status: 0, stdout: "Added stdio MCP server earshot\n", stderr: "",
                                                  timedOut: false))
            let shown = await app.addToClaudeCode(claudePath: "/opt/homebrew/bin/claude", runner: runner)
            #expect(shown == "Added stdio MCP server earshot")
            let call = try! #require(runner.calls.first)
            #expect(call.executable == "/opt/homebrew/bin/claude")
            #expect(call.arguments == app.mcpAddArguments)
            #expect(!call.inheritEnvironment)
            #expect(call.environment == ClaudeEnvironment.child(claudePath: "/opt/homebrew/bin/claude"))
            #expect(call.environment["ANTHROPIC_API_KEY"] == nil)
        }

        @Test func anExistingServerReadsAsAlreadyAdded() async {
            let runner = FakeRunner(ProcessOutput(status: 1, stdout: "",
                                                  stderr: "MCP server earshot already exists in user config\n",
                                                  timedOut: false))
            let shown = await app.addToClaudeCode(claudePath: "/c", runner: runner)
            #expect(shown == AIAppsSetup.alreadyAdded)
        }

        @Test func aFailureShowsWhatClaudeCodeSaid() async {
            let runner = FakeRunner(ProcessOutput(status: 2, stdout: "", stderr: "error: unknown option '--scope'\n",
                                                  timedOut: false))
            let shown = await app.addToClaudeCode(claudePath: "/c", runner: runner)
            #expect(shown == "Claude Code said: error: unknown option '--scope'")
        }

        @Test func aClaudeThatCannotStartSaysSo() async {
            let shown = await app.addToClaudeCode(claudePath: "/c", runner: ThrowingRunner(error: CancellationError()))
            #expect(shown.hasPrefix("Couldn't run Claude Code"))
        }
    }

    struct Welcome {
        @Test func aNewUserGetsOnboarding() {
            #expect(WelcomeSheet.which(onboarded: false, onboardedVersion: 0) == .onboarding)
        }

        @Test func anUpgradingUserGetsWhatsNewOnce() {
            #expect(WelcomeSheet.which(onboarded: true, onboardedVersion: 0) == .whatsNew)
            #expect(WelcomeSheet.which(onboarded: true, onboardedVersion: 1) == .whatsNew)
            // 0.3: a user who saw "New in 0.2" sees "New in 0.3" once.
            #expect(WelcomeSheet.which(onboarded: true, onboardedVersion: 2) == .whatsNew)
            #expect(WelcomeSheet.which(onboarded: true, onboardedVersion: 3) == nil)
            #expect(WelcomeSheet.which(onboarded: true, onboardedVersion: 4) == nil)
        }

        @Test func aNewUserWhoFinishedOnboardingNeverSeesWhatsNew() {
            #expect(WelcomeSheet.which(onboarded: false, onboardedVersion: WelcomeSheet.currentVersion) == nil)
            #expect(WelcomeSheet.currentVersion == 3)
        }

        /// What's New lists what 0.2 added only for users coming from 0.1, who never saw "New in v0.2".
        @Test func onlyUsersFrom01SeeThe02Points() {
            #expect(WelcomeSheet.shows02Points(onboardedVersion: 0))
            #expect(WelcomeSheet.shows02Points(onboardedVersion: 1))
            #expect(!WelcomeSheet.shows02Points(onboardedVersion: 2))
            #expect(!WelcomeSheet.shows02Points(onboardedVersion: 3))
        }
    }

    struct Advice {
        func status(_ plan: String?, _ state: ClaudeCodeStatus.State = .ready) -> ClaudeCodeStatus {
            ClaudeCodeStatus(state: state, path: "/c", version: "2.1.296", subscription: plan)
        }

        @Test func onlyAReadyProPlanGetsTheProHint() {
            #expect(ClaudeAdvice.isProPlan(status("pro")))
            #expect(ClaudeAdvice.isProPlan(status("Pro")))
            #expect(!ClaudeAdvice.isProPlan(status("max")))
            #expect(!ClaudeAdvice.isProPlan(status(nil)))
            #expect(!ClaudeAdvice.isProPlan(status("pro", .notSignedIn)))
            #expect(!ClaudeAdvice.isProPlan(nil))
        }

        @Test func theProHintSuggestsSonnetAndLeavingLiveOff() {
            #expect(ClaudeAdvice.proHint.contains("Sonnet"))
            #expect(ClaudeAdvice.proHint.contains("live assistant off"))
        }

        @Test func theDefaultIntervalIsAbout40CallsAnHour() {
            #expect(ClaudeAdvice.callsPerHour(interval: 90) == 40)
            #expect(ClaudeAdvice.callsPerHour(interval: 60) == 60)
            #expect(ClaudeAdvice.callsPerHour(interval: 180) == 20)
            #expect(ClaudeAdvice.callsPerHour(interval: 0) == 0)
            #expect(ClaudeAdvice.defaultCallsLine == "About 40 live calls an hour at the default interval")
            #expect(ClaudeAdvice.callsLine(interval: 120) == "About 30 live calls an hour")
            #expect(ClaudeAdvice.liveIntervals == [60, 90, 120, 180])
        }

        @Test func autoAndBypassUsersAreOfferedRestrictedOnce() {
            #expect(PermissionNotice.shouldOffer(permissionMode: "auto", dismissed: false))
            #expect(PermissionNotice.shouldOffer(permissionMode: "bypassPermissions", dismissed: false))
            #expect(!PermissionNotice.shouldOffer(permissionMode: "auto", dismissed: true))
            #expect(!PermissionNotice.shouldOffer(permissionMode: "restricted", dismissed: false))
            #expect(!PermissionNotice.shouldOffer(permissionMode: "acceptEdits", dismissed: false))
        }

        @Test func onlyAnUpgradeWithAutoOrBypassSavedKeepsTheOfferOpen() {
            #expect(PermissionNotice.answeredByWelcome(.onboarding, permissionMode: "auto"))
            #expect(PermissionNotice.answeredByWelcome(.onboarding, permissionMode: "restricted"))
            #expect(PermissionNotice.answeredByWelcome(.whatsNew, permissionMode: "acceptEdits"))
            #expect(PermissionNotice.answeredByWelcome(.whatsNew, permissionMode: "restricted"))
            #expect(!PermissionNotice.answeredByWelcome(.whatsNew, permissionMode: "auto"))
            #expect(!PermissionNotice.answeredByWelcome(.whatsNew, permissionMode: "bypassPermissions"))
        }

        @Test func noTextHasAnEmDash() {
            let texts = [ClaudeAdvice.proHint, ClaudeAdvice.defaultCallsLine, PermissionNotice.text,
                         AIAppsSetup.helperMissing, AIAppsSetup.alreadyAdded, AIAppsSetup.moveFirst,
                         ConfirmDraft.needsTask, ConfirmDraft.startedDuringCall]
            #expect(texts.allSatisfy { !$0.contains("\u{2014}") })
        }
    }

    struct Rows {
        let folder = URL(fileURLWithPath: "/m/2026-10-14 Acme")

        @Test func aMeetingOpensItsPageFirst() {
            let all: Set<String> = [folder.appending(path: "notes.html").path, folder.appending(path: "notes.md").path]
            #expect(MeetingOpener.target(folder: folder, exists: all.contains).lastPathComponent == "notes.html")
        }

        @Test func thenItsMarkdownThenTheFolder() {
            let md: Set<String> = [folder.appending(path: "notes.md").path]
            #expect(MeetingOpener.target(folder: folder, exists: md.contains).lastPathComponent == "notes.md")
            #expect(MeetingOpener.target(folder: folder, exists: { _ in false }) == folder)
        }
    }

    struct AskFix {
        func session(_ mode: Mode = .notesAndDo, dispatch: StageState.Status? = nil, recording: Bool = false) -> Session {
            var stages: [Stage: StageState] = [:]
            if let dispatch { stages[.dispatch] = StageState(status: dispatch) }
            return Session(id: "s1", folderName: "f", title: "Acme", mode: mode, startedAt: at1530, endedAt: nil,
                           recording: recording, tracks: [], stages: stages, sent: [], warnings: [])
        }

        @Test func askNeedsATranscriptAndAFinishedRecording() {
            #expect(AskRules.canAsk(session(), hasTranscript: true))
            #expect(!AskRules.canAsk(session(), hasTranscript: false))
            #expect(!AskRules.canAsk(session(recording: true), hasTranscript: true))
        }

        @Test func fixNeedsNotesAndAnIdlePipeline() {
            #expect(AskRules.canFix(hasNotes: true, running: false))
            #expect(!AskRules.canFix(hasNotes: true, running: true))
            #expect(!AskRules.canFix(hasNotes: false, running: false))
        }

        @Test func doRanWhenTheDispatchStageIsDoneOrItemsWereChosen() {
            #expect(AskRules.doAlreadyRan(session(dispatch: .done), itemsChosen: false))
            #expect(AskRules.doAlreadyRan(session(dispatch: .failed), itemsChosen: true))
            #expect(!AskRules.doAlreadyRan(session(dispatch: .pending), itemsChosen: false))
            #expect(!AskRules.doAlreadyRan(session(.notes), itemsChosen: false))
            #expect(!AskRules.doAlreadyRan(session(.notes, dispatch: .done), itemsChosen: true))
        }

        @Test func newItemsAreTheAddedOnesByTheirIndexInTheRevisedNotes() {
            let old = MeetingNotes(title: "A", summary: "s", actionItems: [
                ActionItem(task: "Call the venue", owner: "Me", doer: .me),
                ActionItem(task: "Email Dana the scope", owner: "Me", doer: .ai, source: "n2"),
            ])
            let new = MeetingNotes(title: "A", summary: "s", actionItems: [
                ActionItem(task: "Book a room for the pilot review", owner: "Me", doer: .ai),
                ActionItem(task: "Call the venue", owner: "Me", doer: .me),
                ActionItem(task: "Email Dana the scope", owner: "Me", doer: .ai),
                ActionItem(task: "Send the invoice to Acme finance", owner: "Me", doer: .ai),
            ])
            #expect(AskRules.newItems(old: old, new: new) == [0, 3])
            #expect(AskRules.newItems(old: new, new: new).isEmpty)
        }

        @Test func aDuplicatedNewItemCountsOncePerCopy() {
            let old = MeetingNotes(title: "A", summary: "s")
            let one = ActionItem(task: "Send the deck", owner: "Me", doer: .ai)
            let new = MeetingNotes(title: "A", summary: "s", actionItems: [one, one])
            #expect(AskRules.newItems(old: old, new: new) == [0, 1])
        }

        @Test func aMeetingHasATranscriptOnceTranscribingFinished() {
            var meeting = session(.notes)
            #expect(!AskRules.hasTranscript(meeting))
            meeting.stages[.transcribe] = StageState(status: .running)
            #expect(!AskRules.hasTranscript(meeting))
            meeting.stages[.transcribe] = StageState(status: .done)
            #expect(AskRules.hasTranscript(meeting))
            #expect(!AskRules.hasTranscript(session(.record)))
        }

        @Test func pendingItemsAreFoundByTheirPlaceInTheNotes() {
            let room = ActionItem(task: "Book a room", owner: "Me", doer: .ai)
            let deck = ActionItem(task: "Send the deck", owner: "Me", doer: .ai)
            var sourced = deck
            sourced.source = "n3"
            let notes = MeetingNotes(title: "A", summary: "s", actionItems: [deck, room, sourced])
            #expect(AskRules.indices(of: [room, deck, deck], in: notes) == [0, 1, 2])
            #expect(AskRules.indices(of: [ActionItem(task: "Gone", owner: "Me", doer: .ai)], in: notes).isEmpty)
        }

        @Test func aSecondFixKeepsTheUnsentItemsOfTheFirst() {
            let deck = ActionItem(task: "Send the deck", owner: "Me", doer: .ai)
            let room = ActionItem(task: "Book a room for the review", owner: "Me", doer: .ai)
            let call = ActionItem(task: "Call the venue", owner: "Me", doer: .me)
            let first = MeetingNotes(title: "A", summary: "s", actionItems: [call, deck, room])
            var renamed = room
            renamed.owner = "Dana"
            let invoice = ActionItem(task: "Email Acme finance about billing", owner: "Me", doer: .ai)
            let second = MeetingNotes(title: "A", summary: "s", actionItems: [call, renamed, invoice])
            // deck was removed by the second Fix, room was changed and follows its change, invoice is new.
            let pending = AskRules.pending([deck, room], old: first, new: second)
            #expect(pending == [renamed, invoice])
            #expect(AskRules.indices(of: pending, in: second) == [1, 2])
        }

        @Test func theNewItemsStayUntilEveryTargetTookThem() {
            #expect(AskRules.sentToEveryTarget(["webhook": DispatchResult(ok: true, detail: "200")]))
            #expect(!AskRules.sentToEveryTarget(["webhook": DispatchResult(ok: true, detail: "200"),
                                                 "routine": DispatchResult(ok: false, detail: "401")]))
            #expect(!AskRules.sentToEveryTarget([:]))
        }

        @Test func sendNewItemsLabel() {
            #expect(AskRules.sendNewItemsLabel(1) == "Send the 1 new item…")
            #expect(AskRules.sendNewItemsLabel(3) == "Send the 3 new items…")
        }
    }
}

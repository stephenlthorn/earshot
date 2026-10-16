import Foundation
import Testing
@testable import EarshotKit

struct ChoiceStubTarget: DoTarget {
    let id: String
    let label: String
    func send(_ payload: DoPayload, json: Data, folder: URL) async -> DispatchResult { DispatchResult(ok: true, detail: "") }
}

private func liveSettings(_ change: (inout EarshotSettings) -> Void = { _ in }) -> EarshotSettings {
    var settings = EarshotSettings()
    settings.liveAssistant = true
    change(&settings)
    return settings
}

/// Spec 4.4 as adopted: a chosen live target that is off or can't run falls back to the first working target.
struct LiveTargetChoiceTests {
    let webhook = ChoiceStubTarget(id: "webhook", label: "Webhook")
    let command = ChoiceStubTarget(id: "command", label: "Command")
    let brokenClaude = UnavailableTarget(id: "claude-code", label: "Claude Code", reason: "No folder")

    @Test func withNothingChosenTheFirstWorkingTargetIsUsedWithoutANote() {
        let choice = LiveTargetChoice.make(settings: liveSettings(), targets: [brokenClaude, webhook, command])
        #expect(choice.target?.id == "webhook")
        #expect(!choice.chosenIsOff)
        #expect(choice.settingsNote == nil)
        #expect(choice.decision == .oneClick)
    }

    @Test func aChosenTargetThatWorksIsUsed() {
        let choice = LiveTargetChoice.make(settings: liveSettings { $0.liveTarget = "command" },
                                           targets: [webhook, command])
        #expect(choice.target?.id == "command")
        #expect(!choice.chosenIsOff)
        #expect(choice.settingsNote == nil)
        #expect(choice.decision == .confirmSheet)
    }

    @Test func aChosenTargetThatIsOffFallsBackToTheFirstWorkingOne() {
        let choice = LiveTargetChoice.make(settings: liveSettings { $0.liveTarget = "routine" },
                                           targets: [webhook, command])
        #expect(choice.target?.id == "webhook")
        #expect(choice.chosenIsOff)
        #expect(choice.decision == .oneClick)
        #expect(choice.settingsNote == "The chosen target is off. Start uses Webhook for now.")
    }

    @Test func aChosenTargetThatCantRunFallsBackInTheUsualOrder() {
        let choice = LiveTargetChoice.make(settings: liveSettings { $0.liveTarget = "claude-code" },
                                           targets: [brokenClaude, command, webhook])
        #expect(choice.target?.id == "command")
        #expect(choice.chosenIsOff)
        #expect(choice.decision == .confirmSheet)
        #expect(choice.settingsNote == "The chosen target is off. Start uses Command for now.")
    }

    @Test func aChosenTargetWithNothingElseWorkingOffersSetUp() {
        let choice = LiveTargetChoice.make(settings: liveSettings { $0.liveTarget = "claude-code" },
                                           targets: [brokenClaude])
        #expect(choice.target == nil)
        #expect(choice.chosenIsOff)
        #expect(choice.settingsNote == nil)
        #expect(choice.decision == .unavailable(LiveStartPolicy.setUpTarget))
    }

    @Test func aFallbackRoutineStillNeedsAllowStartDuringCalls() {
        let routine = ChoiceStubTarget(id: "routine", label: "Claude Code routine")
        let choice = LiveTargetChoice.make(settings: liveSettings { $0.liveTarget = "webhook" }, targets: [routine])
        #expect(choice.target?.id == "routine")
        #expect(choice.decision == .unavailable(LiveStartPolicy.routineNotAllowed))
        let allowed = LiveTargetChoice.make(settings: liveSettings { $0.liveTarget = "webhook"; $0.allowRoutineLiveStart = true },
                                            targets: [routine])
        #expect(allowed.decision == .oneClick)
    }

    @Test func theNoteHasNoDashes() {
        let note = LiveTargetChoice.fallbackNote("Webhook")
        #expect(!note.contains("\u{2014}") && !note.contains("\u{2013}"))
    }

    @Test func livePolicyFollowsTheSameChoice() {
        let chosen = liveSettings { $0.liveTarget = "claude-code" }
        #expect(LiveStartPolicy.liveTarget(settings: chosen, targets: [brokenClaude, webhook])?.id == "webhook")
        #expect(LiveStartPolicy.decision(settings: chosen, targets: [brokenClaude, webhook]) == .oneClick)
        #expect(LiveStartPolicy.startAvailable(mode: .notesAndDo, settings: chosen, targets: [brokenClaude, webhook]))
    }
}

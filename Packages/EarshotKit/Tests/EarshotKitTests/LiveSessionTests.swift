import AVFoundation
import Foundation
import Testing
@testable import EarshotKit

struct LiveSessionTests {
    @Test func theFeedSendsEachTrackToItsOwnTranscriber() throws {
        let h = try LiveHarness()
        let feed = LiveSession.feed(for: [h.me, h.them])
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        feed(.me, buffer, 1)
        feed(.them, buffer, 2)
        feed(.speaker, buffer, 3)
        #expect(h.me.appended.get == [1])
        #expect(h.them.appended.get == [2])
    }

    @Test(.timeLimit(.minutes(1))) func finalsReachLiveJSONAndTheTickerShowsVolatileText() async throws {
        let h = try LiveHarness()
        let live = h.live()
        let events = Events(live.events)
        await live.start()
        await pollUntil { h.me.started.get == 1 && h.them.started.get == 1 }
        #expect(h.me.started.get == 1 && h.them.started.get == 1)
        h.them.say("Can you send the", 1, 2, final: false)
        await pollUntil { events.all.get.contains(.ticker(me: "", them: "Can you send the")) }
        h.them.say("Can you send the scope?", 1, 3)
        h.me.say("Sure.", 3, 4)
        await pollUntil { live.store.segments.count == 2 }
        await live.stop()
        let file = try h.store.read(LiveFile.self, h.session, MeetingFile.live)
        #expect(file.segments.sorted { $0.start < $1.start }.map(\.text) == ["Can you send the scope?", "Sure."])
        #expect(events.all.get.contains(.ticker(me: "", them: "")))
        #expect(h.me.finished.get == 1 && h.them.finished.get == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aPassSendsTheNewTextFinalizesFirstAndShowsTheItems() async throws {
        let h = try LiveHarness()
        let client = ScriptedClaude(liveOneItem)
        let live = h.live(client: client)
        let events = Events(live.events)
        await live.start()
        h.them.say(liveLongLine, 0, 20)
        await pollUntil { live.store.segments.count == 1 }
        #expect(await live.passNow() == .extracted)
        #expect(h.me.finalized.get == 1 && h.them.finalized.get == 1)
        #expect(client.requests.get.first?.user.contains("pilot scope in writing") == true)
        await pollUntil { events.items?.count == 1 }
        #expect(events.items?.first?.task == "Send Dana the pilot scope")
        #expect(live.store.items.map(\.id) == ["L1"])
        await live.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aSpokenFlagOnTheMeTrackIsSavedOnceAndNeverFromThem() async throws {
        let h = try LiveHarness()
        let live = h.live()
        let events = Events(live.events)
        await live.start()
        h.them.say("Flag that.", 10, 11)
        h.me.say("That price is fine, flag that.", 20, 22)
        h.me.say("Flag that.", 25, 26)
        h.me.say("Earshot, flag.", 40, 41)
        await pollUntil { events.flags.count == 2 }
        await live.stop()
        let expected = [Flag(offset: 22, source: .voice), Flag(offset: 41, source: .voice)]
        #expect(events.flags == expected)
        #expect(h.store.find(h.session.id)?.flags == expected)
    }

    @Test(.timeLimit(.minutes(1))) func voiceFlagsCanBeSwitchedOff() async throws {
        let h = try LiveHarness()
        var settings = EarshotSettings()
        settings.voiceFlags = false
        let live = h.live(settings: settings)
        await live.start()
        h.me.say("Flag that.", 20, 22)
        await pollUntil { live.store.segments.count == 1 }
        await live.stop()
        #expect(h.store.find(h.session.id)?.flags == [])
    }

    @Test func aPressedFlagIsSavedAtTheMeetingClockAndARepeatIsNot() async throws {
        let h = try LiveHarness()
        let live = h.live(transcribers: [])
        #expect(await live.flag(.hotkey) == Flag(offset: 30, source: .hotkey))
        #expect(await live.flag(.panel) == nil)
        #expect(h.store.find(h.session.id)?.flags == [Flag(offset: 30, source: .hotkey)])
    }

    @Test(.timeLimit(.minutes(1))) func startSendsTheRowAsDrawnAndTheNextPassKnowsItWentOut() async throws {
        let h = try LiveHarness()
        let client = ScriptedClaude(liveOneItem)
        let live = h.live(client: client)
        let events = Events(live.events)
        await live.start()
        h.them.say(liveLongLine, 0, 20)
        await pollUntil { live.store.segments.count == 1 }
        await live.passNow()
        var row = try #require(live.store.items.first)
        row.task = "Send Dana the pilot scope today"
        let target = KeptTarget()
        let payload = await live.payload(for: row, at: at1530)
        #expect(await live.start(row, payload: payload, target: target, confirmed: true))
        await pollUntil { live.store.items.first?.status == .sent }
        #expect(target.sent.get.first?.items.first?.task == "Send Dana the pilot scope today")
        #expect(target.sent.get.first?.session.id == "\(h.session.id)-live-1")
        await pollUntil { events.items?.first?.status == .sent }

        h.me.say(liveLongLine, 30, 50)
        await pollUntil { live.store.segments.count == 2 }
        try await live.dismiss("L1")
        #expect(live.store.items.first?.status == .sent)  // a started item can't be dismissed
        // The next pass knows L1 went out, so the model never offers it again as a suggestion.
        #expect(await live.passNow() == .extracted)
        let second = try #require(client.requests.get.last?.user)
        #expect(second.contains("L1: Send Dana the pilot scope today (owner: Stephen, status: sent)"))
        await live.stop()
    }

    @Test(.timeLimit(.minutes(1))) func dismissIsSavedAtOnceShownAndReachesTheExtractor() async throws {
        let h = try LiveHarness()
        let client = ScriptedClaude(liveOneItem)
        let live = h.live(client: client)
        let events = Events(live.events)
        await live.start()
        h.them.say(liveLongLine, 0, 20)
        await pollUntil { live.store.segments.count == 1 }
        await live.passNow()
        try await live.dismiss("L1")
        #expect(try h.store.read(LiveFile.self, h.session, MeetingFile.live).items.first?.status == .dismissed)
        await pollUntil { events.items?.first?.status == .dismissed }
        // The extractor was told: the next pass lists L1 as dismissed, and an answer about it keeps it dismissed.
        h.me.say(liveLongLine, 30, 50)
        await pollUntil { live.store.segments.count == 2 }
        #expect(await live.passNow() == .extracted)
        let second = try #require(client.requests.get.last?.user)
        #expect(second.contains("L1: Send Dana the pilot scope (owner: Stephen, status: dismissed)"))
        #expect(live.store.items.first { $0.id == "L1" }?.status == .dismissed)
        await live.stop()
    }

    @Test(.timeLimit(.minutes(1))) func withoutAClientThereAreNoPassesAndThePanelSaysWhy() async throws {
        let h = try LiveHarness()
        let live = h.live(client: nil)
        let events = Events(live.events)
        await live.start()
        await pollUntil { events.all.get.contains(.status(.paused(LiveSession.claudeNotSetUp))) }
        #expect(await live.passNow() == nil)
        await live.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aTranscriberThatCantStartIsReported() async throws {
        let h = try LiveHarness()
        let live = h.live(transcribers: [SpokenTranscriber(.me, failStart: true)])
        let events = Events(live.events)
        await live.start()
        await pollUntil { events.all.get.contains(.transcriptionFailed(LiveTranscriberError.noAudioFormat.localizedDescription)) }
        #expect(events.all.get.contains(.transcriptionFailed(LiveTranscriberError.noAudioFormat.localizedDescription)))
        await live.stop()
    }

    @Test func withinTellsWhetherTheWorkFinishedInTime() async {
        #expect(await LiveSession.within(.seconds(5)) {})
        #expect(!(await LiveSession.within(.milliseconds(50)) { try? await Task.sleep(for: .seconds(30)) }))
    }
}

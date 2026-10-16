import Foundation
import Testing
@testable import EarshotKit

/// Screen reading switched off or narrowed during a recording stops at once, and Stop still waits for that save
/// (spec 9).
struct ScreenSavesTests {
    private func settings(_ change: (inout EarshotSettings) -> Void = { _ in }) -> EarshotSettings {
        var settings = EarshotSettings()
        settings.readScreen = true
        change(&settings)
        return settings
    }

    private func running(_ options: ScreenSampler.Options = ScreenSampler.Options()) -> ScreenSaves {
        var saves = ScreenSaves()
        saves.started(options)
        return saves
    }

    @Test func aSaveStartedBySwitchingOffIsTheOneStopGets() {
        var saves = running()
        let midCall = Task<Void, Never> {}
        saves.stoppedMidCall(saving: midCall)
        #expect(saves.running == nil)
        #expect(saves.takeForStop(running: nil) == midCall)
        // Handed out once: a second Stop gets a save that is already done, not the same one again.
        #expect(saves.takeForStop(running: nil) != midCall)
    }

    @Test func aRunningSamplersSaveComesFirst() {
        var saves = running()
        let atStop = Task<Void, Never> {}
        #expect(saves.takeForStop(running: atStop) == atStop)
    }

    @Test func aNewRecordingForgetsTheEarlierSave() {
        var saves = running()
        let midCall = Task<Void, Never> {}
        saves.stoppedMidCall(saving: midCall)
        saves.started(nil)
        #expect(saves.takeForStop(running: nil) != midCall)
        saves.started(ScreenSampler.Options())
        #expect(saves.running == ScreenSampler.Options())
    }

    @Test func screenReadingSwitchedOffStopsTheSampler() {
        let saves = running()
        #expect(saves.stopsNow(from: settings(), to: settings { $0.readScreen = false }))
        #expect(!saves.stopsNow(from: settings(), to: settings { $0.liveAssistant.toggle() }))
    }

    @Test func wholeDisplaySwitchedOffStopsASamplerReadingIt() {
        let whole = running(ScreenSampler.Options(wholeDisplay: true))
        let before = settings { $0.screenWholeDisplay = true }, after = settings { $0.screenWholeDisplay = false }
        #expect(whole.stopsNow(from: before, to: after))
        // A sampler that reads only the call app's windows isn't affected.
        #expect(!running().stopsNow(from: before, to: after))
    }

    @Test func keepScreenshotsSwitchedOffStopsASamplerKeepingThem() {
        let keeping = running(ScreenSampler.Options(keepImages: true))
        let before = settings { $0.keepScreenshots = true }, after = settings { $0.keepScreenshots = false }
        #expect(keeping.stopsNow(from: before, to: after))
        #expect(!running().stopsNow(from: before, to: after))
    }

    @Test func nothingStopsWhenNoSamplerRuns() {
        let idle = ScreenSaves()
        #expect(!idle.stopsNow(from: settings(), to: settings { $0.readScreen = false }))
    }

    @Test func narrowingFollowsTheRunningOptions() {
        let options = ScreenSampler.Options(wholeDisplay: true, keepImages: true)
        #expect(RecordingSwitches.narrowsScreenReading(options, to: settings { $0.keepScreenshots = false }))
        #expect(RecordingSwitches.narrowsScreenReading(options, to: settings { $0.screenWholeDisplay = false }))
        #expect(!RecordingSwitches.narrowsScreenReading(options, to: settings {
            $0.screenWholeDisplay = true
            $0.keepScreenshots = true
        }))
        #expect(!RecordingSwitches.narrowsScreenReading(ScreenSampler.Options(), to: settings()))
    }
}

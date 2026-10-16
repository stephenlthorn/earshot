import CoreAudio
import Foundation
import Testing
@testable import EarshotKit

private let zoomID = "us.zoom.xos"
private let chromeHelperID = "com.google.Chrome.helper"
private let t0 = Date(timeIntervalSince1970: 1_792_006_200)

private func proc(_ pid: Int32, _ bundleID: String?, input: Bool = true, output: Bool = true,
                  realMic: Bool = true) -> AudioProcessInfo {
    AudioProcessInfo(pid: pid, bundleID: bundleID, runningInput: input, runningOutput: output,
                     usesRealMicrophone: input && realMic)
}

private func zoomCall(_ pid: Int32 = 100) -> CallEvent.Call {
    CallEvent.Call(pid: pid, bundleID: zoomID, appName: "Zoom", isDedicated: true)
}

struct DetectMeetingAppsTests {
    @Test func listsEverySpecPrefix() {
        #expect(MeetingApps.dedicatedPrefixes == [
            "us.zoom.", "com.microsoft.teams", "com.cisco.webex", "Cisco-Systems.Spark", "com.tinyspeck.slackmacgap",
            "com.hnc.Discord", "com.apple.FaceTime", "com.skype.", "app.tuple.", "com.loom.",
        ])
        #expect(MeetingApps.browserPrefixes == [
            "com.google.Chrome", "com.apple.Safari", "com.apple.WebKit", "org.mozilla.firefox", "com.microsoft.edgemac",
            "company.thebrowser.", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        ])
        #expect(MeetingApps.prefixes == MeetingApps.dedicatedPrefixes + MeetingApps.browserPrefixes)
    }

    @Test func dedicatedAppsMatchByPrefix() {
        #expect(MeetingApps.isDedicatedCallApp("us.zoom.xos"))
        #expect(MeetingApps.isDedicatedCallApp("com.microsoft.teams2"))
        #expect(MeetingApps.isDedicatedCallApp("com.apple.FaceTime"))
        #expect(!MeetingApps.isDedicatedCallApp("com.google.Chrome"))
        #expect(!MeetingApps.isDedicatedCallApp("us.zoomer.app"))
        #expect(!MeetingApps.isDedicatedCallApp(""))
    }

    @Test func matchPrefersTheRunningAppName() {
        #expect(MeetingApps.match(zoomID, runningApps: [zoomID: "zoom.us"]) == "zoom.us")
    }

    @Test func matchMapsABrowserHelperToItsParentApp() {
        let running = ["com.google.Chrome": "Google Chrome", "com.google.Chrome.canary": "Chrome Canary"]
        #expect(MeetingApps.match(chromeHelperID, runningApps: running) == "Google Chrome")
    }

    @Test func matchPrefersTheParentAppOverAHelpersOwnName() {
        let running = ["com.google.Chrome": "Google Chrome", chromeHelperID: "Google Chrome Helper (Aperitif)"]
        #expect(MeetingApps.match(chromeHelperID, runningApps: running) == "Google Chrome")
        #expect(MeetingApps.match(chromeHelperID, runningApps: [chromeHelperID: "Google Chrome Helper"]) == "Google Chrome Helper")
    }

    @Test func appKeyIsTheMatchedPrefixWithWebKitAsSafari() {
        #expect(MeetingApps.appKey(for: zoomID) == "us.zoom.")
        #expect(MeetingApps.appKey(for: "us.zoom.CptHost") == "us.zoom.")
        #expect(MeetingApps.appKey(for: chromeHelperID) == "com.google.Chrome")
        #expect(MeetingApps.appKey(for: "com.apple.WebKit.GPU") == "com.apple.Safari")
        #expect(MeetingApps.appKey(for: "com.spotify.client") == nil)
    }

    @Test func matchUsesAnotherProcessOfTheSameAppForItsName() {
        #expect(MeetingApps.match("us.zoom.CptHost", runningApps: [zoomID: "zoom.us"]) == "zoom.us")
    }

    @Test func matchFallsBackToAKnownName() {
        #expect(MeetingApps.match(zoomID, runningApps: [:]) == "Zoom")
        #expect(MeetingApps.match(chromeHelperID, runningApps: [:]) == "Google Chrome")
        #expect(MeetingApps.match("com.microsoft.teams2", runningApps: [:]) == "Microsoft Teams")
    }

    @Test func webKitCountsOnlyWhileSafariRuns() {
        #expect(MeetingApps.match("com.apple.WebKit.GPU", runningApps: [:]) == nil)
        #expect(MeetingApps.match("com.apple.WebKit.GPU", runningApps: ["com.apple.mail": "Mail"]) == nil)
        #expect(MeetingApps.match("com.apple.WebKit.GPU", runningApps: ["com.apple.Safari": "Safari"]) == "Safari")
    }

    @Test func appsOffTheListDontMatch() {
        #expect(MeetingApps.match("com.spotify.client", runningApps: ["com.spotify.client": "Spotify"]) == nil)
        #expect(MeetingApps.match("us.zoomer.app", runningApps: [:]) == nil)
        #expect(MeetingApps.match("", runningApps: [:]) == nil)
    }
}

struct DetectCallNoticePolicyTests {
    @Test func noticesACallAppThatStartsUsingTheRealMicrophone() {
        var policy = CallNoticePolicy(ownPID: 1)
        #expect(policy.notice([proc(100, zoomID, input: false)], recording: false, runningApps: [:], now: t0) == nil)
        let call = policy.notice([proc(100, zoomID)], recording: false, runningApps: [zoomID: "zoom.us"], now: t0)
        #expect(call == CallEvent.Call(pid: 100, bundleID: zoomID, appName: "zoom.us", isDedicated: true))
        #expect(policy.lastAsked["us.zoom."] == t0)
    }

    @Test func aCallAlreadyRunningAtTheFirstLookCounts() {
        var policy = CallNoticePolicy(ownPID: 1)
        #expect(policy.notice([proc(100, zoomID)], recording: false, runningApps: [:], now: t0)?.appName == "Zoom")
    }

    @Test func firesOnceWhileTheMicStaysOn() {
        var policy = CallNoticePolicy(ownPID: 1)
        #expect(policy.notice([proc(100, zoomID)], recording: false, runningApps: [:], now: t0) != nil)
        for minute in 1...30 {
            let later = t0.addingTimeInterval(Double(minute) * 60)
            #expect(policy.notice([proc(100, zoomID)], recording: false, runningApps: [:], now: later) == nil)
        }
    }

    @Test func ignoresInputFromAVirtualDevice() {
        var policy = CallNoticePolicy(ownPID: 1)
        #expect(policy.notice([proc(100, zoomID, realMic: false)], recording: false, runningApps: [:], now: t0) == nil)
    }

    @Test func ignoresItsOwnProcess() {
        var policy = CallNoticePolicy(ownPID: 100)
        #expect(policy.notice([proc(100, zoomID)], recording: false, runningApps: [:], now: t0) == nil)
    }

    @Test func ignoresAppsOffTheList() {
        var policy = CallNoticePolicy(ownPID: 1)
        let snapshot = [proc(100, "com.spotify.client"), proc(101, nil), proc(102, "com.apple.WebKit.GPU")]
        #expect(policy.notice(snapshot, recording: false, runningApps: [:], now: t0) == nil)
    }

    @Test func staysQuietWhileRecordingAndAfterwardsForTheSameCall() {
        var policy = CallNoticePolicy(ownPID: 1)
        #expect(policy.notice([proc(100, zoomID)], recording: true, runningApps: [:], now: t0) == nil)
        #expect(policy.notice([proc(100, zoomID)], recording: false, runningApps: [:], now: t0 + 60) == nil)
        #expect(policy.lastAsked.isEmpty)
    }

    @Test func waitsTenMinutesBeforeAskingAboutTheSameAppAgain() {
        var policy = CallNoticePolicy(ownPID: 1)
        #expect(policy.notice([proc(100, zoomID)], recording: false, runningApps: [:], now: t0) != nil)
        #expect(policy.notice([proc(100, zoomID, input: false)], recording: false, runningApps: [:], now: t0 + 60) == nil)
        #expect(policy.notice([proc(100, zoomID)], recording: false, runningApps: [:], now: t0 + 599) == nil)
        #expect(policy.notice([proc(100, zoomID, input: false)], recording: false, runningApps: [:], now: t0 + 600) == nil)
        #expect(policy.notice([proc(100, zoomID)], recording: false, runningApps: [:], now: t0 + 600) != nil)
        #expect(CallNoticePolicy.quietPeriod == 600)
    }

    @Test func theQuietPeriodCoversEveryProcessOfTheApp() {
        var policy = CallNoticePolicy(ownPID: 1)
        #expect(policy.notice([proc(100, chromeHelperID)], recording: false, runningApps: [:], now: t0) != nil)
        #expect(policy.notice([proc(200, chromeHelperID)], recording: false, runningApps: [:], now: t0 + 120) == nil)
    }

    @Test func theQuietPeriodHoldsWhenTheAppsNameChanges() {
        var policy = CallNoticePolicy(ownPID: 1)
        #expect(policy.notice([proc(100, zoomID)], recording: false, runningApps: [:], now: t0)?.appName == "Zoom")
        #expect(policy.notice([proc(100, zoomID, input: false)], recording: false, runningApps: [:], now: t0 + 60) == nil)
        let named = [zoomID: "zoom.us"]
        #expect(policy.notice([proc(100, zoomID)], recording: false, runningApps: named, now: t0 + 120) == nil)
    }

    @Test func forgettingThePreviousSnapshotCountsAHeldMicAsAStart() {
        var policy = CallNoticePolicy(ownPID: 1)
        let held = [proc(100, zoomID)]
        #expect(policy.notice(held, recording: false, runningApps: [:], now: t0) != nil)
        policy.forgetPreviousSnapshot()
        #expect(policy.lastAsked["us.zoom."] == t0)
        #expect(policy.notice(held, recording: false, runningApps: [:], now: t0 + 120) == nil)
        #expect(policy.notice(held, recording: false, runningApps: [:], now: t0 + 601) == nil)
        policy.forgetPreviousSnapshot()
        #expect(policy.notice(held, recording: false, runningApps: [:], now: t0 + 602) != nil)
    }

    @Test func anotherAppStillGetsAsked() {
        var policy = CallNoticePolicy(ownPID: 1)
        #expect(policy.notice([proc(100, zoomID)], recording: false, runningApps: [:], now: t0) != nil)
        let both = [proc(100, zoomID), proc(200, chromeHelperID)]
        #expect(policy.notice(both, recording: false, runningApps: [:], now: t0 + 5)?.appName == "Google Chrome")
    }

    @Test func aDedicatedAppWinsWhenTwoStartTogether() {
        var policy = CallNoticePolicy(ownPID: 1)
        let both = [proc(50, chromeHelperID), proc(100, zoomID)]
        #expect(policy.notice(both, recording: false, runningApps: [:], now: t0)?.bundleID == zoomID)
    }

    @Test func autoRecordNeedsAWayToReachTheUser() {
        #expect(CallNoticePolicy.canTurnOnAutoRecord(notificationsAuthorized: true, panelOn: false))
        #expect(CallNoticePolicy.canTurnOnAutoRecord(notificationsAuthorized: false, panelOn: true))
        #expect(!CallNoticePolicy.canTurnOnAutoRecord(notificationsAuthorized: false, panelOn: false))
    }

    @Test func autoRecordStartsDedicatedAppsOnly() {
        let chrome = CallEvent.Call(pid: 2, bundleID: chromeHelperID, appName: "Google Chrome", isDedicated: false)
        func auto(_ call: CallEvent.Call, on: Bool = true, video: Bool = false, notify: Bool = true, panel: Bool = false) -> Bool {
            CallNoticePolicy.shouldAutoRecord(call, autoRecordOn: on, eventHasVideoLink: video,
                                              notificationsAuthorized: notify, panelOn: panel)
        }
        #expect(auto(zoomCall()))
        #expect(auto(zoomCall(), notify: false, panel: true))
        #expect(!auto(zoomCall(), on: false))
        #expect(!auto(zoomCall(), notify: false, panel: false))
        #expect(!auto(chrome))
        #expect(auto(chrome, video: true))
        #expect(!auto(chrome, video: true, notify: false, panel: false))
    }
}

struct DetectAutoStopPolicyTests {
    private func policy(byEarshot: Bool = true, stopWhenCallEnds: Bool = true, eventEnd: Date? = nil) -> AutoStopPolicy {
        AutoStopPolicy(call: zoomCall(), startedByEarshot: byEarshot, stopWhenCallEnds: stopWhenCallEnds,
                       eventEnd: eventEnd, startedAt: t0)
    }

    @Test func handStartedRecordingsNeverStop() {
        var stopper = policy(byEarshot: false)
        #expect(stopper.observe([], now: t0 + 3_600) == .keepRecording)
    }

    @Test func aMutedCallKeepsRecording() {
        var stopper = policy()
        for second in stride(from: 0, through: 600, by: 3) {
            #expect(stopper.observe([proc(100, zoomID, output: false)], now: t0 + Double(second)) == .keepRecording)
        }
    }

    @Test func stopsWhenTheAppIsGoneAfter45Seconds() {
        var stopper = policy()
        #expect(stopper.observe([proc(100, zoomID)], now: t0 + 10) == .keepRecording)
        #expect(stopper.observe([], now: t0 + 54) == .keepRecording)
        #expect(stopper.observe([], now: t0 + 55) == .stop)
    }

    @Test func stopsWhenInputAndOutputAreIdle() {
        var stopper = policy()
        #expect(stopper.observe([proc(100, zoomID)], now: t0) == .keepRecording)
        #expect(stopper.observe([proc(100, zoomID, input: false, output: false)], now: t0 + 45) == .stop)
    }

    @Test func stopsWhenTheEventHasEnded() {
        var stopper = policy(eventEnd: t0 + 30)
        #expect(stopper.observe([proc(100, zoomID)], now: t0) == .keepRecording)
        #expect(stopper.observe([proc(100, zoomID, input: false)], now: t0 + 44) == .keepRecording)
        #expect(stopper.observe([proc(100, zoomID, input: false)], now: t0 + 45) == .stop)
    }

    @Test func asksInsteadWhenStopWhenTheCallEndsIsOff() {
        var stopper = policy(stopWhenCallEnds: false)
        #expect(stopper.observe([], now: t0 + 45) == .ask)
        #expect(stopper.observe([], now: t0 + 3_600) == .ask)
        var ended = policy(stopWhenCallEnds: false, eventEnd: t0 + 30)
        #expect(ended.observe([proc(100, zoomID, input: false)], now: t0 + 3_600) == .ask)
    }

    @Test func asksAt45SecondsAndStopsAt5MinutesWhenTheCallMayContinue() {
        var stopper = policy(eventEnd: t0 + 3_600)
        let quiet = [proc(100, zoomID, input: false, output: true)]
        #expect(stopper.observe(quiet, now: t0 + 44) == .keepRecording)
        #expect(stopper.observe(quiet, now: t0 + 45) == .ask)
        #expect(stopper.observe(quiet, now: t0 + 299) == .ask)
        #expect(stopper.observe(quiet, now: t0 + 300) == .stop)
    }

    @Test func stillGivesUpAfter5MinutesWithStopWhenTheCallEndsOff() {
        var stopper = policy(stopWhenCallEnds: false)
        let quiet = [proc(100, zoomID, input: false, output: true)]
        #expect(stopper.observe(quiet, now: t0 + 45) == .ask)
        #expect(stopper.observe(quiet, now: t0 + 299) == .ask)
        #expect(stopper.observe(quiet, now: t0 + 300) == .stop)
    }

    @Test func keepRecordingTurnsOffTheGiveUpUntilInputRunsAgain() {
        var stopper = policy(stopWhenCallEnds: true)
        let muted = [proc(100, zoomID, input: false, output: true)]
        #expect(stopper.observe(muted, now: t0 + 45) == .ask)
        stopper.keepRecording(now: t0 + 50)
        for second in stride(from: 51, through: 1_200, by: 3) {
            #expect(stopper.observe(muted, now: t0 + Double(second)) == .keepRecording)
        }
        #expect(stopper.observe([proc(100, zoomID)], now: t0 + 1_210) == .keepRecording)
        #expect(!stopper.kept)
        #expect(stopper.observe(muted, now: t0 + 1_255) == .ask)
        #expect(stopper.observe(muted, now: t0 + 1_510) == .stop, "unanswered, it gives up after 5 minutes again")
    }

    @Test func keepRecordingStillStopsWhenTheCallEnds() {
        var stopper = policy(eventEnd: t0 + 600)
        stopper.keepRecording(now: t0 + 45)
        #expect(stopper.observe([proc(100, zoomID, input: false)], now: t0 + 400) == .keepRecording)
        #expect(stopper.observe([proc(100, zoomID, input: false)], now: t0 + 600) == .stop)
    }

    @Test func inputComingBackResetsTheTimer() {
        var stopper = policy()
        let quiet = [proc(100, zoomID, input: false, output: true)]
        #expect(stopper.observe(quiet, now: t0 + 50) == .ask)
        #expect(stopper.observe([proc(100, zoomID)], now: t0 + 60) == .keepRecording)
        #expect(stopper.observe(quiet, now: t0 + 104) == .keepRecording)
        #expect(stopper.observe(quiet, now: t0 + 105) == .ask)
    }

    @Test func anyProcessOfTheSameAppCounts() {
        var stopper = policy()
        let helper = [proc(300, zoomID, input: true, output: true)]
        #expect(stopper.observe(helper, now: t0 + 200) == .keepRecording)
        #expect(stopper.observe([proc(400, "com.spotify.client", input: true)], now: t0 + 245) == .stop)
    }

    @Test func theRulesAsAPureFunction() {
        func decide(idle: TimeInterval, gone: Bool = false, outputIdle: Bool = false, ended: Bool = false,
                    byEarshot: Bool = true, stopOn: Bool = true) -> AutoStopPolicy.Decision {
            AutoStopPolicy.decide(inputIdleFor: idle, processGone: gone, outputIdle: outputIdle, eventEnded: ended,
                                  startedByEarshot: byEarshot, stopWhenCallEnds: stopOn)
        }
        #expect(decide(idle: 44, gone: true) == .keepRecording)
        #expect(decide(idle: 45, gone: true) == .stop)
        #expect(decide(idle: 45, outputIdle: true) == .stop)
        #expect(decide(idle: 45, ended: true) == .stop)
        #expect(decide(idle: 45, ended: true, stopOn: false) == .ask)
        #expect(decide(idle: 45) == .ask)
        #expect(decide(idle: 300) == .stop)
        #expect(decide(idle: 300, stopOn: false) == .stop)
        #expect(decide(idle: 300, gone: true, stopOn: false) == .ask)
        #expect(decide(idle: 9_999, gone: true, byEarshot: false) == .keepRecording)
        #expect(AutoStopPolicy.idleAfter == 45 && AutoStopPolicy.giveUpAfter == 300)
    }
}

struct DetectRealMicrophoneTests {
    @Test func classifiesInputDevicesByTransport() {
        let real = CoreAudioProcessSource.isRealMicrophone
        #expect(real(kAudioDeviceTransportTypeBuiltIn, false))
        #expect(real(kAudioDeviceTransportTypeUSB, false))
        #expect(real(kAudioDeviceTransportTypeBluetooth, false))
        #expect(real(kAudioDeviceTransportTypeBluetoothLE, false))
        #expect(!real(kAudioDeviceTransportTypeVirtual, false))
        #expect(!real(kAudioDeviceTransportTypeAggregate, false))
        #expect(!real(kAudioDeviceTransportTypeAutoAggregate, false))
        #expect(!real(kAudioDeviceTransportTypeUnknown, false))
        #expect(real(kAudioDeviceTransportTypeVirtual, true))
    }

    @Test func checksEveryInputDeviceOfTheProcess() {
        let builtIn = (id: AudioObjectID(10), transport: kAudioDeviceTransportTypeBuiltIn)
        let virtual = (id: AudioObjectID(20), transport: kAudioDeviceTransportTypeVirtual)
        func uses(_ devices: [(id: AudioObjectID, transport: UInt32)], defaultInput: AudioObjectID? = 10,
                  running: Bool = false) -> Bool {
            CoreAudioProcessSource.usesRealMicrophone(inputDevices: devices, defaultInput: defaultInput,
                                                      defaultInputRunningSomewhere: running)
        }
        #expect(!uses([virtual]))
        #expect(uses([virtual, builtIn], defaultInput: nil))
        #expect(uses([virtual], defaultInput: 20))
        #expect(uses([], running: true))
        #expect(!uses([], running: false))
        #expect(!uses([], defaultInput: nil, running: true))
    }
}

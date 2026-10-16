import Foundation
import Testing
@testable import EarshotKit

/// What happens when a call is noticed, the notification routes, and which app the screen reader follows (spec 7, 9).
extension StartTests {
    static let zoom = CallEvent.Call(pid: 42, bundleID: "us.zoom.xos", appName: "zoom.us", isDedicated: true)
    static let chrome = CallEvent.Call(pid: 77, bundleID: "com.google.Chrome.helper", appName: "Google Chrome",
                                       isDedicated: false)

    static func callSettings(_ change: (inout EarshotSettings) -> Void = { _ in }) -> EarshotSettings {
        var settings = EarshotSettings()
        settings.noticeCalls = true
        change(&settings)
        return settings
    }

    @Suite struct CallResponseTests {
        @Test func theDefaultIsToAskByNotification() {
            let response = CallResponse.decide(StartTests.zoom, settings: StartTests.callSettings(), event: nil,
                                               notificationsAuthorized: true)
            #expect(response == .askByNotification)
        }

        @Test func withoutNotificationsTheChoiceIsShownInTheApp() {
            let response = CallResponse.decide(StartTests.zoom, settings: StartTests.callSettings(), event: nil,
                                               notificationsAuthorized: false)
            #expect(response == .askInApp)
        }

        @Test func autoRecordStartsDedicatedAppsAndBrowsersOnlyWithAVideoLink() {
            let auto = StartTests.callSettings { $0.autoRecordCalls = true }
            #expect(CallResponse.decide(StartTests.zoom, settings: auto, event: nil, notificationsAuthorized: true) == .autoRecord)
            #expect(CallResponse.decide(StartTests.chrome, settings: auto, event: nil, notificationsAuthorized: true)
                == .askByNotification)
            let meet = StartTests.event(url: "https://meet.google.com/abc-defg-hij")
            #expect(CallResponse.decide(StartTests.chrome, settings: auto, event: meet, notificationsAuthorized: true)
                == .autoRecord)
        }

        @Test func autoRecordNeedsAWayToReachTheUser() {
            let noPanel = StartTests.callSettings {
                $0.autoRecordCalls = true
                $0.showLivePanel = false
            }
            #expect(CallResponse.decide(StartTests.zoom, settings: noPanel, event: nil, notificationsAuthorized: false)
                == .askInApp)
            let panel = StartTests.callSettings { $0.autoRecordCalls = true }
            #expect(CallResponse.decide(StartTests.zoom, settings: panel, event: nil, notificationsAuthorized: false)
                == .autoRecord)
        }

        @Test func nothingHappensWithNoticeCallsOff() {
            let off = StartTests.callSettings {
                $0.noticeCalls = false
                $0.autoRecordCalls = true
            }
            #expect(CallResponse.decide(StartTests.zoom, settings: off, event: nil, notificationsAuthorized: true) == .ignore)
        }
    }

    @Suite struct CallPromptTests {
        @Test func theWordsMatchTheSpecAndHaveNoDashes() {
            #expect(CallTexts.ask("zoom.us") == "zoom.us is using your microphone. Record this call?")
            #expect(CallTexts.recording("zoom.us") == "Recording your zoom.us call")
            #expect(CallTexts.askToStop == "The call seems to have ended. Stop recording?")
            #expect(CallTexts.consentTitle == "Recording. Let everyone know.")
            let all = [CallTexts.ask("A"), CallTexts.recording("A"), CallTexts.askToStop, CallTexts.consentTitle]
                + NotificationRoute.Action.allCases.map(\.title)
            #expect(all.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("\u{2013}") })
        }

        @Test func aPromptExpiresAfterTheQuietPeriod() {
            let prompt = CallPrompt(id: "p1", kind: .record, call: StartTests.zoom, sessionID: nil, createdAt: at1530)
            #expect(prompt.isCurrent(now: at1530.addingTimeInterval(CallPrompt.lifetime - 1)))
            #expect(!prompt.isCurrent(now: at1530.addingTimeInterval(CallPrompt.lifetime)))
            #expect(prompt.text == CallTexts.ask("zoom.us"))
            let stop = CallPrompt(id: "p2", kind: .stop, call: StartTests.zoom, sessionID: "s1", createdAt: at1530)
            #expect(stop.text == CallTexts.askToStop)
        }
    }

    @Suite struct CallMatchTests {
        static func info(_ pid: Int32, _ bundle: String?, input: Bool = true, real: Bool = true) -> AudioProcessInfo {
            AudioProcessInfo(pid: pid, bundleID: bundle, runningInput: input, runningOutput: true, usesRealMicrophone: real)
        }

        @Test func findsTheCallAppUsingTheRealMicrophoneDedicatedFirst() {
            let snapshot = [Self.info(9, "com.google.Chrome.helper"), Self.info(42, "us.zoom.xos"),
                            Self.info(5, "com.apple.Music"), Self.info(1, "us.zoom.xos", input: false)]
            let call = CallMatch.activeCall(snapshot, runningApps: ["us.zoom.xos": "zoom.us"], ownPID: 1000)
            #expect(call == StartTests.zoom)
        }

        @Test func ignoresVirtualInputItselfAndAppsOffTheList() {
            #expect(CallMatch.activeCall([Self.info(42, "us.zoom.xos", real: false)], runningApps: [:], ownPID: 1) == nil)
            #expect(CallMatch.activeCall([Self.info(1, "us.zoom.xos")], runningApps: [:], ownPID: 1) == nil)
            #expect(CallMatch.activeCall([Self.info(3, "com.apple.Music"), Self.info(4, nil)], runningApps: [:], ownPID: 1) == nil)
        }
    }

    @Suite struct ScreenReadingTests {
        @Test func runsOnlyWhenTurnedOnAndAllowed() {
            var settings = EarshotSettings()
            #expect(!ScreenReading.shouldRun(settings: settings, hasPermission: true))
            settings.readScreen = true
            #expect(!ScreenReading.shouldRun(settings: settings, hasPermission: false))
            #expect(ScreenReading.shouldRun(settings: settings, hasPermission: true))
        }

        @Test func followsTheCallAppByItsPrefix() {
            #expect(ScreenReading.appPrefix(for: StartTests.zoom) == "us.zoom.")
            #expect(ScreenReading.appPrefix(for: StartTests.chrome) == "com.google.Chrome")
            let safari = CallEvent.Call(pid: 3, bundleID: "com.apple.WebKit.GPU", appName: "Safari", isDedicated: false)
            #expect(ScreenReading.appPrefix(for: safari) == "com.apple.Safari")
            #expect(ScreenReading.appPrefix(for: nil) == nil)
        }

        @Test func optionsComeFromSettings() {
            var settings = EarshotSettings()
            settings.screenWholeDisplay = true
            settings.keepScreenshots = true
            let options = ScreenReading.options(settings: settings)
            #expect(options.wholeDisplay && options.keepImages)
            #expect(options.interval == .seconds(15))
            #expect(options.maxWidth == 1440)
        }
    }

    @Suite struct NotificationRouteTests {
        typealias Route = NotificationRoute

        @Test func eachCategoryHasItsButtons() {
            #expect(Route.Category.callNotice.actions == [.record, .notNow])
            #expect(Route.Category.callRecording.actions == [.stop])
            #expect(Route.Category.callEnded.actions == [.stop, .keepRecording])
            #expect(Route.Category.consent.actions == [.copyLine])
            #expect(Route.Action.copyLine.title == "Copy consent line")
            #expect(Route.Action.record.title == "Record")
            #expect(Route.Action.notNow.title == "Not now")
        }

        @Test func buttonsBecomeCommands() {
            let prompt = [Route.Key.prompt: "p1", Route.Key.session: "s1"]
            #expect(Route.command(category: Route.Category.callNotice.rawValue, action: Route.Action.record.rawValue,
                                  userInfo: prompt) == .record(prompt: "p1"))
            #expect(Route.command(category: Route.Category.callNotice.rawValue, action: Route.Action.notNow.rawValue,
                                  userInfo: prompt) == .dismiss(prompt: "p1"))
            #expect(Route.command(category: Route.Category.callEnded.rawValue, action: Route.Action.stop.rawValue,
                                  userInfo: prompt) == .stop(session: "s1"))
            #expect(Route.command(category: Route.Category.callEnded.rawValue,
                                  action: Route.Action.keepRecording.rawValue, userInfo: prompt) == .dismiss(prompt: "p1"))
            #expect(Route.command(category: Route.Category.callRecording.rawValue, action: Route.Action.stop.rawValue,
                                  userInfo: [Route.Key.session: "s1"]) == .stop(session: "s1"))
            #expect(Route.command(category: Route.Category.consent.rawValue, action: Route.Action.copyLine.rawValue,
                                  userInfo: [:]) == .copyConsentLine)
        }

        @Test func clickingTheNotificationItselfIsSafe() {
            let click = "com.apple.UNNotificationDefaultActionIdentifier"
            #expect(Route.command(category: "", action: click, userInfo: [Route.Key.path: "/x/notes.md"]) == .open(path: "/x/notes.md"))
            #expect(Route.command(category: Route.Category.consent.rawValue, action: click, userInfo: [:]) == .copyConsentLine)
            // Never records or stops without the button.
            #expect(Route.command(category: Route.Category.callNotice.rawValue, action: click,
                                  userInfo: [Route.Key.prompt: "p1"]) == .none)
            #expect(Route.command(category: Route.Category.callRecording.rawValue, action: click,
                                  userInfo: [Route.Key.session: "s1"]) == .none)
        }

        @Test func aButtonWithoutItsIDDoesNothing() {
            #expect(Route.command(category: Route.Category.callNotice.rawValue, action: Route.Action.record.rawValue,
                                  userInfo: [:]) == .none)
            #expect(Route.command(category: Route.Category.callRecording.rawValue, action: Route.Action.stop.rawValue,
                                  userInfo: [:]) == .none)
            #expect(Route.command(category: "other", action: Route.Action.record.rawValue,
                                  userInfo: [Route.Key.prompt: "p1"]) == .none)
        }
    }
}

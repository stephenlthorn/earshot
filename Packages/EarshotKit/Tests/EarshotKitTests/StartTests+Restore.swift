import Foundation
import Testing
@testable import EarshotKit

extension StartTests {
    /// A mode preselected for a calendar event gives way to the user's default once the event is over, unless the user
    /// changed it since (spec 5.3).
    @Suite struct PreselectRestoreTests {
        static func settings(_ change: (inout EarshotSettings) -> Void = { _ in }) -> EarshotSettings {
            StartTests.settings {
                $0.defaultMode = .record
                $0.externalMode = .notes
                change(&$0)
            }
        }

        @Test func theDefaultComesBackWhenTheEventEndsAndTheModeWasLeftAlone() {
            var tracker = CurrentEventTracker()
            let settings = Self.settings()
            #expect(tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: true,
                                    currentMode: .record) == .notes)
            #expect(tracker.preselectedMode == .notes)
            // Still current: nothing changes.
            #expect(tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: true,
                                    currentMode: .notes) == nil)
            #expect(tracker.observe(nil, settings: settings, now: at1530.addingTimeInterval(3600), canPreselect: true,
                                    currentMode: .notes) == .record)
            #expect(tracker.preselectedMode == nil)
            // Once restored, it never restores again.
            #expect(tracker.observe(nil, settings: settings, now: at1530.addingTimeInterval(3700), canPreselect: true,
                                    currentMode: .notes) == nil)
        }

        @Test func aModeTheUserChoseStays() {
            var tracker = CurrentEventTracker()
            let settings = Self.settings()
            _ = tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: true,
                                currentMode: .record)
            #expect(tracker.observe(nil, settings: settings, now: at1530.addingTimeInterval(3600), canPreselect: true,
                                    currentMode: .notesAndDo) == nil)
            #expect(tracker.preselectedMode == nil)
            // Changing it back later is the user's choice too.
            #expect(tracker.observe(nil, settings: settings, now: at1530.addingTimeInterval(3700), canPreselect: true,
                                    currentMode: .notes) == nil)
        }

        @Test func duringARecordingItWaitsForTheNextIdleRead() {
            var tracker = CurrentEventTracker()
            let settings = Self.settings()
            _ = tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: true,
                                currentMode: .record)
            #expect(tracker.observe(nil, settings: settings, now: at1530.addingTimeInterval(3600), canPreselect: false,
                                    currentMode: .notes) == nil)
            #expect(tracker.preselectedMode == .notes)
            #expect(tracker.observe(nil, settings: settings, now: at1530.addingTimeInterval(3660), canPreselect: true,
                                    currentMode: .notes) == .record)
        }

        @Test func aPreselectionThatIsAlreadyTheDefaultChangesNothing() {
            var tracker = CurrentEventTracker()
            let settings = Self.settings { $0.defaultMode = .notes }
            #expect(tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: true,
                                    currentMode: .notes) == .notes)
            #expect(tracker.observe(nil, settings: settings, now: at1530.addingTimeInterval(3600), canPreselect: true,
                                    currentMode: .notes) == nil)
            #expect(tracker.preselectedMode == nil)
        }

        @Test func theNextEventPreselectsItsOwnMode() {
            var tracker = CurrentEventTracker()
            let settings = Self.settings { $0.internalMode = .record }
            _ = tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: true,
                                currentMode: .record)
            let next = StartTests.event("evt-2", people: [Attendee(name: "Ana", email: "ana@thorn.example")])
            #expect(tracker.observe(next, settings: settings, now: at1530, canPreselect: true,
                                    currentMode: .notes) == .record)
            #expect(tracker.preselectedMode == .record)
        }

        @Test func withoutTheCurrentModeNothingIsRestored() {
            var tracker = CurrentEventTracker()
            let settings = Self.settings()
            _ = tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: true)
            #expect(tracker.observe(nil, settings: settings, now: at1530.addingTimeInterval(3600),
                                    canPreselect: true) == nil)
        }

        @Test func turningTheCalendarOffRestoresTheDefaultToo() {
            var tracker = CurrentEventTracker()
            let settings = Self.settings()
            _ = tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: true,
                                currentMode: .record)
            #expect(tracker.modeToRestore(currentMode: .notes, settings: settings) == .record)
            #expect(tracker.modeToRestore(currentMode: .notesAndDo, settings: settings) == nil)
            tracker.reset()
            #expect(tracker.modeToRestore(currentMode: .notes, settings: settings) == nil)
        }

        @Test func turningTheCalendarOffWhileIdleRestoresAtOnce() {
            var tracker = CurrentEventTracker()
            let settings = Self.settings()
            _ = tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: true,
                                currentMode: .record)
            #expect(tracker.calendarTurnedOff(currentMode: .notes, settings: settings, canRestore: true) == .record)
            #expect(tracker.event == nil)
            #expect(tracker.preselectedID == nil)
            #expect(tracker.preselectedMode == nil)
        }

        @Test func turningTheCalendarOffDuringARecordingRestoresWhenItEnds() {
            var tracker = CurrentEventTracker()
            let settings = Self.settings()
            _ = tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: true,
                                currentMode: .record)
            #expect(tracker.calendarTurnedOff(currentMode: .notes, settings: settings, canRestore: false) == nil)
            #expect(tracker.event == nil)
            #expect(tracker.preselectedMode == .notes)
            // The recording ended: the next idle point restores, once.
            #expect(tracker.restoreDefault(currentMode: .notes, settings: settings) == .record)
            #expect(tracker.preselectedMode == nil)
            #expect(tracker.restoreDefault(currentMode: .notes, settings: settings) == nil)
        }

        @Test func aModeChangedDuringTheRecordingStaysWhenItEnds() {
            var tracker = CurrentEventTracker()
            let settings = Self.settings()
            _ = tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: true,
                                currentMode: .record)
            _ = tracker.calendarTurnedOff(currentMode: .notes, settings: settings, canRestore: false)
            #expect(tracker.restoreDefault(currentMode: .notesAndDo, settings: settings) == nil)
            #expect(tracker.preselectedMode == nil)
        }

        @Test func aModeTheUserChoseBeforeTheEventStaysAfterIt() {
            var tracker = CurrentEventTracker()
            let settings = Self.settings()
            // Default Record; the user picked Notes by hand before an External event whose mode is Notes.
            #expect(tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: true,
                                    currentMode: .notes) == .notes)
            #expect(tracker.preselectedMode == nil)
            #expect(tracker.observe(nil, settings: settings, now: at1530.addingTimeInterval(3600), canPreselect: true,
                                    currentMode: .notes) == nil)
        }

        @Test func aModeLeftAsTheLastEventSetItCarriesOverToTheNext() {
            var tracker = CurrentEventTracker()
            let settings = Self.settings()
            _ = tracker.observe(StartTests.event(), settings: settings, now: at1530, canPreselect: true,
                                currentMode: .record)
            // A second External event with the same mode follows straight on; the user never touched the mode.
            let next = StartTests.event("evt-2")
            #expect(tracker.observe(next, settings: settings, now: at1530, canPreselect: true,
                                    currentMode: .notes) == .notes)
            #expect(tracker.preselectedMode == .notes)
            #expect(tracker.observe(nil, settings: settings, now: at1530.addingTimeInterval(3600), canPreselect: true,
                                    currentMode: .notes) == .record)
        }
    }

    /// The live panel's brief card (spec 4.5): collapsed for External meetings, following the profile until the user
    /// opens or closes it by hand.
    @Suite struct BriefCardExpansionTests {
        @Test func externalStartsCollapsedAndOthersOpen() {
            #expect(!BriefCardExpansion(profile: .external).expanded)
            #expect(BriefCardExpansion(profile: .internal).expanded)
            #expect(BriefCardExpansion(profile: .noEvent).expanded)
            #expect(BriefCardExpansion(profile: nil).expanded)
        }

        @Test func aProfileSavedAfterTheStartIsFollowed() {
            var card = BriefCardExpansion(profile: nil)
            card.profileKnown(.external)
            #expect(!card.expanded)
            card.profileKnown(.internal)
            #expect(card.expanded)
        }

        @Test func aChoiceByHandWins() {
            var card = BriefCardExpansion(profile: nil)
            card.toggle()
            #expect(!card.expanded)
            #expect(card.setByHand)
            card.profileKnown(.internal)
            #expect(!card.expanded)
            var opened = BriefCardExpansion(profile: .external)
            opened.toggle()
            opened.profileKnown(.external)
            #expect(opened.expanded)
        }
    }
}

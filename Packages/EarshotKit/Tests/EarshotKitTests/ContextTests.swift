import EventKit
import Foundation
import Testing
@testable import EarshotKit

/// Calendar, profile, history, confirm and consent rules (spec 5 and 7.4). Each nested suite covers one type.
struct ContextTests {
    static let me = Attendee(name: "Stephen Thorn", email: "stephen@thorn.example", isMe: true)
    static let dana = Attendee(name: "Dana Smith", email: "dana@acme.com")
    static let priya = Attendee(name: "Priya Rao", email: "priya@thorn.example")

    /// An event starting `minutes` after 15:30 and lasting `length` minutes.
    static func event(_ id: String, minutes: Double = 0, length: Double = 30, people: [Attendee] = [],
                      agenda: String = "", location: String? = nil, url: String? = nil) -> CalendarEventInfo {
        let start = at1530.addingTimeInterval(minutes * 60)
        return CalendarEventInfo(id: id, title: "Event \(id)", start: start, end: start.addingTimeInterval(length * 60),
                                 attendees: people, agenda: agenda, location: location, url: url)
    }
}

/// A calendar with fixed events and a fixed authorization; it records the windows it was asked for.
private final class FakeCalendar: CalendarSource, @unchecked Sendable {
    let status: CalendarAuthorization
    let stored: [CalendarEventInfo]
    private let asked = Locked<[(Date, Date)]>([])

    init(_ status: CalendarAuthorization = .fullAccess, events: [CalendarEventInfo]) {
        self.status = status
        stored = events
    }

    var windows: [(Date, Date)] { asked.get }

    func authorization() async -> CalendarAuthorization { status }
    func requestAccess() async -> CalendarAuthorization { status }
    func events(from start: Date, to end: Date) async -> [CalendarEventInfo] {
        asked.update { $0.append((start, end)) }
        return status.canRead ? stored.filter { $0.end > start && $0.start < end } : []
    }
}

extension ContextTests {
    struct CurrentEventTests {
        @Test func onlyEventsOverlappingNowOrStartingWithinTenMinutesCount() {
            let past = event("past", minutes: -60, length: 30)
            let endsNow = event("endsNow", minutes: -30, length: 30)
            let soon = event("soon", minutes: 10)
            let later = event("later", minutes: 11)
            #expect(CurrentEvent.pick([past, endsNow, later], now: at1530) == nil)
            #expect(CurrentEvent.pick([past, soon, later], now: at1530)?.id == "soon")
            #expect(CurrentEvent.pick([event("running", minutes: -20)], now: at1530)?.id == "running")
        }

        @Test func prefersOtherAttendeesThenAVideoLinkThenTheClosestStart() {
            let solo = event("solo", minutes: 0, url: "https://zoom.us/j/1")
            let withPeople = event("people", minutes: -25, people: [me, dana])
            #expect(CurrentEvent.pick([solo, withPeople], now: at1530)?.id == "people")

            let plain = event("plain", minutes: 0, people: [me, dana])
            let video = event("video", minutes: -20, people: [me, dana], location: "https://meet.google.com/abc-defg-hij")
            #expect(CurrentEvent.pick([plain, video], now: at1530)?.id == "video")

            let early = event("early", minutes: -15, people: [me, dana])
            let close = event("close", minutes: 5, people: [me, dana])
            #expect(CurrentEvent.pick([early, close], now: at1530)?.id == "close")
            #expect(CurrentEvent.pick([close, early], now: at1530)?.id == "close")
        }

        @Test func meOnlyDoesNotCountAsOtherAttendees() {
            let justMe = event("me", minutes: 0, people: [me])
            let other = event("other", minutes: -25, people: [me, dana])
            #expect(CurrentEvent.pick([justMe, other], now: at1530)?.id == "other")
        }

        @Test func fetchReadsTwelveHoursEitherSideAndPicks() async {
            let calendar = FakeCalendar(events: [event("a", minutes: -120), event("b", minutes: 3, people: [me, dana])])
            #expect(await CurrentEvent.fetch(from: calendar, now: at1530)?.id == "b")
            let window = try! #require(calendar.windows.first)
            #expect(window.0 == at1530.addingTimeInterval(-12 * 3600) && window.1 == at1530.addingTimeInterval(12 * 3600))
            #expect(CurrentEvent.pollInterval == 60)
        }

        @Test func withoutAccessThereIsNoEventAndNoRead() async {
            let calendar = FakeCalendar(.denied, events: [event("a")])
            #expect(await CurrentEvent.fetch(from: calendar, now: at1530) == nil)
            #expect(calendar.windows.isEmpty)
            #expect(CalendarAuthorization.fullAccess.canRead)
            #expect(!CalendarAuthorization.writeOnly.canRead && !CalendarAuthorization.notDetermined.canRead)
        }

        @Test func aDifferentEventIsNewOnceSoTheModeIsPreselectedOnce() {
            let a = event("a")
            #expect(CurrentEvent.isNew(a, previousID: nil))
            #expect(!CurrentEvent.isNew(a, previousID: "a"))
            #expect(CurrentEvent.isNew(event("b"), previousID: "a"))
            #expect(!CurrentEvent.isNew(nil, previousID: "a"))
        }

        @Test func theMenuLineNamesTheEventAndItsProfile() {
            var a = event("a")
            a.title = "Acme pricing"
            #expect(CurrentEvent.menuLine(a, profile: .external) == "Now: Acme pricing · External")
            #expect(CurrentEvent.menuLine(a, profile: .internal) == "Now: Acme pricing · Internal")
            #expect(CurrentEvent.menuLine(a, profile: .noEvent) == "Now: Acme pricing")
            a.title = "  "
            #expect(CurrentEvent.menuLine(a, profile: .noEvent) == "Now: Untitled event")
        }

        @Test func theEventTitleIsUsedWhenTitleIsLeftBlank() {
            var a = event("a")
            a.title = " Acme pricing "
            #expect(CurrentEvent.meetingTitle(typed: "", event: a) == "Acme pricing")
            #expect(CurrentEvent.meetingTitle(typed: nil, event: a) == "Acme pricing")
            #expect(CurrentEvent.meetingTitle(typed: " Mine ", event: a) == "Mine")
            #expect(CurrentEvent.meetingTitle(typed: "  ", event: nil) == nil)
        }

        @Test func anEventTitleIsCleanedLikeAnAgenda() {
            var a = event("a")
            a.title = "Intro call with dana.smith@acme.com"
            #expect(CurrentEvent.meetingTitle(typed: nil, event: a) == "Intro call with [address at acme.com]")
            a.title = "Sync https://zoom.us/j/8123456789?pwd=Xy12"
            #expect(CurrentEvent.meetingTitle(typed: "", event: a) == "Sync [link]")
            // A passcode line is dropped whole, so nothing is left and the meeting has no title from the event.
            a.title = "Zoom https://zoom.us/j/8123456789?pwd=Xy12 passcode 4411"
            #expect(CurrentEvent.meetingTitle(typed: nil, event: a) == nil)
            a.title = "Line one\nLine two"
            #expect(CurrentEvent.eventTitle(a) == "Line one Line two")
            // What the user typed is their own and is kept as typed.
            #expect(CurrentEvent.meetingTitle(typed: "Call with Dana", event: a) == "Call with Dana")
        }

        @Test func storageClipsToFiftyAttendeesAndTheAgendaTo1500() {
            let people = (0..<80).map { Attendee(name: "P\($0)", email: "p\($0)@acme.com") }
            let big = CalendarEventInfo(id: "x", title: "Big", start: at1530, end: at1530, attendees: people,
                                        agenda: String(repeating: "a", count: 3000))
            #expect(big.attendees.count == 50 && big.agenda.count == 1500)
        }
    }
}

extension ContextTests {
    struct EventKitSourceTests {
        typealias Snapshot = EventKitCalendarSource.Snapshot
        typealias Participant = EventKitCalendarSource.Snapshot.Participant

        static func person(_ name: String, _ address: String?, me: Bool = false, type: EKParticipantType = .person,
                           status: EKParticipantStatus = .accepted) -> Participant {
            Participant(name: name, url: URL(string: address.map { "mailto:\($0)" } ?? "https://acme.com/people/\(name)")!,
                        isCurrentUser: me, type: type, status: status)
        }

        static func snapshot(allDay: Bool = false, status: EKEventStatus = .confirmed, attendees: [Participant] = [],
                             organizer: Participant? = nil) -> Snapshot {
            Snapshot(itemID: "item-1", title: "Acme pricing", start: at1530, end: at1530.addingTimeInterval(1800),
                     isAllDay: allDay, status: status, attendees: attendees, organizer: organizer, notes: "Agenda",
                     location: "Room 4", url: URL(string: "https://zoom.us/j/1"))
        }

        @Test func declinedAllDayAndCancelledEventsAreSkipped() throws {
            let me = Self.person("Stephen Thorn", "stephen@thorn.example", me: true)
            let dana = Self.person("Dana Smith", "dana@acme.com")
            let info = try #require(EventKitCalendarSource.info(Self.snapshot(attendees: [me, dana])))
            #expect(info.title == "Acme pricing" && info.agenda == "Agenda" && info.location == "Room 4")
            #expect(info.url == "https://zoom.us/j/1" && info.start == at1530 && info.end == at1530.addingTimeInterval(1800))
            #expect(EventKitCalendarSource.info(Self.snapshot(allDay: true, attendees: [me, dana])) == nil)
            #expect(EventKitCalendarSource.info(Self.snapshot(status: .canceled, attendees: [me, dana])) == nil)
            let iDeclined = Self.person("Stephen Thorn", "stephen@thorn.example", me: true, status: .declined)
            #expect(EventKitCalendarSource.info(Self.snapshot(attendees: [iDeclined, dana])) == nil)
            // Someone else declining, or the organizer declining, never hides the event from the user.
            let danaDeclined = Self.person("Dana Smith", "dana@acme.com", status: .declined)
            #expect(EventKitCalendarSource.info(Self.snapshot(attendees: [me, danaDeclined], organizer: danaDeclined)) != nil)
            #expect(EventKitCalendarSource.info(Self.snapshot(attendees: [me, dana], organizer: iDeclined)) != nil)
        }

        @Test func roomsAreLeftOutAndAMissingOrganizerIsAdded() throws {
            let me = Self.person("Stephen Thorn", "stephen@thorn.example", me: true)
            let dana = Self.person("Dana Smith", "dana@acme.com")
            let room = Self.person("Room 4B", "room4b@resource.acme.com", type: .room)
            let projector = Self.person("Projector", "proj@resource.acme.com", type: .resource)
            let bob = Self.person("Bob Lee", "Bob@Globex.com")
            let info = try #require(EventKitCalendarSource.info(Self.snapshot(attendees: [me, dana, room, projector],
                                                                               organizer: bob)))
            #expect(info.attendees == [Attendee(name: "Bob Lee", email: "Bob@Globex.com"),
                                       Attendee(name: "Stephen Thorn", email: "stephen@thorn.example", isMe: true),
                                       Attendee(name: "Dana Smith", email: "dana@acme.com")])
            // An organizer already listed, in any case, is not added twice.
            let danaUpper = Self.person("Dana Smith", "DANA@acme.com")
            let listed = try #require(EventKitCalendarSource.info(Self.snapshot(attendees: [me, dana], organizer: danaUpper)))
            #expect(listed.attendees.count == 2)
            // Without other attendees there is no meeting to join, so the organizer (the user's own event) is not added.
            let solo = try #require(EventKitCalendarSource.info(Self.snapshot(organizer: bob)))
            #expect(solo.attendees.isEmpty)
        }

        @Test func aNonMailtoParticipantHasNoAddress() throws {
            let me = Self.person("Stephen Thorn", "stephen@thorn.example", me: true)
            let web = Self.person("Dana Smith", nil)
            let info = try #require(EventKitCalendarSource.info(Self.snapshot(attendees: [me, web], organizer: web)))
            #expect(info.attendees == [Attendee(name: "Stephen Thorn", email: "stephen@thorn.example", isMe: true),
                                       Attendee(name: "Dana Smith", email: nil)])
        }

        @Test func eachOccurrenceOfARecurringEventHasItsOwnID() throws {
            let first = try #require(EventKitCalendarSource.info(Self.snapshot()))
            var next = Self.snapshot()
            next.start = at1530.addingTimeInterval(7 * 86_400)
            next.end = next.start.map { $0.addingTimeInterval(1800) }
            let second = try #require(EventKitCalendarSource.info(next))
            #expect(first.id != second.id && first.id.hasPrefix("item-1") && !first.id.contains("@"))
            #expect(first.id == (try #require(EventKitCalendarSource.info(Self.snapshot()))).id)
            #expect(CurrentEvent.isNew(second, previousID: first.id))
        }

        @Test func aStoreMadeBeforeAccessChangedIsReplaced() {
            #expect(EventKitCalendarSource.needsNewStore(madeUnder: .notDetermined, now: .fullAccess))
            #expect(EventKitCalendarSource.needsNewStore(madeUnder: .denied, now: .fullAccess))
            #expect(!EventKitCalendarSource.needsNewStore(madeUnder: .fullAccess, now: .fullAccess))
            #expect(!EventKitCalendarSource.needsNewStore(madeUnder: nil, now: .fullAccess))
        }

        @Test func mailtoLinksGiveTheAddress() {
            #expect(EventKitCalendarSource.email(from: URL(string: "mailto:dana@acme.com")!) == "dana@acme.com")
            #expect(EventKitCalendarSource.email(from: URL(string: "MAILTO:Dana@Acme.com")!) == "Dana@Acme.com")
            #expect(EventKitCalendarSource.email(from: URL(string: "https://acme.com/dana")!) == nil)
        }
    }
}

extension ContextTests {
    /// Reads only the authorization status: requesting access would show the system prompt.
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["EARSHOT_DEVICE_TESTS"] == "1", "needs EARSHOT_DEVICE_TESTS=1"))
    struct EventKitDeviceTests {
        @Test func readsTheAuthorizationStatusWithoutAsking() async {
            let source = EventKitCalendarSource()
            let status = await source.authorization()
            #expect(CalendarAuthorization.allCases.contains(status))
            if !status.canRead { #expect(await source.events(from: at1530, to: at1530.addingTimeInterval(60)).isEmpty) }
        }
    }
}

extension ContextTests {
    struct VideoLinksTests {
        @Test func findsEachCallServiceInTheURLLocationOrNotes() {
            for link in ["https://us02web.zoom.us/j/123?pwd=x", "https://meet.google.com/abc-defg-hij",
                         "https://teams.microsoft.com/l/meetup-join/1", "https://teams.live.com/meet/9",
                         "https://acme.webex.com/meet/dana", "https://facetime.apple.com/join#v=1", "zoom.us/j/5"] {
                #expect(VideoLinks.contains(text: "Join: \(link)"), "\(link)")
            }
            #expect(VideoLinks.contains(event("u", url: "https://zoom.us/j/1")))
            #expect(VideoLinks.contains(event("l", location: "Zoom https://acme.zoom.us/j/9")))
            #expect(VideoLinks.contains(event("n", agenda: "Agenda\nJoin at meet.google.com/abc-defg-hij")))
        }

        @Test func lookalikesAndAddressesAreNotLinks() {
            for text in ["notzoom.us/j/1", "https://zoom.usa.com/x", "https://zoom.us.evil.example/j", "Room 4B",
                         "mail dana@zoom.us", "https://teams.microsoft.community/x", ""] {
                #expect(!VideoLinks.contains(text: text), "\(text)")
            }
            #expect(!VideoLinks.contains(event("plain", agenda: "Pricing review", location: "Room 4")))
        }
    }
}

extension ContextTests {
    struct AgendaSanitizerTests {
        @Test func linksBecomeLinkAndDialInLinesAreDropped() {
            let agenda = """
            Pricing review (see https://docs.acme.com/q4?id=1).
            Join Zoom Meeting
            https://us02web.zoom.us/j/8812345?pwd=abc
            Meeting ID: 881 2345
            Passcode: 991122
            Password 1234
            PIN: 4455#
            Dial-in: +1 646 555 0100
            Dial in by phone
            Deck at www.acme.com/deck, and the opinion pinboard.
            """
            let clean = AgendaSanitizer.clean(agenda)
            #expect(clean == """
            Pricing review (see [link]).
            Join Zoom Meeting
            [link]
            Deck at [link], and the opinion pinboard.
            """)
        }

        @Test func noAddressOrAtSignSurvives() {
            let clean = AgendaSanitizer.clean("Send it to dana@acme.com @ noon, cc ops@globex.io.\nmailto:x@y.com")
            #expect(!clean.contains("@"))
            #expect(clean == "Send it to [address at acme.com] at noon, cc [address at globex.io].\n[link]")
        }

        @Test func everyKindOfLineBreakSplitsTheAgenda() {
            let teams = "Q4 pricing\r\nMeeting ID: 1\r\nPasscode: x"
            #expect(AgendaSanitizer.clean(teams) == "Q4 pricing")
            #expect(AgendaSanitizer.hasContent(teams))
            #expect(AgendaSanitizer.clean("Goals\rPasscode: 2\u{2028}Next steps") == "Goals\nNext steps")
        }

        @Test func accentedAndSingleLabelAddressesLeaveNoLocalPart() {
            let clean = AgendaSanitizer.clean("Ask josé@acme.com, bob@intranet and Dana.O\u{2019}Brien@acme.com. Also ana@münchen.de")
            for part in ["josé", "bob", "Brien", "O\u{2019}", "ana", "@"] { #expect(!clean.contains(part), "\(part)") }
            #expect(clean == "Ask [address at acme.com], [address at intranet] and [address at acme.com]. Also [address at münchen.de]")
            for odd in ["dana@.com", "dana@@acme.com", "x<dana@>y"] {
                let scrubbed = AgendaSanitizer.scrubAddresses(odd)
                #expect(!scrubbed.contains("@") && !scrubbed.contains("dana"), "\(odd) -> \(scrubbed)")
            }
            #expect(AgendaSanitizer.scrubAddresses("Lunch @ noon") == "Lunch at noon")
        }

        @Test func pinIsASecretOnlyAsAPinAndDialInCodesAreDropped() {
            let agenda = """
            Pin down Q4 price
            Pins for the booth
            PIN 4455
            pin: 7788
            Phone conference ID: 123 456#
            Access code: 2468
            Access-codes are on the card
            """
            #expect(AgendaSanitizer.clean(agenda) == "Pin down Q4 price\nPins for the booth")
        }

        @Test func blankRunsCollapseAndTheResultIsTrimmed() {
            #expect(AgendaSanitizer.clean("\n\n  Goals\n\n\n\nPasscode: 1\n\nNext steps  \n\n") == "Goals\n\nNext steps")
            #expect(AgendaSanitizer.clean("Passcode: 1\nhttps://zoom.us/j/1") == "[link]")
            #expect(AgendaSanitizer.clean("") == "")
            #expect(!AgendaSanitizer.hasContent("Passcode: 1\nhttps://zoom.us/j/1\n\nwww.acme.com"))
            #expect(AgendaSanitizer.hasContent("Q4 pricing\nhttps://zoom.us/j/1"))
        }
    }
}

extension ContextTests {
    struct ProfileRulesTests {
        @Test func myDomainsAreMyAddressPlusTypedButNeverPersonal() {
            let event = CalendarEventInfo(id: "e", title: "t", start: at1530, end: at1530, attendees: [me, dana])
            #expect(ProfileRules.myDomains(event: event, typed: "") == ["thorn.example"])
            #expect(ProfileRules.myDomains(event: event, typed: " @Acme.com, globex.io;; gmail.com example ")
                    == ["thorn.example", "acme.com", "globex.io"])
            let gmailMe = Attendee(name: "Stephen", email: "stephen@gmail.com", isMe: true)
            let personal = CalendarEventInfo(id: "e", title: "t", start: at1530, end: at1530, attendees: [gmailMe, dana])
            #expect(ProfileRules.myDomains(event: personal, typed: "").isEmpty)
            for domain in ["gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com",
                           "live.com", "yahoo.com", "aol.com", "proton.me", "protonmail.com", "fastmail.com"] {
                #expect(ProfileRules.personalDomains.contains(domain))
            }
            var settings = EarshotSettings()
            settings.myDomains = "acme.com"
            #expect(ProfileRules.myDomains(event: nil, settings: settings) == ["acme.com"])
        }

        @Test func externalWhenAnyoneIsOutsideInternalWhenAllAreInside() {
            let mine: Set<String> = ["thorn.example"]
            func profile(_ people: [Attendee]) -> MeetingProfile {
                ProfileRules.profile(event: CalendarEventInfo(id: "e", title: "t", start: at1530, end: at1530,
                                                              attendees: [me] + people), myDomains: mine)
            }
            #expect(profile([priya]) == .internal)
            #expect(profile([Attendee(name: "Eng", email: "eng@eu.thorn.example")]) == .internal)
            #expect(profile([priya, dana]) == .external)
            #expect(profile([Attendee(name: "Friend", email: "friend@gmail.com")]) == .external)
            #expect(profile([Attendee(name: "No address")]) == .external)
            #expect(profile([]) == .noEvent)
            #expect(ProfileRules.profile(event: nil, myDomains: mine) == .noEvent)
            #expect(ProfileRules.profile(event: CalendarEventInfo(id: "e", title: "t", start: at1530, end: at1530,
                                                                  attendees: [me, priya]), myDomains: []) == .external)
        }

        @Test func modeFollowsTheProfileAndExternalNeedsADoTarget() {
            var settings = EarshotSettings()
            settings.defaultMode = .record
            #expect(ProfileRules.mode(profile: .external, settings: settings) == .notes)
            settings.webhookOn = true
            #expect(ProfileRules.mode(profile: .external, settings: settings) == .notesAndDo)
            settings.webhookOn = false
            settings.routineOn = true
            #expect(ProfileRules.mode(profile: .external, settings: settings) == .notesAndDo)
            settings.externalMode = .record
            #expect(ProfileRules.mode(profile: .external, settings: settings) == .record)
            #expect(ProfileRules.mode(profile: .internal, settings: settings) == .notes)
            settings.internalMode = .notesAndDo
            #expect(ProfileRules.mode(profile: .internal, settings: settings) == .notesAndDo)
            settings.routineOn = false
            #expect(ProfileRules.mode(profile: .internal, settings: settings) == .notes)
            #expect(ProfileRules.mode(profile: .noEvent, settings: settings) == .record)
        }

        @Test func styleIsSalesForExternalTitlesWithASalesKeyword() {
            var settings = EarshotSettings()
            settings.style = .brainDump
            #expect(ProfileRules.style(profile: .external, title: "Acme Demo: Q4", settings: settings) == .salesCall)
            #expect(ProfileRules.style(profile: .external, title: "Pricing follow-up", settings: settings) == .salesCall)
            #expect(ProfileRules.style(profile: .external, title: "Introduction to the team", settings: settings) == .general)
            #expect(ProfileRules.style(profile: .external, title: "Unquoted sync", settings: settings) == .general)
            #expect(ProfileRules.style(profile: .internal, title: "Sales pipeline", settings: settings) == .general)
            #expect(ProfileRules.style(profile: .noEvent, title: "Demo", settings: settings) == .brainDump)
            settings.salesKeywords = "renewal, Price check"
            #expect(ProfileRules.style(profile: .external, title: "Acme renewal", settings: settings) == .salesCall)
            #expect(ProfileRules.style(profile: .external, title: "Quick price-check", settings: settings) == .salesCall)
            #expect(ProfileRules.style(profile: .external, title: "Acme demo", settings: settings) == .general)
            #expect(ProfileRules.salesKeywords(EarshotSettings().salesKeywords)
                    == ["demo", "discovery", "intro", "proposal", "pricing", "sales", "pitch", "quote", "consult"])
        }

        @Test func contextAttendeesAreNamesOnlyWithTheirSide() {
            let ops = Attendee(name: "ops@globex.com", email: "ops@globex.com")
            let event = CalendarEventInfo(id: "e", title: "t", start: at1530, end: at1530, attendees: [me, priya, dana, ops])
            let people = ProfileRules.contextAttendees(event: event, myDomains: ["thorn.example"])
            #expect(people == [ContextAttendee(name: "Stephen Thorn", side: .me), ContextAttendee(name: "Priya Rao", side: .internal),
                               ContextAttendee(name: "Dana Smith", side: .external), ContextAttendee(name: "globex.com", side: .external)])
            #expect(!people.contains { $0.name.contains("@") })
            #expect(ProfileRules.contextAttendees(event: nil, myDomains: []).isEmpty)
            #expect(ProfileRules.label(.external) == "External" && ProfileRules.label(.internal) == "Internal")
        }
    }
}

extension ContextTests {
    struct MeetingHistoryTests {
        let h = LibraryHarness()

        private func session(_ title: String?, event: CalendarEventInfo?) throws -> Session {
            var s = try h.store.create(mode: .notes, title: title, now: at1530)
            s.calendarEvent = event
            return s
        }

        @Test func relatedUsesTheEventTheTitleAndLeavesTheMeetingItselfOut() throws {
            let event = LibraryHarness.event("Acme pricing", [("Dana Smith", "dana@acme.com")])
            let old = try h.meeting("Acme kickoff", daysAgo: 3, notes: LibraryHarness.notes("Acme kickoff"), event: event)
            try h.meeting("Other", daysAgo: 2, notes: LibraryHarness.notes("Other"))
            let tooOld = LibraryHarness.event("Acme old", [("Dana Smith", "dana@acme.com")])
            try h.meeting("Acme old", daysAgo: 181, notes: LibraryHarness.notes("Acme old"), event: tooOld)
            let current = try session(nil, event: event)
            try h.index.write(MeetingRecord.load(current, from: h.store), transcript: [], names: [:], userName: "Stephen")
            let found = MeetingHistory.related(to: current, library: h.library, now: at1530.addingTimeInterval(60))
            #expect(found.map(\.id) == [old.id])
        }

        @Test func aTypedTitleOrTheEventTitleLinksWhenNobodyElseIsInvited() throws {
            let old = try h.meeting("Q4 planning", daysAgo: 5, notes: LibraryHarness.notes("Q4 planning"))
            let alone = CalendarEventInfo(id: "x", title: "Q4 planning", start: at1530, end: at1530, attendees: [LibraryHarness.me])
            #expect(MeetingHistory.related(to: try session(nil, event: alone), library: h.library, now: at1530).map(\.id) == [old.id])
            #expect(MeetingHistory.related(to: try session("Q4 Planning!", event: nil), library: h.library, now: at1530).map(\.id) == [old.id])
            #expect(MeetingHistory.related(to: try session("  ", event: nil), library: h.library, now: at1530).isEmpty)
            #expect(MeetingHistory.related(to: try session("  ", event: alone), library: h.library, now: at1530).map(\.id) == [old.id])
            let generic = try h.meeting("Weekly sync", daysAgo: 1, notes: LibraryHarness.notes("Weekly sync"),
                                        event: LibraryHarness.event("Weekly sync", []))
            let syncEvent = CalendarEventInfo(id: "y", title: "Weekly sync", start: at1530, end: at1530, attendees: [LibraryHarness.me])
            #expect(!MeetingHistory.related(to: try session(nil, event: syncEvent), library: h.library, now: at1530)
                .map(\.id).contains(generic.id))
        }

        @Test func theUserNameKeepsTheirOwnAddressOutOnADelegatedCalendar() throws {
            // A delegated calendar lists the user as a plain attendee, not isMe.
            let user = Attendee(name: "Stephen Thorn", email: "stephen@thorn.example")
            let past = CalendarEventInfo(id: "p", title: "Globex intro", start: at1530, end: at1530,
                                         attendees: [user, Attendee(name: "Bob Lee", email: "bob@globex.com")])
            let unrelated = try h.meeting("Globex intro", daysAgo: 4, notes: LibraryHarness.notes("Globex intro"), event: past)
            let now = CalendarEventInfo(id: "n", title: "Acme pricing", start: at1530, end: at1530,
                                        attendees: [user, Attendee(name: "Dana Smith", email: "dana@acme.com")])
            let current = try session(nil, event: now)
            #expect(MeetingHistory.related(to: current, library: h.library, userName: "Stephen Thorn", now: at1530).isEmpty)
            // Without the name the user's own address links every meeting they were in, which is why callers pass it.
            #expect(MeetingHistory.related(to: current, library: h.library, now: at1530).map(\.id) == [unrelated.id])
        }

        @Test func atMostFiveNewestFirst() throws {
            let event = LibraryHarness.event("Acme", [("Dana Smith", "dana@acme.com")])
            for day in 1...7 { try h.meeting("Acme \(day)", daysAgo: Double(day), notes: LibraryHarness.notes("Acme \(day)"), event: event) }
            let found = MeetingHistory.related(to: try session(nil, event: event), library: h.library, now: at1530)
            #expect(found.map(\.title) == ["Acme 1", "Acme 2", "Acme 3", "Acme 4", "Acme 5"])
        }
    }
}

extension ContextTests {
    struct ConfirmPolicyTests {
        @Test func asksUnlessSendWithoutAskingAndTheMeetingIsInternalAndStartedByHand() throws {
            var settings = EarshotSettings()
            var session = try SessionStore(root: tempDir()).create(mode: .notesAndDo, title: "t", now: at1530)
            #expect(ConfirmPolicy.mustAsk(session: session, settings: settings))
            settings.sendWithoutAsking = true
            #expect(!ConfirmPolicy.mustAsk(session: session, settings: settings))
            session.profile = .internal
            #expect(!ConfirmPolicy.mustAsk(session: session, settings: settings))
            session.profile = .external
            #expect(ConfirmPolicy.mustAsk(session: session, settings: settings))
            session.profile = .noEvent
            session.startedBy = .auto
            #expect(ConfirmPolicy.mustAsk(session: session, settings: settings))
            for trigger in [StartTrigger.manual, .importFile] {
                session.startedBy = trigger
                #expect(!ConfirmPolicy.mustAsk(session: session, settings: settings))
            }
            // A meeting `earshot process` made always asks: an agent chose its sends, not the user.
            session.startedBy = .cli
            #expect(ConfirmPolicy.mustAsk(session: session, settings: settings))
        }
    }
}

extension ContextTests {
    struct ConsentPolicyTests {
        @Test func theLineAddsTheScreenSentenceOnlyWhenReadingTheScreen() {
            var settings = EarshotSettings()
            #expect(ConsentPolicy.line(settings: settings) == "Quick heads-up: I'm recording this call so an AI assistant can transcribe it and take notes. I'll share the notes afterwards.")
            settings.readScreen = true
            #expect(ConsentPolicy.line(settings: settings) == "Quick heads-up: I'm recording this call so an AI assistant can transcribe it and take notes. I'll share the notes afterwards. It also reads what's shared on screen.")
            settings.consentLine = "  Recording for notes, OK?  "
            #expect(ConsentPolicy.line(settings: settings) == "Recording for notes, OK? It also reads what's shared on screen.")
            settings.consentLine = "Recording. It also reads what's shared on screen."
            #expect(ConsentPolicy.line(settings: settings) == "Recording. It also reads what's shared on screen.")
            settings.consentLine = " "
            settings.readScreen = false
            #expect(ConsentPolicy.line(settings: settings) == EarshotSettings.defaultConsentLine)
            #expect(!ConsentPolicy.line(settings: settings).contains("\u{2014}"))
        }

        @Test func theBannerStaysUntilDismissedOnlyForAutomaticStarts() {
            #expect(ConsentPolicy.bannerPersists(startedBy: .auto))
            for trigger in [StartTrigger.manual, .importFile, .cli] { #expect(!ConsentPolicy.bannerPersists(startedBy: trigger)) }
            let shown = at1530
            #expect(ConsentPolicy.bannerVisible(startedBy: .manual, shownAt: shown, now: shown.addingTimeInterval(119), dismissed: false))
            #expect(!ConsentPolicy.bannerVisible(startedBy: .manual, shownAt: shown, now: shown.addingTimeInterval(120), dismissed: false))
            #expect(ConsentPolicy.bannerVisible(startedBy: .auto, shownAt: shown, now: shown.addingTimeInterval(3600), dismissed: false))
            #expect(!ConsentPolicy.bannerVisible(startedBy: .auto, shownAt: shown, now: shown, dismissed: true))
            #expect(!ConsentPolicy.bannerVisible(startedBy: .manual, shownAt: shown, now: shown, dismissed: true))
        }

        @Test func theReminderUsesThePanelOrANotificationWhenThePanelIsHidden() {
            var settings = EarshotSettings()
            #expect(ConsentPolicy.delivery(settings: settings, panelShown: true) == .banner)
            #expect(ConsentPolicy.delivery(settings: settings, panelShown: false) == .notification)
            settings.consentReminder = false
            #expect(ConsentPolicy.delivery(settings: settings, panelShown: true) == nil)
        }
    }
}

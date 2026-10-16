import Testing
@testable import EarshotKit

struct TranscriptTests {
    @Test func sortsByTimeAndJoinsCloseSegmentsFromOneSpeaker() {
        let merged = TranscriptMerger.merge([
            Segment(track: .them, start: 5, end: 7, text: "Sounds good."),
            Segment(track: .me, start: 0, end: 2, text: "Hi Dana."),
            Segment(track: .me, start: 2.5, end: 4, text: "Shall we start?"),
        ])
        #expect(merged.map(\.text) == ["Hi Dana. Shall we start?", "Sounds good."])
        #expect(merged[0].end == 4)
    }

    @Test func dropsMicEchoOfTheCall() {
        let merged = TranscriptMerger.merge([
            Segment(track: .them, start: 10, end: 14, text: "We can start the pilot on Monday."),
            Segment(track: .me, start: 10.2, end: 13.8, text: "we can start the pilot on monday"),
        ])
        #expect(merged.map(\.track) == [.them])
    }

    @Test func keepsMicSpeechThatOverlapsButSaysSomethingElse() {
        let merged = TranscriptMerger.merge([
            Segment(track: .them, start: 10, end: 14, text: "We can start the pilot on Monday."),
            Segment(track: .me, start: 12, end: 13, text: "Monday works for me."),
        ])
        #expect(merged.count == 2)
    }

    @Test func keepsMicSpeechWithTheSameWordsAtAnotherTime() {
        let merged = TranscriptMerger.merge([
            Segment(track: .them, start: 10, end: 12, text: "Thanks everyone."),
            Segment(track: .me, start: 40, end: 42, text: "Thanks everyone."),
        ])
        #expect(merged.count == 2)
    }

    @Test func appliesTrackOffsets() {
        let merged = TranscriptMerger.merge([Segment(track: .them, start: 0, end: 1, text: "Hello.")], offsets: [.them: 1.5])
        #expect(merged[0].start == 1.5 && merged[0].end == 2.5)
    }

    @Test func similarityIgnoresCaseAndPunctuation() {
        #expect(TranscriptMerger.similarity("Hello, world!", "hello world") == 1)
        #expect(TranscriptMerger.similarity("", "") == 0)
    }

    @Test func rendersTimestampsAndNames() {
        let text = TranscriptRenderer.markdown([
            Segment(track: .me, start: 3725.9, end: 3727, text: "Thanks."),
            Segment(track: .them, start: 3728, end: 3729, text: "Bye."),
        ], names: [.me: "Stephen"])
        #expect(text == "[01:02:05] Stephen: Thanks.\n[01:02:08] Them: Bye.\n")
    }

    @Test func emptyTranscriptRendersEmpty() {
        #expect(TranscriptRenderer.markdown([], names: [:]) == "")
    }
}

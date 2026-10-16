import AVFoundation
import CoreMedia
import Foundation
import Speech
import Testing
@testable import EarshotKit

private func segment(_ track: Track, _ start: Double, _ end: Double, _ text: String) -> Segment {
    Segment(track: track, start: start, end: end, text: text)
}

private func finalUpdate(_ track: Track, _ start: Double, _ end: Double, _ text: String) -> LiveUpdate {
    LiveUpdate(segment: segment(track, start, end, text), isFinal: true)
}

private func volatileUpdate(_ track: Track, _ start: Double, _ end: Double, _ text: String) -> LiveUpdate {
    LiveUpdate(segment: segment(track, start, end, text), isFinal: false)
}

private func host(_ seconds: Double) -> UInt64 { AVAudioTime.hostTime(forSeconds: seconds) }

private let analyzerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

/// Pushes 0.1 s tap buffers at the given host seconds and returns what the analyzer would get.
private func feed(base: UInt64?, at seconds: [Double], readyFirst: Bool = true) async -> [AnalyzerInput] {
    let feeder = LiveTranscriber.Feeder(track: .them, base: base)
    if readyFirst { feeder.ready(analyzerFormat) }
    for second in seconds { feeder.push(tapLikeBuffer(frames: 4_800, amplitude: 0.3), hostTime: host(second)) }
    if !readyFirst { feeder.ready(analyzerFormat) }
    await feeder.drain()
    feeder.end()
    var inputs: [AnalyzerInput] = []
    for await input in feeder.stream { inputs.append(input) }
    return inputs
}

private func startFrame(_ input: AnalyzerInput) -> Int64 { input.bufferStartTime?.value ?? -1 }

/// Each input starts exactly where the one before it ended.
private func contiguous(_ inputs: ArraySlice<AnalyzerInput>) -> Bool {
    zip(inputs, inputs.dropFirst()).allSatisfy { startFrame($0) + Int64($0.buffer.frameLength) == startFrame($1) }
}

struct LiveTranscriptionTests {
    // MARK: LiveTranscript

    @Test func finalsComeBackInTimeOrderWhateverOrderTheyArrived() async {
        let transcript = LiveTranscript()
        await transcript.apply(finalUpdate(.them, 10, 12, "Second"))
        await transcript.apply(finalUpdate(.me, 2, 4, "First"))
        await transcript.apply(finalUpdate(.them, 20, 22, "Fourth"))
        await transcript.apply(finalUpdate(.me, 13, 15, "Third"))
        #expect(await transcript.finals().map(\.text) == ["First", "Second", "Third", "Fourth"])
    }

    @Test func finalsSinceAnOffsetIncludeASegmentThatEndsAfterIt() async {
        let transcript = LiveTranscript()
        for update in [finalUpdate(.me, 0, 5, "a"), finalUpdate(.them, 8, 12, "b"), finalUpdate(.me, 11, 14, "c"), finalUpdate(.them, 20, 25, "d")] {
            await transcript.apply(update)
        }
        #expect(await transcript.finals(since: 12).map(\.text) == ["c", "d"])
        #expect(await transcript.finals(since: 0).map(\.text) == ["a", "b", "c", "d"])
        #expect(await transcript.finals(since: 25).isEmpty)
    }

    @Test func aFinalThatArrivesLateStillCountsAsNewWhateverItsTime() async {
        let transcript = LiveTranscript()
        await transcript.apply(finalUpdate(.them, 81, 85, "Them is done."))
        let first = await transcript.finals(after: 0)
        #expect(first.segments.map(\.text) == ["Them is done."] && first.cursor == 1)
        // Me spoke from 80 to 84, but that final only arrives after the pass that read up to 85.
        await transcript.apply(finalUpdate(.me, 80, 84, "Me was still talking."))
        await transcript.apply(finalUpdate(.them, 86, 88, "Next."))
        let second = await transcript.finals(after: first.cursor)
        #expect(second.segments.map(\.text) == ["Me was still talking.", "Next."])  // time order within the batch
        #expect(second.cursor == 3)
        #expect(await transcript.finals(after: second.cursor).segments.isEmpty)
        #expect(await transcript.finals(after: 99).cursor == 3)  // a cursor past the end is clamped
        // A repeat or an empty final never arrives, so it never moves the cursor.
        await transcript.apply(finalUpdate(.them, 86, 88, "Next."))
        await transcript.apply(finalUpdate(.me, 89, 90, " "))
        #expect(await transcript.finals(after: second.cursor).cursor == 3)
    }

    @Test func aWindowHoldsEverySegmentThatOverlapsIt() async {
        let transcript = LiveTranscript()
        for update in [finalUpdate(.me, 0, 5, "a"), finalUpdate(.them, 8, 12, "b"), finalUpdate(.me, 11, 14, "c"), finalUpdate(.them, 20, 25, "d")] {
            await transcript.apply(update)
        }
        #expect(await transcript.window(from: 10, to: 21).map(\.text) == ["b", "c", "d"])
        #expect(await transcript.window(from: 5, to: 8).isEmpty)  // touching edges don't overlap
        #expect(await transcript.window(from: 0, to: 100).count == 4)
    }

    @Test func aVolatileResultReplacesTheOneBeforeItForItsTrackOnly() async {
        let transcript = LiveTranscript()
        await transcript.apply(volatileUpdate(.me, 0, 1, "Hel"))
        await transcript.apply(volatileUpdate(.me, 0, 2, "Hello there"))
        await transcript.apply(volatileUpdate(.them, 1, 2, "Hi"))
        #expect(await transcript.volatileText(.me) == "Hello there")
        #expect(await transcript.volatileText(.them) == "Hi")
        #expect(await transcript.finals().isEmpty)
        #expect(await transcript.finalCharacters() == 0)
    }

    @Test func aFinalClearsTheVolatileTextItCovers() async {
        let transcript = LiveTranscript()
        await transcript.apply(volatileUpdate(.me, 0, 2, "Hello there"))
        await transcript.apply(volatileUpdate(.them, 0, 2, "Morning"))
        await transcript.apply(finalUpdate(.me, 0, 2.5, "Hello there."))
        #expect(await transcript.volatileText(.me) == "")
        #expect(await transcript.volatileText(.them) == "Morning")
        // A volatile tail that starts after the final ends is still being spoken, so it stays.
        await transcript.apply(volatileUpdate(.me, 3, 4, "and then"))
        await transcript.apply(finalUpdate(.me, 2.5, 3, "So."))
        #expect(await transcript.volatileText(.me) == "and then")
    }

    @Test func emptyResultsClearTheTickerButAreNeverKeptAsFinals() async {
        let transcript = LiveTranscript()
        await transcript.apply(volatileUpdate(.me, 0, 1, "Um"))
        await transcript.apply(volatileUpdate(.me, 0, 1, " "))
        #expect(await transcript.volatileText(.me) == "")
        await transcript.apply(volatileUpdate(.them, 0, 1, "Okay"))
        await transcript.apply(finalUpdate(.them, 0, 1, "  "))
        #expect(await transcript.volatileText(.them) == "")
        #expect(await transcript.finals().isEmpty)
    }

    @Test func finalTextIsTrimmedCountedAndNeverDoubled() async {
        let transcript = LiveTranscript()
        await transcript.apply(finalUpdate(.me, 0, 2, "  Send the deck. "))
        await transcript.apply(finalUpdate(.them, 3, 4, "Sure."))
        await transcript.apply(finalUpdate(.them, 3, 4, "Sure."))
        #expect(await transcript.finals().map(\.text) == ["Send the deck.", "Sure."])
        #expect(await transcript.finalCharacters() == "Send the deck.".count + "Sure.".count)
    }

    // MARK: Feeding the analyzer

    @Test func buffersFollowEachOtherByConvertedFrameCount() async {
        let inputs = await feed(base: host(1_000), at: (0..<500).map { 1_000 + Double($0) / 10 })  // 50 s
        #expect(inputs.count == 500)
        #expect(startFrame(inputs[0]) == 0)
        #expect(contiguous(inputs[...]))
        #expect(inputs.allSatisfy { $0.buffer.format == analyzerFormat && $0.bufferStartTime?.timescale == 16_000 })
        let total = inputs.reduce(0) { $0 + Int($1.buffer.frameLength) }
        // 50 s at 16 kHz. The converter holds back a short filter delay but never drifts: 20 ms at most.
        #expect(abs(total - 800_000) < 320)
    }

    @Test func aGapOverHalfASecondJumpsTheTimelineForward() async {
        let inputs = await feed(base: host(1_000), at: [1_000, 1_000.1, 1_000.2, 1_002.3, 1_002.4])
        #expect(contiguous(inputs[0..<3]))
        #expect(startFrame(inputs[3]) == 36_800)  // 2.3 s after the meeting's first buffer
        #expect(contiguous(inputs[3...]))
    }

    @Test func aShortGapDoesNotJump() async {
        let inputs = await feed(base: host(1_000), at: [1_000, 1_000.1, 1_000.2, 1_000.6])
        #expect(contiguous(inputs[...]))
    }

    @Test func aTrackThatStartsLaterStartsAtItsOffsetOnTheMeetingClock() async {
        let inputs = await feed(base: host(1_000), at: [1_001.5, 1_001.6])
        #expect(startFrame(inputs[0]) == 24_000)
        #expect(contiguous(inputs[...]))
    }

    @Test func withoutAFirstHostTimeTheFirstBufferIsTimeZero() async {
        let inputs = await feed(base: nil, at: [500, 500.1])
        #expect(startFrame(inputs[0]) == 0)
        #expect(contiguous(inputs[...]))
    }

    @Test func buffersThatArriveBeforeTheAnalyzerIsReadyAreKept() async {
        let inputs = await feed(base: host(1_000), at: [1_000, 1_000.1, 1_000.2], readyFirst: false)
        #expect(inputs.count == 3)
        #expect(startFrame(inputs[0]) == 0 && contiguous(inputs[...]))
    }

    @Test func aNewInputFormatAfterAMicRestartStillConverts() async {
        let feeder = LiveTranscriber.Feeder(track: .me, base: host(1_000))
        feeder.ready(analyzerFormat)
        feeder.push(tapLikeBuffer(frames: 4_800, amplitude: 0.3), hostTime: host(1_000))
        let mono = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!, frameCapacity: 4_410)!
        mono.frameLength = 4_410
        feeder.push(mono, hostTime: host(1_003))
        await feeder.drain()
        feeder.end()
        feeder.push(tapLikeBuffer(frames: 4_800, amplitude: 0.3), hostTime: host(1_003.1))  // after end: ignored
        var inputs: [AnalyzerInput] = []
        for await input in feeder.stream { inputs.append(input) }
        #expect(inputs.count == 2)
        #expect(startFrame(inputs[1]) == 48_000)
        #expect(inputs[1].buffer.format == analyzerFormat)
    }

    @Test func theJumpRule() {
        let rate = 16_000.0
        #expect(LiveTranscriber.Feeder.startFrame(next: 0, wall: 1.5, rate: rate, first: true) == 24_000)
        #expect(LiveTranscriber.Feeder.startFrame(next: 0, wall: -0.2, rate: rate, first: true) == 0)
        #expect(LiveTranscriber.Feeder.startFrame(next: 16_000, wall: 1.4, rate: rate, first: false) == 16_000)
        #expect(LiveTranscriber.Feeder.startFrame(next: 16_000, wall: 1.6, rate: rate, first: false) == 25_600)
        #expect(LiveTranscriber.Feeder.startFrame(next: 16_000, wall: 0.2, rate: rate, first: false) == 16_000)  // never back
    }

    @Test func resultTextLosesStrayLeadingPunctuationAndPunctuationOnlyResultsAreEmpty() {
        #expect(LiveTranscriber.cleaned(".. Sam will book the venue.") == "Sam will book the venue.")
        #expect(LiveTranscriber.cleaned("  Hello there. ") == "Hello there.")
        #expect(LiveTranscriber.cleaned(",..........") == "")
        #expect(LiveTranscriber.cleaned(" . ") == "")
        #expect(LiveTranscriber.cleaned("42 people came.") == "42 people came.")
    }

    // MARK: When finalizeNow forces the analyzer

    @Test func thePendingStretchFollowsVolatileResultsAndClearsWhenAFinalCoversIt() {
        typealias Pending = LiveTranscriber.Pending
        var pending: Pending? = nil
        pending = LiveTranscriber.pending(after: pending, result: (0, 1.1, false))
        #expect(pending == Pending(start: 0, end: 1.1))
        pending = LiveTranscriber.pending(after: pending, result: (0, 4, false))
        #expect(pending == Pending(start: 0, end: 4))
        pending = LiveTranscriber.pending(after: pending, result: (0, 3, true))  // the first sentence is final
        #expect(pending == nil)
        pending = LiveTranscriber.pending(after: pending, result: (3, 4.1, false))
        #expect(pending == Pending(start: 3, end: 4.1))
        // A final that ends before the stretch starts (a late one) leaves it pending.
        #expect(LiveTranscriber.pending(after: pending, result: (1, 3, true)) == pending)
        #expect(LiveTranscriber.pending(after: nil, result: (5, 6, true)) == nil)
    }

    @Test func finalizeNowForcesOnlyALongUnbrokenStretch() {
        typealias Pending = LiveTranscriber.Pending
        let limit = LiveTranscriber.forceAfter
        #expect(!LiveTranscriber.shouldForce(nil))  // nothing pending: only drain
        #expect(!LiveTranscriber.shouldForce(Pending(start: 3, end: 3 + limit - 0.1)))  // a sentence: wait for its pause
        #expect(LiveTranscriber.shouldForce(Pending(start: 3, end: 3 + limit)))
        #expect(LiveTranscriber.shouldForce(Pending(start: 0, end: 40)))
        #expect(limit >= 8 && limit <= 20)
    }

    @Test func aBoundedWaitGivesUpOnWorkThatNeverEnds() async {
        let clock = ContinuousClock()
        let started = clock.now
        let stuck = await LiveTranscriber.within(.milliseconds(100)) {
            try? await Task.sleep(for: .seconds(5))
            return true
        }
        #expect(!stuck && clock.now - started < .seconds(2))
        #expect(await LiveTranscriber.within(.seconds(5)) { true })
        #expect(!(await LiveTranscriber.within(.seconds(5)) { false }))
    }

    // MARK: The meeting clock's base

    @Test func aBaseKnownOnlyAfterTheFeederWasMadeStillPutsATrackAtItsOffset() async {
        let capture = Locked<UInt64?>(nil)
        let feeder = LiveTranscriber.Feeder(track: .them, base: { capture.get })
        capture.update { $0 = host(1_000) }  // the mic's first buffer arrives; the call track starts later
        feeder.ready(analyzerFormat)
        feeder.push(tapLikeBuffer(frames: 4_800, amplitude: 0.3), hostTime: host(1_001.5))
        feeder.push(tapLikeBuffer(frames: 4_800, amplitude: 0.3), hostTime: host(1_001.6))
        await feeder.drain()
        feeder.end()
        var inputs: [AnalyzerInput] = []
        for await input in feeder.stream { inputs.append(input) }
        #expect(startFrame(inputs[0]) == 24_000)
        #expect(contiguous(inputs[...]))
    }

    @Test func theBaseIsReadWhenTheAnalyzerIsReadyNotWhenBuffersArrive() async {
        let capture = Locked<UInt64?>(nil)
        let feeder = LiveTranscriber.Feeder(track: .them, base: { capture.get })
        // Buffers pile up while the model loads, before the capture clock is read.
        feeder.push(tapLikeBuffer(frames: 4_800, amplitude: 0.3), hostTime: host(1_002))
        feeder.push(tapLikeBuffer(frames: 4_800, amplitude: 0.3), hostTime: host(1_002.1))
        await feeder.drain()
        capture.update { $0 = host(1_000) }
        feeder.ready(analyzerFormat)
        await feeder.drain()
        feeder.end()
        var inputs: [AnalyzerInput] = []
        for await input in feeder.stream { inputs.append(input) }
        #expect(startFrame(inputs[0]) == 32_000)
    }

    @Test func withoutABaseTheFirstBufferAppendedIsTimeZeroEvenIfItWasDropped() async {
        let feeder = LiveTranscriber.Feeder(track: .them, base: { nil })
        // 31 s piles up while the model loads; the oldest second is dropped.
        for index in 0..<310 { feeder.push(tapLikeBuffer(frames: 4_800, amplitude: 0.3), hostTime: host(2_000 + Double(index) / 10)) }
        feeder.ready(analyzerFormat)
        await feeder.drain()
        feeder.end()
        var inputs: [AnalyzerInput] = []
        for await input in feeder.stream { inputs.append(input) }
        let dropped = 310 - inputs.count
        #expect(dropped >= 10 && dropped <= 11)  // about 30 s kept
        #expect(startFrame(inputs[0]) == Int64(dropped) * 1_600)  // the dropped audio doesn't move time zero
    }

    // MARK: LiveTranscriber lifecycle without a speech model

    @Test(.timeLimit(.minutes(1))) func finishingATranscriberThatNeverStartedEndsItsUpdates() async {
        let transcriber = LiveTranscriber(track: .me, locale: Locale(identifier: "en-US"), firstHostTime: nil)
        transcriber.append(tapLikeBuffer(frames: 480, amplitude: 0.1), hostTime: host(10))
        await transcriber.finalizeNow()
        async let first: Void = transcriber.finish()
        async let second: Void = transcriber.finish()  // twice at once is harmless
        _ = await (first, second)
        await transcriber.finish()
        transcriber.append(tapLikeBuffer(frames: 480, amplitude: 0.1), hostTime: host(10.1))
        var count = 0
        for await _ in transcriber.updates { count += 1 }
        #expect(count == 0)
    }

    // MARK: On device

    /// Streams a `say` file at four times real speed, with host times as if it were live, calling `finalizeNow` at
    /// points where it only drains (each sentence is shorter than `forceAfter`): no word may be lost.
    @Test(.enabled(if: deviceTests, "needs EARSHOT_DEVICE_TESTS=1 and macOS 26 speech assets"), .timeLimit(.minutes(3)))
    func aSpokenFileStreamedLiveBecomesFinalTextWithRisingTimes() async throws {
        let audio = tempDir().appending(path: "live.aiff")
        try await say("Ashley needs to send the proposal by Friday. Sam will book the venue for the offsite.", to: audio)
        let file = try AVAudioFile(forReading: audio)
        let base = mach_absolute_time()
        let transcriber = LiveTranscriber(track: .them, locale: Locale(identifier: "en-US"), firstHostTime: base)
        try await transcriber.start()
        let transcript = LiveTranscript()
        let reader = Task { for await update in transcriber.updates { await transcript.apply(update) } }

        let rate = file.processingFormat.sampleRate
        let chunk = AVAudioFrameCount(rate / 10)
        var read: AVAudioFramePosition = 0
        var marks = [0.3, 0.5, 0.7]  // mid-sentence and between sentences: the cuts that lost words when always forced
        var text = ""
        let deadline = ContinuousClock.now + .seconds(20)
        // A live call keeps sending audio after the last sentence, so silence follows the speech until it is final.
        while ContinuousClock.now < deadline {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk))
            if read < file.length {
                try file.read(into: buffer, frameCount: chunk)
            } else {
                buffer.frameLength = chunk
                for plane in 0..<Int(buffer.format.channelCount) { buffer.floatChannelData![plane].update(repeating: 0, count: Int(chunk)) }
            }
            guard buffer.frameLength > 0 else { break }
            let at = AVAudioTime.seconds(forHostTime: base) + Double(read) / rate
            transcriber.append(buffer, hostTime: AVAudioTime.hostTime(forSeconds: at))
            read += AVAudioFramePosition(buffer.frameLength)
            try await Task.sleep(for: .milliseconds(25))  // 0.1 s of audio every 25 ms
            if let mark = marks.first, Double(read) >= Double(file.length) * mark {
                marks.removeFirst()
                await transcriber.finalizeNow()
            }
            guard read >= file.length else { continue }
            text = await transcript.finals().map(\.text).joined(separator: " ")
            if text.contains("Ashley") && text.contains("Friday") && text.contains("venue") { break }
        }
        let finals = await transcript.finals()
        await transcriber.finish()
        await reader.value

        #expect(text.contains("Ashley") && text.contains("Friday") && text.contains("venue"), "\(text)")
        #expect(finals.allSatisfy { $0.track == .them && $0.end >= $0.start })
        #expect(zip(finals, finals.dropFirst()).allSatisfy { $0.start < $1.start })
        let length = Double(read) / rate
        #expect((finals.last?.end ?? 0) <= length + 0.5)
    }

    /// One unbroken 23 s sentence. Without a forced finalize it stays volatile until the speaker stops, so the
    /// early words must turn final within a second of `finalizeNow`, while the sentence is still being spoken.
    /// The forced cut costs a second or three of words just after it; the rest of the sentence still arrives.
    @Test(.enabled(if: deviceTests, "needs EARSHOT_DEVICE_TESTS=1 and macOS 26 speech assets"), .timeLimit(.minutes(3)))
    func finalizeNowMakesALongUnbrokenStretchFinalWhileItIsStillBeingSpoken() async throws {
        let audio = tempDir().appending(path: "monologue.aiff")
        try await say("[[slnc 0]] so what we need to do is take the proposal and the budget and the venue list and the caterer "
                      + "quotes and put them all in one shared folder and then send that folder to Ashley and to Sam and to the "
                      + "finance team so that everyone can review the numbers before the offsite and then we can meet again on "
                      + "Thursday afternoon to go through the feedback and agree the final plan and the dates", to: audio)
        let base = mach_absolute_time()
        let transcriber = LiveTranscriber(track: .me, locale: Locale(identifier: "en-US"), firstHostTime: base)
        try await transcriber.start()
        let transcript = LiveTranscript()
        let reader = Task { for await update in transcriber.updates { await transcript.apply(update) } }
        let fed = Locked(0.0)  // the fraction of the speech appended so far
        let done = Locked(false)
        let feeding = Task {
            let file = try AVAudioFile(forReading: audio)
            let rate = file.processingFormat.sampleRate
            let chunk = AVAudioFrameCount(rate / 10)
            var read: AVAudioFramePosition = 0
            while !done.get {  // then silence, as a live call keeps sending audio
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return }
                if read < file.length {
                    try file.read(into: buffer, frameCount: chunk)
                } else {
                    buffer.frameLength = chunk
                    buffer.floatChannelData![0].update(repeating: 0, count: Int(chunk))
                }
                let at = AVAudioTime.seconds(forHostTime: base) + Double(read) / rate
                transcriber.append(buffer, hostTime: AVAudioTime.hostTime(forSeconds: at))
                read += AVAudioFramePosition(buffer.frameLength)
                fed.update { $0 = Double(read) / Double(file.length) }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        while fed.get < 0.7 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await transcript.finals().isEmpty)  // the analyzer hasn't made any of it final on its own
        await transcriber.finalizeNow()
        let deadline = ContinuousClock.now + .seconds(1)
        var early = ""
        while ContinuousClock.now < deadline, !early.contains("proposal") {
            early = await transcript.finals().map(\.text).joined(separator: " ")
            try await Task.sleep(for: .milliseconds(50))
        }
        let stillSpeaking = fed.get < 1
        let end = ContinuousClock.now + .seconds(20)
        var text = ""
        while ContinuousClock.now < end, !text.contains("dates") {
            text = await transcript.finals().map(\.text).joined(separator: " ")
            try await Task.sleep(for: .milliseconds(100))
        }
        done.update { $0 = true }
        try await feeding.value
        await transcriber.finish()
        await reader.value

        #expect(early.contains("proposal"), "\(early)")
        #expect(stillSpeaking)
        #expect(text.contains("dates"), "\(text)")
    }
}

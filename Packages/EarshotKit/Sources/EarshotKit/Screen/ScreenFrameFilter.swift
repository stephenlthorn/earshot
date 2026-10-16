import Foundation

/// Which screen frames become moments (spec 9). A value: `keeping` returns a new filter and leaves this one alone.
public struct ScreenFrameFilter: Equatable, Sendable {
    /// A frame is read only when more than this share of its hash bits differ from the last kept frame.
    public static let hashThreshold = 0.12
    /// Text with fewer non-space characters than this is dropped.
    public static let minCharacters = 20
    /// Text at least this similar to the last kept frame's text is dropped.
    public static let nearDuplicate = 0.8
    /// At most this many moments per meeting.
    public static let maxMoments = 120

    public private(set) var lastHash: ImageHash?
    public private(set) var lastText: String?
    public private(set) var keptCount: Int

    public init() {
        lastHash = nil
        lastText = nil
        keptCount = 0
    }

    /// A filter that carries on after `moments` kept earlier (a sampler restarted on the same meeting): they count
    /// toward the cap and the last one's text is the duplicate baseline. Their frames are gone, so the next frame is
    /// always read.
    static func resuming(after moments: [ScreenMoment]) -> ScreenFrameFilter {
        var filter = ScreenFrameFilter()
        filter.lastText = moments.last?.text
        filter.keptCount = moments.count
        return filter
    }

    public var isFull: Bool { keptCount >= Self.maxMoments }

    /// True when the frame has changed enough since the last kept one to be worth reading.
    public func needsReading(_ hash: ImageHash) -> Bool {
        guard !isFull else { return false }
        guard let lastHash else { return true }
        return ImageHash.difference(hash, lastHash) > Self.hashThreshold
    }

    /// True when the (already redacted) text is long enough and not a near copy of the last kept text.
    public func accepts(_ text: String) -> Bool {
        guard !isFull, Self.isLongEnough(text) else { return false }
        guard let lastText else { return true }
        return TranscriptMerger.similarity(text, lastText) < Self.nearDuplicate
    }

    /// This filter after keeping a frame with `hash` and `text`.
    public func keeping(hash: ImageHash, text: String) -> ScreenFrameFilter {
        var next = self
        next.lastHash = hash
        next.lastText = text
        next.keptCount += 1
        return next
    }

    static func isLongEnough(_ text: String) -> Bool {
        text.unicodeScalars.lazy.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count >= minCharacters
    }
}

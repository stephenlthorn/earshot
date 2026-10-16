import Foundation

/// The screen reading of one recording, as the settings and Stop see it (spec 9). It keeps the options the running
/// sampler started with, and the save of a sampler stopped during the recording, so Stop still waits for
/// screen.json before the notes are written.
public struct ScreenSaves: Sendable {
    /// The running sampler's options; nil when no sampler runs.
    public private(set) var running: ScreenSampler.Options?
    private var earlier: Task<Void, Never>?

    public init() {}

    /// A recording started; `options` is nil when screen reading doesn't run for it. A save left from an earlier
    /// recording is forgotten.
    public mutating func started(_ options: ScreenSampler.Options?) {
        running = options
        earlier = nil
    }

    /// True when the change from `old` to `new` must stop the running sampler now: screen reading went off, or
    /// "Read the whole display" or "Keep screenshots" went off while the sampler uses it.
    public func stopsNow(from old: EarshotSettings, to new: EarshotSettings) -> Bool {
        guard let running else { return false }
        return RecordingSwitches.stopsScreenReading(from: old, to: new)
            || RecordingSwitches.narrowsScreenReading(running, to: new)
    }

    /// The running sampler was stopped during the recording; `save` finishes once screen.json is saved.
    public mutating func stoppedMidCall(saving save: Task<Void, Never>) {
        running = nil
        earlier = save
    }

    /// At Stop: the running sampler's save when one ran, else the save started when reading stopped during the
    /// recording, else one that is already done. Each save is handed out once.
    public mutating func takeForStop(running save: Task<Void, Never>?) -> Task<Void, Never> {
        let taken = save ?? earlier ?? Task {}
        running = nil
        earlier = nil
        return taken
    }
}

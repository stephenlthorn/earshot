import Foundation

/// Settings switched off during a recording take effect at once, for privacy (spec 4.1 and 9). Screen reading and
/// the live assistant are otherwise set up only when a recording starts.
public enum RecordingSwitches {
    /// The live panel's status line once the live assistant was switched off during this recording.
    public static let liveOffLine = "The live assistant is off until the next recording."

    /// "Read my screen during calls" went off: stop the sampler now and save what it has.
    public static func stopsScreenReading(from old: EarshotSettings, to new: EarshotSettings) -> Bool {
        old.readScreen && !new.readScreen
    }

    /// "Read the whole display" or "Keep screenshots" went off while the running sampler (started with `running`)
    /// uses it. Its options are fixed at start, so it stops now and saves what it has; reading resumes at the next
    /// recording.
    public static func narrowsScreenReading(_ running: ScreenSampler.Options, to new: EarshotSettings) -> Bool {
        (running.wholeDisplay && !new.screenWholeDisplay) || (running.keepImages && !new.keepScreenshots)
    }

    /// The live assistant went off: stop its passes and live transcribers now. The panel and flags stay.
    public static func stopsLiveAssistant(from old: EarshotSettings, to new: EarshotSettings) -> Bool {
        old.liveAssistant && !new.liveAssistant
    }
}

/// "Write notes" on a Record-only meeting: the meeting becomes a Notes meeting and is transcribed and summarized.
public enum RecordingNotes {
    public static let buttonLabel = "Write notes"

    /// A finished Record meeting that the pipeline isn't working on.
    public static func canWrite(_ session: Session, busy: Bool) -> Bool {
        session.mode == .record && session.isFinished && !busy
    }
}

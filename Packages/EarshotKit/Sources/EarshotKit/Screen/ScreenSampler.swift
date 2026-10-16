import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads the call's screen during a recording (spec 9): every 15 seconds it captures a frame, skips it while secure
/// input or a password manager is up, reads changed frames with Vision, redacts the text and keeps up to 120 moments.
/// Saves `screen.json` in the meeting folder; screenshots go under `screen/` only with `keepImages`.
public actor ScreenSampler {
    public struct Options: Equatable, Sendable {
        public var wholeDisplay: Bool
        public var keepImages: Bool
        public var interval: Duration
        public var maxWidth: Int

        public init(wholeDisplay: Bool = false, keepImages: Bool = false, interval: Duration = .seconds(15),
                    maxWidth: Int = 1440) {
            self.wholeDisplay = wholeDisplay
            self.keepImages = keepImages
            self.interval = interval
            self.maxWidth = maxWidth
        }
    }

    /// What one sample did.
    public enum Outcome: Equatable, Sendable {
        case kept(ScreenMoment)
        case skipped(Skip)
        case failed(String)
    }

    public enum Skip: Equatable, Sendable {
        /// 120 moments are already kept.
        case full
        /// No call app is known, so nothing is captured.
        case noCallApp
        /// Secure text input is on or a password manager is frontmost.
        case secureInput
        /// Screen Recording isn't allowed.
        case noPermission
        /// The meeting clock hasn't started.
        case notStarted
        /// The capturer found nothing to capture.
        case nothingToCapture
        /// The frame barely changed since the last kept one.
        case unchanged
        /// Fewer than 20 characters of text.
        case tooLittleText
        /// Nearly the same text as the last kept frame.
        case duplicate
        /// The sampler was stopped, or a switch went off, while it was capturing or reading.
        case cancelled
    }

    private let folder: URL
    private let capturer: any ScreenCapturing
    private let recognizer: any TextRecognizing
    private let secureInput: SecureInputCheck
    private let appBundlePrefix: @Sendable () -> String?
    private let now: @Sendable () -> Double?
    private let sleep: @Sendable (Duration) async throws -> Void
    private let options: Options

    private var filter = ScreenFrameFilter()
    private var kept: [ScreenMoment] = []
    private var running = false
    /// Whether an earlier screen.json in the folder has been read in (once, on first use).
    private var resumed = false
    /// The number for the next `screen/NNN.png`, after any already in the folder.
    private var nextImageNumber = 1
    /// The last capture, read, save or screenshot write that failed, for the log.
    public private(set) var lastError: String?

    /// - Parameters:
    ///   - appBundlePrefix: the call app that call detection matched (or the frontmost browser), nil when none.
    ///   - now: seconds on the meeting clock (spec 14.1), nil before the first audio buffer.
    public init(folder: URL, capturer: any ScreenCapturing, recognizer: any TextRecognizing,
                secureInput: SecureInputCheck = .system, appBundlePrefix: @escaping @Sendable () -> String?,
                now: @escaping @Sendable () -> Double?,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                options: Options = Options()) {
        self.folder = folder
        self.capturer = capturer
        self.recognizer = recognizer
        self.secureInput = secureInput
        self.appBundlePrefix = appBundlePrefix
        self.now = now
        self.sleep = sleep
        self.options = options
    }

    /// Samples every `interval` until cancelled, the sleep throws, or the cap is reached. Saves after each kept moment.
    /// A second call while one is running returns at once.
    public func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        while !Task.isCancelled {
            if case .kept = await sampleOnce() { saveLogged() }
            if filter.isFull { break }
            do { try await sleep(options.interval) } catch { break }
        }
    }

    /// Takes and judges one frame.
    public func sampleOnce() async -> Outcome {
        resumeIfNeeded()
        if filter.isFull { return .skipped(.full) }
        guard let app = appBundlePrefix() else { return .skipped(.noCallApp) }
        if await secureInput.shouldSkip() { return .skipped(.secureInput) }
        guard capturer.hasPermission() else { return .skipped(.noPermission) }
        guard let offset = now() else { return .skipped(.notStarted) }
        do {
            guard let image = try await capturer.capture(appBundlePrefix: app, wholeDisplay: options.wholeDisplay,
                                                         maxWidth: options.maxWidth) else {
                return .skipped(.nothingToCapture)
            }
            // Stopped (a screen switch went off) while the frame was taken: it is never read.
            if Task.isCancelled { return .skipped(.cancelled) }
            // Secure input may have come on while the frame was taken.
            if await secureInput.shouldSkip() { return .skipped(.secureInput) }
            guard let hash = ImageHash.average16(image) else {
                lastError = "Earshot couldn't read a screenshot."
                return .failed("The screenshot couldn't be read.")
            }
            guard filter.needsReading(hash) else { return .skipped(filter.isFull ? .full : .unchanged) }
            let text = ScreenRedaction.clean(try await recognizer.recognize(image))
            // Stopped (reading switched off or narrowed) while Vision read: nothing is kept, no image written.
            if Task.isCancelled { return .skipped(.cancelled) }
            guard ScreenFrameFilter.isLongEnough(text) else { return .skipped(.tooLittleText) }
            guard filter.accepts(text) else { return .skipped(filter.isFull ? .full : .duplicate) }
            let moment = ScreenMoment(offset: offset, text: text, image: options.keepImages ? writeImage(image) : nil)
            filter = filter.keeping(hash: hash, text: text)
            kept.append(moment)
            return .kept(moment)
        } catch is CancellationError {
            return .skipped(.cancelled)
        } catch {
            // A stop can surface as another error from the capturer or Vision; it isn't a failure.
            if Task.isCancelled { return .skipped(.cancelled) }
            lastError = "Earshot couldn't read the screen: \(error.localizedDescription)"
            return .failed(error.localizedDescription)
        }
    }

    /// The moments kept so far, in time order, including any an earlier sampler saved in this folder.
    public func moments() -> [ScreenMoment] {
        resumeIfNeeded()
        return kept
    }

    /// Writes `screen.json` (version 1) with every moment, earlier ones included. Safe to call more than once.
    public func save() throws {
        resumeIfNeeded()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONFiles.write(ScreenFile(version: 1, moments: kept), to: folder.appending(path: MeetingFile.screen))
    }

    // MARK: - Private

    /// Carries on from an earlier screen.json in the folder (screen reading turned off and on, or the sampler made
    /// again mid-call), so its moments aren't overwritten, they count toward the cap, and new screenshots get new
    /// numbers. An unreadable file held no moments Earshot can use; it is replaced on the next save and noted.
    private func resumeIfNeeded() {
        guard !resumed else { return }
        resumed = true
        do {
            let earlier = try JSONFiles.readIfPresent(ScreenFile.self, from: folder.appending(path: MeetingFile.screen))
            if let earlier, !earlier.moments.isEmpty {
                kept = earlier.moments + kept
                filter = ScreenFrameFilter.resuming(after: kept)
            }
        } catch {
            lastError = "Earshot couldn't read the earlier screen text: \(error.localizedDescription)"
        }
        nextImageNumber = Self.nextImageNumber(after: kept.compactMap(\.image) + existingImageNames())
    }

    /// File names already under `screen/`, or none when there's no such folder.
    private func existingImageNames() -> [String] {
        let directory = folder.appending(path: MeetingFile.screenFolder, directoryHint: .isDirectory)
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// One past the highest `NNN.png` among `names`; 1 when there are none.
    static func nextImageNumber(after names: [String]) -> Int {
        let numbers = names.compactMap { name -> Int? in
            guard name.lowercased().hasSuffix(".png") else { return nil }
            return Int(name.dropLast(4))
        }
        return (numbers.filter { $0 > 0 }.max() ?? 0) + 1
    }

    private func saveLogged() {
        do { try save() } catch { lastError = "Earshot couldn't save the screen text: \(error.localizedDescription)" }
    }

    /// Writes the frame as `screen/NNN.png` and returns the file name, or nil (with `lastError`) when it can't.
    private func writeImage(_ image: CGImage) -> String? {
        let name = String(format: "%03d.png", nextImageNumber)
        let directory = folder.appending(path: MeetingFile.screenFolder, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            lastError = "Earshot couldn't save a screenshot: \(error.localizedDescription)"
            return nil
        }
        let url = directory.appending(path: name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            lastError = "Earshot couldn't save a screenshot."
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            lastError = "Earshot couldn't save a screenshot."
            return nil
        }
        nextImageNumber += 1
        return name
    }
}

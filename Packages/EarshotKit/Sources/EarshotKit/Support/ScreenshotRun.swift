import Foundation

/// The plumbing of `Earshot --render-screenshots <folder>` (spec 19), kept here so it has tests: the launch argument,
/// the scratch folder for the sample meetings, and the copy of the notes page Scripts/screenshots.sh measures.
public enum ScreenshotRun {
    public static let flag = "--render-screenshots"

    public enum Request: Equatable, Sendable {
        /// Draw everything into this folder.
        case render(URL)
        /// The flag came without a folder: print the usage and exit 64.
        case usage
    }

    /// Nil when the flag isn't given, so the app starts as usual.
    public static func request(in arguments: [String]) -> Request? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = index + 1
        guard next < arguments.count, !arguments[next].isEmpty, !arguments[next].hasPrefix("-") else { return .usage }
        return .render(URL(fileURLWithPath: arguments[next], isDirectory: true))
    }

    public static let scratchName = "scratch"

    /// Where the sample meetings and Claude Code work folder go: inside the output folder, so the script's own
    /// cleanup removes them even when the renderer is stopped before it can.
    public static func scratchFolder(in out: URL) -> URL {
        out.appending(path: scratchName, directoryHint: .isDirectory)
    }

    // MARK: The notes page crop

    /// The README shows the notes page from the header down to this section.
    public static let cropSection = "flags"
    /// Space kept below that section, in CSS pixels.
    public static let cropMargin = 40
    /// The attribute the measuring copy sets on `<body>`: where the crop ends, in CSS pixels from the top.
    public static let cropAttribute = "data-crop-bottom"

    /// The page with its Content-Security-Policy removed and one script added that writes where the crop ends onto
    /// `<body>`. Chrome's `--dump-dom` prints it, and the script screenshots the real (unchanged) page to that height.
    public static func measuringCopy(_ html: String) -> String {
        let script = "<script>const s=document.querySelector('section.\(cropSection)');"
            + "if(s){document.body.setAttribute('\(cropAttribute)',"
            + "Math.ceil(s.getBoundingClientRect().bottom+window.scrollY+\(cropMargin)))}</script>"
        return html.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("http-equiv=\"Content-Security-Policy\"") }
            .joined(separator: "\n")
            .replacingOccurrences(of: "</body>", with: script + "\n</body>")
    }
}

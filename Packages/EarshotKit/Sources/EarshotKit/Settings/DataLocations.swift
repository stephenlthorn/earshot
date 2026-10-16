import Foundation

/// Where the app keeps the library index and lessons.json. The user's own are in Application Support (spec 6 and
/// 11.1); the e2e harnesses use a folder of their own, so a test run never touches the user's index or lessons.
public struct DataLocations: Equatable, Sendable {
    public var index: URL
    public var lessons: URL

    public init(index: URL, lessons: URL) {
        self.index = index
        self.lessons = lessons
    }

    /// The user's index and lessons, in Application Support.
    public static var standard: DataLocations {
        DataLocations(index: LibraryIndex.defaultURL, lessons: LessonsStore.defaultURL)
    }

    /// Index/ and lessons.json inside `folder`, laid out like Application Support/Earshot.
    public static func inside(_ folder: URL) -> DataLocations {
        DataLocations(index: folder.appending(path: "Index", directoryHint: .isDirectory),
                      lessons: folder.appending(path: "lessons.json"))
    }
}

/// The app's end-to-end command lines (App/E2E.swift):
///
/// - `--e2e <mode> <seconds> <meetings folder> [<data folder>]` records (Scripts/e2e.sh).
/// - `--e2e-import <audio> <meetings folder> [<data folder>] [--local <url> <model>]` imports
///   (Scripts/e2e-import.sh). With `--local`, the notes come from that local model server, not Claude Code.
///
/// The data folder holds the run's library index and lessons. Without one they go to a new temporary folder, so a
/// run never writes the user's index in Application Support.
public enum E2ELaunch: Equatable, Sendable {
    /// The local model server an import writes its notes with.
    public struct LocalModel: Equatable, Sendable {
        public var url: String
        public var model: String

        public init(url: String, model: String) {
            self.url = url
            self.model = model
        }
    }

    case record(mode: Mode, seconds: Double, meetings: URL, data: DataLocations)
    case importAudio(audio: URL, meetings: URL, data: DataLocations, local: LocalModel? = nil)

    public var meetings: URL {
        switch self {
        case let .record(_, _, meetings, _), let .importAudio(_, meetings, _, _): meetings
        }
    }

    public var data: DataLocations {
        switch self {
        case let .record(_, _, _, data), let .importAudio(_, _, data, _): data
        }
    }

    /// Nil when `arguments` ask for neither harness, or give `--local` without both its values. `--e2e-import` wins
    /// when both are given.
    public static func parse(_ arguments: [String],
                             temporaryFolder: () -> URL = E2ELaunch.newTemporaryFolder) -> E2ELaunch? {
        if let index = arguments.firstIndex(of: "--e2e-import"), arguments.count > index + 2 {
            var local: LocalModel?
            if let flag = arguments.firstIndex(of: "--local") {
                let values = arguments.dropFirst(flag + 1).prefix(2).map { $0.trimmingCharacters(in: .whitespaces) }
                guard values.count == 2, values.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else { return nil }
                local = LocalModel(url: values[0], model: values[1])
            }
            return .importAudio(audio: URL(fileURLWithPath: arguments[index + 1]),
                                meetings: URL(fileURLWithPath: arguments[index + 2]),
                                data: data(arguments, at: index + 3, temporaryFolder), local: local)
        }
        guard let index = arguments.firstIndex(of: "--e2e"), arguments.count > index + 3,
              let mode = Mode(rawValue: arguments[index + 1]), let seconds = Double(arguments[index + 2]) else {
            return nil
        }
        return .record(mode: mode, seconds: seconds, meetings: URL(fileURLWithPath: arguments[index + 3]),
                       data: data(arguments, at: index + 4, temporaryFolder))
    }

    /// A folder of its own under the system's temporary folder.
    public static func newTemporaryFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "earshot-e2e-data-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// The data folder given at `position`, or a temporary one. A flag there (macOS can add its own) isn't a folder.
    private static func data(_ arguments: [String], at position: Int, _ temporaryFolder: () -> URL) -> DataLocations {
        let given = arguments.indices.contains(position) && !arguments[position].hasPrefix("-") ? arguments[position] : nil
        return .inside(given.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? temporaryFolder())
    }
}

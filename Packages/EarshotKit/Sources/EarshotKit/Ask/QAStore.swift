import Foundation

/// A meeting's qa.json (spec 8): questions and answers, oldest first.
public struct QAStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// qa.json in the meeting folder.
    public init(folder: URL) {
        self.init(url: folder.appending(path: MeetingFile.qa))
    }

    /// The file, or an empty one when it doesn't exist yet. A file that isn't qa.json throws.
    public func read() throws -> QAFile {
        try JSONFiles.readIfPresent(QAFile.self, from: url) ?? QAFile()
    }

    public func entries() throws -> [QAEntry] {
        try read().entries
    }

    /// Re-reads the file, adds `entry` at the end and writes it atomically. The existing file must be a JSON object
    /// whose `entries` is an array of entries that all decode; otherwise it is left exactly as it is and the append
    /// throws, so no earlier answer is lost. The new entry is spliced into the file as it is on disk, so unknown
    /// fields and a newer `version` are kept.
    @discardableResult
    public func append(_ entry: QAEntry) throws -> QAFile {
        try Self.lock.withLock {
            var raw = try existing()
            var entries = raw["entries"] as? [Any] ?? []
            entries.append(try JSONSerialization.jsonObject(with: JSONFiles.encoder().encode(entry)))
            raw["entries"] = entries
            if let version = raw["version"] as? Int {
                raw["version"] = max(version, 1)
            } else if raw["version"] == nil {
                raw["version"] = 1
            }
            let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            return try JSONFiles.decoder().decode(QAFile.self, from: data)
        }
    }

    /// The file on disk as a JSON object, an empty one when there is no file yet. Throws when the file is not a JSON
    /// object, has no `entries` array, or holds an entry that does not decode as a `QAEntry`.
    private func existing() throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["entries"] as? [Any]
        else { throw unreadable() }
        let decoder = JSONFiles.decoder()
        for element in entries {
            guard let fields = element as? [String: Any],
                  let one = try? JSONSerialization.data(withJSONObject: fields),
                  (try? decoder.decode(QAEntry.self, from: one)) != nil
            else { throw unreadable() }
        }
        return object
    }

    private func unreadable() -> CocoaError {
        CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url, NSFilePathErrorKey: url.path])
    }

    /// One append at a time in this process.
    private static let lock = NSLock()
}

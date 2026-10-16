import Foundation

/// How Earshot reads and writes its JSON files: pretty, sorted keys, ISO 8601 dates, written atomically.
public enum JSONFiles {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder().decode(type, from: Data(contentsOf: url))
    }

    /// Nil when the file doesn't exist; any other problem (unreadable, wrong shape) throws.
    public static func readIfPresent<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        do {
            return try read(type, from: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// Writes atomically, so a reader never sees half a file.
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder().encode(value).write(to: url, options: .atomic)
    }
}

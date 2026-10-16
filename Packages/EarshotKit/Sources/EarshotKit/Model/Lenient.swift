import Foundation

/// Decoding helpers for files that newer or older versions of Earshot may have written. A missing key, a null, a
/// value of the wrong shape or an enum case this version doesn't know never fails the whole decode.
extension KeyedDecodingContainer {
    /// The value, or nil when the key is missing, null or doesn't decode.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// The array without the elements that don't decode; empty when the key is missing or isn't an array.
    func lossy<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        (lenient([Lossy<T>].self, key) ?? []).compactMap(\.value)
    }

    /// The string as the enum case it names, or nil for a case this version doesn't know.
    func lenientCase<T: RawRepresentable>(_ type: T.Type, _ key: Key) -> T? where T.RawValue == String {
        lenient(String.self, key).flatMap(T.init(rawValue:))
    }
}

/// One array element that may fail to decode on its own.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

/// An enum that decodes a case it doesn't know to `fallback` instead of failing.
public protocol FallbackDecodable: RawRepresentable, Decodable where RawValue == String {
    static var fallback: Self { get }
}

extension FallbackDecodable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.fallback
    }
}

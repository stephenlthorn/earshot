import Foundation

/// Cleans an event's notes before a model sees them (spec 2 and 5.2): links become "[link]", lines with dial-in
/// details are dropped, and no full address or "@" is left.
public enum AgendaSanitizer {
    public static let link = "[link]"

    /// The agenda with links replaced, secret lines (`isSecret`) dropped, addresses reduced to their domain, blank
    /// runs collapsed and the ends trimmed.
    public static func clean(_ agenda: String) -> String {
        var out: [String] = []
        // Every kind of line break: Exchange and Teams invites use "\r\n", which Swift sees as one Character.
        for raw in agenda.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            if isSecret(line) { continue }
            let cleaned = scrubAddresses(replaceLinks(line)).replacing(/\s+$/, with: "")
            if cleaned.trimmingCharacters(in: .whitespaces).isEmpty {
                if let last = out.last, !last.isEmpty { out.append("") }
            } else {
                out.append(cleaned)
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the cleaned agenda says something besides links: a block of only dial-in details and join links is
    /// not an agenda.
    public static func hasContent(_ agenda: String) -> Bool {
        clean(agenda).replacingOccurrences(of: link, with: "").contains { $0.isLetter || $0.isNumber }
    }

    /// Every web, mail or phone link, and every bare host with a path (zoom.us/j/1), as "[link]". Punctuation that
    /// ends a sentence stays after it.
    public static func replaceLinks(_ text: String) -> String {
        var result = text
        for pattern in linkPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: link + "$1")
        }
        return result
    }

    /// Each address as "[address at <domain>]", then any other "@" as "at", so no full address or "@" is left.
    /// The local part is any run of characters that cannot end an address, so accented names and typographic
    /// apostrophes go too, and a single-label domain ("intranet") counts. A token still stuck to an "@" is dropped,
    /// never spelled out.
    public static func scrubAddresses(_ text: String) -> String {
        guard text.contains("@") else { return text }
        let addresses = text.replacing(/[^\s@<>()\[\],;:"]+@((?:[\p{L}\p{N}-]+\.)*[\p{L}\p{N}-]+)/) { match in
            "[address at \(match.1.lowercased())]"
        }
        let stuck = addresses.replacing(/[^\s@]+@+(?=\S)/, with: "at ")
        return stuck.replacing(/[ \t]*@+[ \t]*/, with: " at ")
    }

    /// True for a line holding a passcode, password, PIN, meeting or conference ID, access code or dial-in number.
    /// "PIN" in capitals always counts. In any other case "pin" counts only before a ":", "#" or digit, so "Pin
    /// down the price" stays.
    static func isSecret(_ line: String) -> Bool {
        line.range(of: secretLine, options: [.regularExpression, .caseInsensitive]) != nil
            || line.range(of: pinInCapitals, options: .regularExpression) != nil
    }

    static let secretLine = #"\b(?:pass[ -]?codes?|passwords?|(?:meeting|conference)[ -]?ids?|access[ -]?codes?|dial[ -]?ins?)\b|\bpins?\s*[:#\d]"#
    static let pinInCapitals = #"\bPINs?\b"#

    /// Each pattern captures any trailing punctuation in $1, so it is put back after "[link]".
    static let linkPatterns = [
        #"(?:\b[a-z][a-z0-9+.-]*://|\bmailto:|\btel:|\bwww\.)\S*?([.,;:!?)\]}>'"]*)(?=\s|$)"#,
        #"\b(?:[a-z0-9-]+\.)+[a-z]{2,}/\S*?([.,;:!?)\]}>'"]*)(?=\s|$)"#,
    ]
}

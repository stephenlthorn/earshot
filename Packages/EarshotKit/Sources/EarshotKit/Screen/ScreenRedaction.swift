import Foundation

/// Cleans text read from the screen before it is stored or sent (spec 9).
///
/// First the agenda's own rules, by calling `AgendaSanitizer`: lines about passcodes, passwords, PINs, meeting or
/// conference IDs, access codes or dial-ins are dropped, web, mail and phone links become "[link]", and addresses
/// become "[address at <domain>]" with no "@" left.
///
/// Then the screen rules: lines with password, passcode or passwd anywhere in a word, or with "pin" as a word in any
/// case (`USER_PIN=`, `pin=4821`), private key blocks, keys and tokens, card-like numbers and IBANs, and runs of 9 or
/// more digits.
public enum ScreenRedaction {
    public static let link = AgendaSanitizer.link
    public static let secret = "[redacted]"
    public static let number = "[number]"

    /// The cleaned text: trimmed lines, blank ones dropped.
    public static func clean(_ text: String) -> String {
        keptLines(text)
            .map { line in
                let agenda = agendaLine(line)
                let tokenless = replace(tokens, in: agenda, with: secret)
                let cardless = replace(cards, in: tokenless, with: number, when: passesLuhn)
                return replace(numbers, in: cardless, with: number)
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: - Lines

    /// The lines left after dropping secret lines and private key blocks.
    static func keptLines(_ text: String) -> [String] {
        var inKeyBlock = false
        var kept: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.contains("-----BEGIN"), line.contains("PRIVATE KEY") { inKeyBlock = true }
            let endsBlock = inKeyBlock && line.contains("-----END")
            if !inKeyBlock, !isSecretLine(line) { kept.append(line) }
            if endsBlock { inKeyBlock = false }
        }
        return kept
    }

    static func isSecretLine(_ line: String) -> Bool {
        AgendaSanitizer.isSecret(line) || matches(screenSecretLine, line)
    }

    /// The screen's extra rule, stricter than the agenda's (spec 9): password, passcode and passwd anywhere in a word
    /// (`DB_PASSWORD=`), and "pin" or "pins" in any case between non-letters (`USER_PIN=`, `pin=4821`,
    /// `my pin is 4821`). "Spinning" and "Pinned" stay; "Pins for the booth" goes on screen, though the agenda keeps it.
    private static let screenSecretLine = regex(
        #"(?i:pass(?:word|code|wd))|(?i:(?<![a-z])pins?(?![a-z]))"#)

    // MARK: - The agenda rules for one line

    /// Links replaced, then addresses scrubbed, exactly as `AgendaSanitizer.clean` does to each line it keeps.
    static func agendaLine(_ line: String) -> String {
        AgendaSanitizer.scrubAddresses(AgendaSanitizer.replaceLinks(line))
    }

    // MARK: - Keys, tokens and numbers

    private static let tokens = [
        // A labelled value, env-style names too: "token = ...", "AWS_SECRET_ACCESS_KEY=...", "x-api-token: ...",
        // "\"api_key\": ...". No \b before the name: "_" and "-" are part of it.
        regex(#"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]*(?:api[_-]?key|access[_-]?key|secret|token|passwd)[A-Za-z0-9_-]*["']?\s*[:=]\s*\S+"#,
              caseInsensitive: true),
        regex(#"\bbearer\s+[A-Za-z0-9._~+/=-]{16,}"#, caseInsensitive: true),
        // Anthropic and OpenAI style keys.
        regex(#"\bsk-[A-Za-z0-9_-]{16,}"#),
        // GitHub.
        regex(#"\bgh[pousr]_[A-Za-z0-9]{20,}"#),
        regex(#"\bgithub_pat_[A-Za-z0-9_]{20,}"#),
        // Slack.
        regex(#"\bxox[abposr]-[A-Za-z0-9-]{10,}"#),
        // AWS access key ids.
        regex(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        // Google API keys.
        regex(#"\bAIza[0-9A-Za-z_-]{30,}"#),
        // JSON web tokens.
        regex(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"#),
        // Any other long run of letters and digits mixed.
        regex(#"\b(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{32,}"#),
    ]

    /// Card numbers written in groups (4-4-4-4, 4-6-5), kept only when they pass the Luhn check, so a row of years
    /// such as "2024 2025 2026 2027" usually stays.
    private static let cards = [
        regex(#"\b(?:\d{4}([ -])\d{4}\1\d{4}\1\d{1,7}|\d{4}([ -])\d{6}\2\d{4,5})\b"#),
    ]

    private static let numbers = [
        // IBANs, spaced or not: two letters, two check digits, then groups of letters and digits.
        regex(#"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?\b"#),
        regex(#"\d{9,}"#),
    ]

    /// True when the digits in `text` pass the Luhn check that card numbers carry.
    static func passesLuhn(_ text: String) -> Bool {
        let digits = text.compactMap(\.wholeNumberValue)
        guard digits.count >= 12 else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { total, pair in
            guard pair.offset % 2 == 1 else { return total + pair.element }
            let doubled = pair.element * 2
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }

    // MARK: - Helpers

    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        // The patterns are constants, so a bad one is a programming error caught by the tests.
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Each match of each pattern replaced by `placeholder`, or only the matches `when` accepts.
    private static func replace(_ patterns: [NSRegularExpression], in line: String, with placeholder: String,
                                when accept: (String) -> Bool = { _ in true }) -> String {
        patterns.reduce(line) { text, regex in
            let found = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            return found.reversed().reduce(text) { result, match in
                guard let range = Range(match.range, in: result), accept(String(result[range])) else { return result }
                return result.replacingCharacters(in: range, with: placeholder)
            }
        }
    }
}

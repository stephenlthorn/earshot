import Foundation

/// Where the webhook target may send a meeting. The app's Settings and `earshot process --target webhook` share it.
/// - https is always allowed.
/// - Plain http only reaches this Mac or the local network: `localhost`, `127.0.0.1`, `::1`, `.local` names, and
///   the private and carrier-grade NAT IPv4 ranges (10/8, 172.16/12, 192.168/16, 100.64/10), written as numbers.
/// - A user name or password in the URL is never allowed: it would sit in the saved settings, and the token field
///   is for secrets.
public enum WebhookURLPolicy {
    public static let missingURL = "Paste the webhook URL in Settings, Do."
    public static let wrongURL =
        "The webhook URL must start with https://. Plain http:// works only for this Mac or your local network."
    public static let credentials =
        "Take the user name and password out of the webhook URL. Put a token in the token field instead."

    public static func allows(_ url: URL) -> Bool { problem(url) == nil }

    /// Why the URL typed in Settings can't be used, or nil when it can. Spaces around it are ignored.
    public static func problem(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return missingURL }
        guard let url = URL(string: trimmed) else { return wrongURL }
        return problem(url)
    }

    static func problem(_ url: URL) -> String? {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "https" || scheme == "http", let host = host(of: url) else { return wrongURL }
        if url.user(percentEncoded: true) != nil || url.password(percentEncoded: true) != nil { return credentials }
        return scheme == "https" || isLocal(host) ? nil : wrongURL
    }

    /// The host in lower case, without IPv6 brackets or a final dot, or nil when there is none.
    static func host(of url: URL) -> String? {
        var host = (url.host(percentEncoded: false) ?? "").lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    /// This Mac, a `.local` name, or a private or carrier-grade NAT IPv4 address.
    static func isLocal(_ host: String) -> Bool {
        if ["localhost", "127.0.0.1", "::1"].contains(host) { return true }
        if host.hasSuffix(".local"), host.count > ".local".count { return true }
        guard let octets = ipv4(host) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    /// The four numbers of a dotted IPv4 address, or nil. Strict: exactly four decimal parts of 0 to 255 with no
    /// leading zeros, since some resolvers read "010" as octal.
    static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  part == "0" || !part.hasPrefix("0"), let value = Int(part), value <= 255 else { return nil }
            return value
        }
        return numbers.count == 4 ? numbers : nil
    }
}

import Foundation

/// The apps whose microphone use counts as a call (spec 7.1), matched by bundle-id prefix.
public enum MeetingApps {
    public static let dedicatedPrefixes = [
        "us.zoom.", "com.microsoft.teams", "com.cisco.webex", "Cisco-Systems.Spark", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "com.apple.FaceTime", "com.skype.", "app.tuple.", "com.loom.",
    ]

    /// Browser calls show up under helper processes (`com.google.Chrome.helper`, `com.apple.WebKit.GPU`).
    public static let browserPrefixes = [
        "com.google.Chrome", "com.apple.Safari", webKitPrefix, "org.mozilla.firefox", "com.microsoft.edgemac",
        "company.thebrowser.", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    public static let prefixes = dedicatedPrefixes + browserPrefixes

    static let webKitPrefix = "com.apple.WebKit"
    static let safariID = "com.apple.Safari"

    /// Names to show when no running app gives one.
    static let knownNames: [String: String] = [
        "us.zoom.": "Zoom", "com.microsoft.teams": "Microsoft Teams", "com.cisco.webex": "Webex",
        "Cisco-Systems.Spark": "Webex", "com.tinyspeck.slackmacgap": "Slack", "com.hnc.Discord": "Discord",
        "com.apple.FaceTime": "FaceTime", "com.skype.": "Skype", "app.tuple.": "Tuple", "com.loom.": "Loom",
        "com.google.Chrome": "Google Chrome", safariID: "Safari", webKitPrefix: "Safari",
        "org.mozilla.firefox": "Firefox", "com.microsoft.edgemac": "Microsoft Edge", "company.thebrowser.": "Arc",
        "com.brave.Browser": "Brave", "com.vivaldi.Vivaldi": "Vivaldi", "com.operasoftware.Opera": "Opera",
    ]

    public static func isDedicatedCallApp(_ bundleID: String) -> Bool {
        prefix(of: bundleID, in: dedicatedPrefixes) != nil
    }

    /// The display name of the call app behind `bundleID`, or nil when it isn't a call app.
    /// `runningApps` maps the bundle ids of running apps to their names. Build it from NSWorkspace's apps with
    /// `activationPolicy == .regular` only, using `Dictionary(_:uniquingKeysWith: { a, _ in a })`, because helpers
    /// register under their own names and several can share one bundle id. WebKit processes count only while
    /// Safari runs.
    public static func match(_ bundleID: String, runningApps: [String: String]) -> String? {
        guard let prefix = prefix(of: bundleID, in: prefixes) else { return nil }
        if prefix == webKitPrefix {
            guard runningApps[safariID] != nil else { return nil }
            return name(for: safariID, prefix: safariID, runningApps: runningApps)
        }
        return name(for: bundleID, prefix: prefix, runningApps: runningApps)
    }

    /// A stable identity for the app behind `bundleID`: its matched prefix, with WebKit counted as Safari.
    /// Nil when it isn't a call app. Unlike the display name, it never depends on which apps are running.
    public static func appKey(for bundleID: String) -> String? {
        guard let prefix = prefix(of: bundleID, in: prefixes) else { return nil }
        return prefix == webKitPrefix ? safariID : prefix
    }

    static func prefix(of bundleID: String, in list: [String]) -> String? {
        guard !bundleID.isEmpty else { return nil }
        return list.first { bundleID.hasPrefix($0) }
    }

    /// The nearest running parent app (a helper such as "Google Chrome Helper" names itself), then the app
    /// itself, then another running app with the same prefix, then a known name.
    private static func name(for bundleID: String, prefix: String, runningApps: [String: String]) -> String? {
        let parents = runningApps.keys.filter { bundleID.hasPrefix($0 + ".") }.sorted { $0.count > $1.count }
        if let parent = parents.first, let name = runningApps[parent] { return name }
        if let own = runningApps[bundleID] { return own }
        if let sibling = runningApps.keys.filter({ $0.hasPrefix(prefix) }).sorted().first, let name = runningApps[sibling] {
            return name
        }
        return knownNames[prefix] ?? bundleID
    }
}

import AppKit
import Carbon.HIToolbox
import Foundation

/// Whether a screen frame must be skipped (spec 9): secure text input is on, or a password manager is frontmost.
/// Both are read on the main actor: `IsSecureEventInputEnabled()` isn't thread safe, and the frontmost app is kept
/// up to date on the main run loop.
public struct SecureInputCheck: Sendable {
    /// Bundle id prefixes of password managers: 1Password (8 and 7), Bitwarden, Dashlane, Keeper, Apple Passwords and
    /// Keychain Access. Matched case-insensitively, as a whole id or a prefix ending at a dot.
    public static let passwordManagers = [
        "com.1password", "com.agilebits.onepassword", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden", "com.dashlane", "com.keepersecurity",
        "com.apple.passwords", "com.apple.keychainaccess",
    ]

    public var secureInputOn: @MainActor @Sendable () -> Bool
    public var frontmostBundleID: @MainActor @Sendable () -> String?

    public init(secureInputOn: @escaping @MainActor @Sendable () -> Bool,
                frontmostBundleID: @escaping @MainActor @Sendable () -> String?) {
        self.secureInputOn = secureInputOn
        self.frontmostBundleID = frontmostBundleID
    }

    /// The real Mac: `IsSecureEventInputEnabled()` and the frontmost app.
    public static let system = SecureInputCheck(
        secureInputOn: { IsSecureEventInputEnabled() },
        frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier })

    @MainActor public func shouldSkip() -> Bool {
        secureInputOn() || Self.isPasswordManager(frontmostBundleID())
    }

    public static func isPasswordManager(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return passwordManagers.contains { id == $0 || id.hasPrefix($0 + ".") }
    }
}

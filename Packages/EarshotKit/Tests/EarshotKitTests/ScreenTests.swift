import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import EarshotKit

// MARK: - Shared fixtures (also used by ScreenSamplerTests)

enum ScreenFixtures {
    /// A width x height RGB image, filled white, with `dark` rectangles (in pixel coordinates, origin bottom left)
    /// black.
    static func image(width: Int = 64, height: Int = 64, dark: [CGRect] = []) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        dark.forEach { context.fill($0) }
        return context.makeImage()!
    }

    static let leftDark = image(dark: [CGRect(x: 0, y: 0, width: 32, height: 64)])
    static let rightDark = image(dark: [CGRect(x: 32, y: 0, width: 32, height: 64)])

    /// Text with enough distinct words that two different `n` are never near-duplicates.
    static func slide(_ n: Int) -> String { "Slide \(n) shows alpha\(n) beta\(n) gamma\(n) delta\(n)" }

    static let noSecureInput = SecureInputCheck(secureInputOn: { false }, frontmostBundleID: { "us.zoom.xos" })
}

private let leftDark = ScreenFixtures.leftDark
private let rightDark = ScreenFixtures.rightDark
private func image(width: Int = 64, height: Int = 64, dark: [CGRect] = []) -> CGImage {
    ScreenFixtures.image(width: width, height: height, dark: dark)
}
private func slide(_ n: Int) -> String { ScreenFixtures.slide(n) }
private let noSecureInput = ScreenFixtures.noSecureInput

/// A hash whose first `count` bits are set.
private func hash(setBits count: Int) -> ImageHash {
    var words = [UInt64](repeating: 0, count: 4)
    for bit in 0..<count { words[bit / 64] |= 1 << UInt64(bit % 64) }
    return ImageHash(words: words)
}

// MARK: - Hashing and the frame filter

struct ScreenHashTests {
    @Test func theSameImageHashesTheSame() throws {
        let a = try #require(ImageHash.average16(leftDark))
        let b = try #require(ImageHash.average16(leftDark))
        #expect(a == b)
        #expect(ImageHash.difference(a, b) == 0)
    }

    @Test func mirroredHalvesDifferInEveryBit() throws {
        let a = try #require(ImageHash.average16(leftDark))
        let b = try #require(ImageHash.average16(rightDark))
        #expect(ImageHash.difference(a, b) == 1)
        #expect(ImageHash.difference(b, a) == 1)
    }

    @Test func aSmallMarkChangesFewBits() throws {
        let plain = try #require(ImageHash.average16(leftDark))
        let marked = try #require(ImageHash.average16(image(dark: [CGRect(x: 0, y: 0, width: 32, height: 64),
                                                                    CGRect(x: 60, y: 60, width: 4, height: 4)])))
        #expect(ImageHash.difference(plain, marked) <= 0.12)
    }
}

struct ScreenFrameFilterTests {
    @Test func theRulesAreTheSpecNumbers() {
        #expect(ScreenFrameFilter.hashThreshold == 0.12)
        #expect(ScreenFrameFilter.minCharacters == 20)
        #expect(ScreenFrameFilter.nearDuplicate == 0.8)
        #expect(ScreenFrameFilter.maxMoments == 120)
    }

    @Test func theFirstFrameIsAlwaysRead() {
        #expect(ScreenFrameFilter().needsReading(hash(setBits: 0)))
    }

    @Test func aFrameIsReadOnlyWhenMoreThanTwelvePercentOfBitsChanged() {
        let filter = ScreenFrameFilter().keeping(hash: hash(setBits: 0), text: slide(1))
        #expect(!filter.needsReading(hash(setBits: 0)))
        #expect(!filter.needsReading(hash(setBits: 30)))  // 11.7%
        #expect(filter.needsReading(hash(setBits: 31)))  // 12.1%
    }

    @Test func textUnderTwentyCharactersIsDropped() {
        let filter = ScreenFrameFilter()
        #expect(!filter.accepts("Nineteen Chars Here!"))  // 17 without spaces
        #expect(!filter.accepts("TwentyCharsExactly!"))
        #expect(!filter.accepts("   \n  "))
        #expect(filter.accepts("TwentyCharsExactly!!"))
        #expect(filter.accepts(" Twenty Chars Exactly!! "))
    }

    @Test func nearDuplicateTextOfTheLastKeptFrameIsDropped() {
        let filter = ScreenFrameFilter().keeping(hash: hash(setBits: 0), text: "Q3 revenue grew 42 percent in Europe and Asia")
        #expect(!filter.accepts("Q3 revenue grew 42 percent in Europe and Asia"))
        #expect(!filter.accepts("q3 REVENUE grew 42 percent in europe and asia."))
        #expect(filter.accepts("Hiring plan for 2027 with three new engineers"))
    }

    @Test func nothingIsKeptAfterTheCap() {
        var filter = ScreenFrameFilter()
        for n in 0..<ScreenFrameFilter.maxMoments { filter = filter.keeping(hash: hash(setBits: n % 2 * 200), text: slide(n)) }
        #expect(filter.keptCount == 120)
        #expect(filter.isFull)
        #expect(!filter.needsReading(hash(setBits: 255)))
        #expect(!filter.accepts(slide(999)))
    }

    @Test func keepingReturnsANewFilterAndLeavesTheOldOne() {
        let empty = ScreenFrameFilter()
        let kept = empty.keeping(hash: hash(setBits: 3), text: slide(1))
        #expect(empty.keptCount == 0 && empty.lastHash == nil)
        #expect(kept.keptCount == 1 && kept.lastHash == hash(setBits: 3) && kept.lastText == slide(1))
    }
}

// MARK: - Redaction

struct ScreenRedactionTests {
    @Test func removesAnAnthropicStyleKey() {
        let out = ScreenRedaction.clean("Set ANTHROPIC_KEY to sk-ant-api03-AbCdEf1234567890_xyzXYZ-0987 before you start")
        #expect(!out.contains("sk-ant"))
        #expect(!out.contains("AbCdEf1234567890"))
        #expect(out.contains("before you start"))
    }

    @Test func removesTwelveDigitNumbersButKeepsShortOnes() {
        let out = ScreenRedaction.clean("Account 123456789012 owes 4500 dollars by 20261015")
        #expect(!out.contains("123456789012"))
        #expect(out.contains("4500"))
        #expect(out.contains("20261015"))  // eight digits stay
        #expect(!ScreenRedaction.clean("ref 123456789 done").contains("123456789"))
    }

    @Test func dropsPasswordPasscodeAndPinLines() {
        let out = ScreenRedaction.clean("""
        Welcome to the quarterly review
        password: hunter2
        Passcode 8812
        Your PIN is 4421
        Meeting ID 812 3456 7890
        Dial-in +1 555 0100
        Spinning up the new region
        """)
        #expect(!out.contains("hunter2"))
        #expect(!out.lowercased().contains("passcode"))
        #expect(!out.contains("4421"))
        #expect(!out.contains("812 3456"))
        #expect(!out.contains("555 0100"))
        #expect(out.contains("Welcome to the quarterly review"))
        #expect(out.contains("Spinning up the new region"))
    }

    @Test func replacesLinksLikeTheAgenda() {
        let out = ScreenRedaction.clean("Join at https://zoom.us/j/123?pwd=abc or zoom.us/j/999 or www.example.com/x today")
        #expect(out == "Join at [link] or [link] or [link] today")
        #expect(ScreenRedaction.clean("See https://example.com/a.") == "See [link].")
    }

    @Test func removesCommonKeyAndTokenShapes() {
        let secrets = [
            "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
            "github_pat_11ABCDEFG0123456789_abcdefghijklmnop",
            "xoxb-1234567890-abcdefghijkl",
            "AKIAIOSFODNN7EXAMPLE",
            "AIzaSyA1234567890abcdefghijklmnopqrstu",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            "Bearer abcDEF123456ghiJKL789012",
            "token = 9f8e7d6c5b4a39281706f5e4d3c2b1a0ffeeddcc",
            "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "DB_SECRET=hunter2hunter2",
            "MY_API_TOKEN=abc123def",
            "client_secret=abc123",
            "x-api-token: abc123def456",
            "\"api_key\": \"abc123\"",
        ]
        for secret in secrets {
            let out = ScreenRedaction.clean("before \(secret) after")
            #expect(!out.contains(secret), "\(secret) survived: \(out)")
            #expect(out.hasPrefix("before") && out.hasSuffix("after"))
        }
    }

    @Test func envStyleSecretValuesNeverSurvive() {
        let out = ScreenRedaction.clean("export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        #expect(out == "export [redacted]")
    }

    @Test func cardNumbersAndIBANsInGroupsAreRemoved() {
        for number in ["4111 1111 1111 1111", "4111-1111-1111-1111", "3782 822463 10005", "GB82 WEST 1234 5698 7654 32",
                       "DE89370400440532013000"] {
            let out = ScreenRedaction.clean("Pay \(number) today")
            #expect(out == "Pay [number] today", "\(number) gave \(out)")
        }
        for kept in ["Years 2024 2025 2026 2027", "From 2026-10-15 2026-10-16", "Room 4111 1111 1111 1112"] {
            #expect(ScreenRedaction.clean(kept) == kept)
        }
        #expect(ScreenRedaction.passesLuhn("4111 1111 1111 1111"))
        #expect(!ScreenRedaction.passesLuhn("4111 1111 1111 1112"))
    }

    @Test func dropsEveryFormOfTheAgendaSecretLines() {
        for line in ["PINs: 4421", "Pass code 8812", "pass-code 8812", "Passcodes below", "Dial ins below",
                     "dial-ins: +1 555 0100", "Meeting IDs 812", "meeting-id 812", "DB_PASSWORD=hunter2",
                     "USER_PIN=4421", "Passwords rotate Friday",
                     "PASSWD=abc123"] {
            #expect(ScreenRedaction.clean("Keep this line\n\(line)") == "Keep this line", "\(line)")
        }
    }

    @Test func keepsLinesThatOnlyLookLikeSecretWords() {
        for line in ["Meeting ideas for Q3", "Spinning up the new region", "Ping me after", "Compass codes on the map",
                     "Pinned items"] {
            #expect(ScreenRedaction.clean(line) == line)
        }
    }

    @Test func addressesKeepOnlyTheirDomainAndNoAtSignIsLeft() {
        #expect(ScreenRedaction.clean("Owner jane.doe@acme.com today") == "Owner [address at acme.com] today")
        #expect(ScreenRedaction.clean("jane@acme.com") == "[address at acme.com]")
        #expect(ScreenRedaction.clean("Mail mailto:x@y.com or tel:+15550100 now") == "Mail [link] or [link] now")
        #expect(ScreenRedaction.clean("Ping me @ the office") == "Ping me at the office")
        for text in ["jane.doe@acme.com", "mailto:x@y.com", "Bob <bob@CORP.example.co.uk>", "@here look", "a@b"] {
            #expect(!ScreenRedaction.clean(text).contains("@"), "\(text)")
        }
    }

    /// The agenda cleaner's own output for this sample, so the screen and the agenda can't drift apart.
    @Test func aSharedSampleComesOutAsTheAgendaCleanerLeavesIt() {
        let sample = """
        Weekly sync with jane.doe@acme.com and Bob <bob@corp.example.co.uk>
        Join https://meet.google.com/abc-defg-hij, or zoom.us/j/123456?pwd=x.
        Email mailto:x@y.com or call tel:+15550100 today
        PINs: 4421
        Pass code 8812
        Dial-ins listed below
        Meeting ID 812 3456 7890
        Meeting ideas for Q3
        Ping me @ the office
        Spinning up www.example.com/docs (see notes)
        """
        let agenda = """
        Weekly sync with [address at acme.com] and Bob <[address at corp.example.co.uk]>
        Join [link], or [link].
        Email [link] or call [link] today
        Meeting ideas for Q3
        Ping me at the office
        Spinning up [link] (see notes)
        """
        #expect(ScreenRedaction.clean(sample) == agenda)
        #expect(AgendaSanitizer.clean(sample) == agenda)
    }

    /// Spec 9: the same redaction as the agenda. Every line the agenda drops, the screen drops; every line the agenda
    /// keeps is cleaned the same way, unless a screen rule finds a password, PIN, key or long number in it.
    @Test func theScreenUsesTheAgendaSecretLineRule() {
        let agendaSecrets = ["Phone conference ID: 123 456#", "Conference-IDs below", "Access code: 2468",
                             "Access-codes are on the card", "PIN 4455", "pin: 7788", "Pin #12", "PINs: 4421",
                             "Pass code 8812", "Meeting ID 812", "Dial-in: +1 555 0100", "Passwords rotate Friday"]
        for line in agendaSecrets {
            #expect(AgendaSanitizer.isSecret(line), "\(line)")
            #expect(ScreenRedaction.clean("Keep this line\n\(line)") == "Keep this line", "\(line)")
        }
        // The agenda's PIN rule: "pin" as a word counts only in capitals or before ":", "#" or a digit. The screen is
        // stricter (spec 9): any line with "pin" as a word goes, so these stay only in the agenda.
        for line in ["Pin down Q4 price", "Pins for the booth", "Pin-up board"] {
            #expect(!AgendaSanitizer.isSecret(line), "\(line)")
            #expect(AgendaSanitizer.clean(line) == line, "\(line)")
            #expect(ScreenRedaction.clean("Keep this line\n\(line)") == "Keep this line", "\(line)")
        }
        let kept = ["Pinned items", "PINNED ITEMS", "Spinning up the new region",
                    "Ping me after", "Meeting ideas for Q3", "Compass codes on the map",
                    "Ask josé@acme.com and Dana.O\u{2019}Brien@acme.com", "Ping bob@intranet today", "Notes at www.acme.com/q4."]
        for line in kept {
            #expect(!AgendaSanitizer.isSecret(line), "\(line)")
            #expect(ScreenRedaction.clean(line) == AgendaSanitizer.clean(line), "\(line)")
        }
    }

    @Test func theScreenAlsoDropsEnvStyleSecretNames() {
        for line in ["DB_PASSWORD=hunter2", "USER_PIN=4421", "user_pin: 4421", "pin_code = 4421", "USER_PINS=1,2",
                     "PASSWD=abc123", "export MYPASSWORD=x", "the passcode is on the card",
                     "pin=4821", "Pin = 4821", "pin-code: 4821", "my pin is 4821", "Your pin is 4821"] {
            #expect(ScreenRedaction.clean("Keep this line\n\(line)") == "Keep this line", "\(line)")
        }
    }

    @Test func keepsOrdinaryTextAndDropsBlankLines() {
        #expect(ScreenRedaction.clean("  Roadmap 2027  \n\n\n  Hire two engineers \n") == "Roadmap 2027\nHire two engineers")
        #expect(ScreenRedaction.clean("") == "")
    }

    @Test func dropsPrivateKeyBlocks() {
        let out = ScreenRedaction.clean("Deploy notes\n-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\n-----END RSA PRIVATE KEY-----\nShip it")
        #expect(!out.contains("PRIVATE KEY"))
        #expect(out.hasPrefix("Deploy notes") && out.hasSuffix("Ship it"))
    }
}

// MARK: - Choosing moments for the notes

struct ScreenSelectionTests {
    private func moment(_ offset: Double, _ size: Int = 100) -> ScreenMoment {
        let head = "m\(Int(offset)) "
        return ScreenMoment(offset: offset, text: head + String(repeating: "x", count: max(0, size - head.count)))
    }

    @Test func emptyInputsGiveNothing() {
        #expect(ScreenSelection.excerpts(moments: [], flags: [], segments: []).isEmpty)
    }

    @Test func everythingFitsWhenSmallAndComesBackInTimeOrder() {
        let moments = [moment(300), moment(15), moment(120)]
        let out = ScreenSelection.excerpts(moments: moments, flags: [], segments: [])
        #expect(out.map(\.offset) == [15, 120, 300])
        #expect(out.map(\.text) == [moment(15).text, moment(120).text, moment(300).text])
    }

    @Test func momentsNearAFlagComeFirst() {
        let moments = (0..<20).map { moment(Double($0) * 100, 1000) }
        let out = ScreenSelection.excerpts(moments: moments, flags: [Flag(offset: 1250, source: .hotkey)], segments: [],
                                           limit: 1000)
        #expect(out.map(\.offset) == [1200])  // 50 s from the flag; 1300 is 50 s too but further in tie order
    }

    @Test func flagWindowIsSixtySeconds() {
        let moments = [moment(0, 1000), moment(500, 1000)]
        let near = ScreenSelection.excerpts(moments: moments, flags: [Flag(offset: 560, source: .panel)], segments: [], limit: 1000)
        #expect(near.map(\.offset) == [500])
        let far = ScreenSelection.excerpts(moments: moments, flags: [Flag(offset: 561, source: .panel)], segments: [], limit: 1000)
        #expect(far.map(\.offset) == [0])
    }

    @Test func pointingAtTheScreenComesNext() {
        let moments = (0..<20).map { moment(Double($0) * 100, 1000) }
        let segments = [Segment(track: .them, start: 700, end: 720, text: "So if you look at this chart here"),
                        Segment(track: .me, start: 1520, end: 1530, text: "Nothing to see")]
        let out = ScreenSelection.excerpts(moments: moments, flags: [Flag(offset: 1210, source: .voice)],
                                           segments: segments, limit: 2100)
        #expect(out.map(\.offset) == [700, 1200])
    }

    @Test func everyPointerPhraseCounts() {
        for phrase in ["this slide", "this number", "on screen", "you can see", "as shown", "this chart"] {
            let moments = [moment(0, 1000), moment(500, 1000)]
            let segments = [Segment(track: .them, start: 520, end: 525, text: "Well, \(phrase.uppercased()) matters")]
            let out = ScreenSelection.excerpts(moments: moments, flags: [], segments: segments, limit: 1000)
            #expect(out.map(\.offset) == [500], "\(phrase)")
        }
    }

    @Test func pointerWindowIsThirtySecondsFromTheLine() {
        let moments = [moment(0, 1000), moment(500, 1000)]
        let inside = [Segment(track: .them, start: 530, end: 540, text: "as shown")]
        let outside = [Segment(track: .them, start: 531, end: 540, text: "as shown")]
        #expect(ScreenSelection.excerpts(moments: moments, flags: [], segments: inside, limit: 1000).map(\.offset) == [500])
        #expect(ScreenSelection.excerpts(moments: moments, flags: [], segments: outside, limit: 1000).map(\.offset) == [0])
    }

    @Test func theRestIsSpreadEvenly() {
        let moments = (0..<9).map { moment(Double($0) * 60, 1000) }
        let out = ScreenSelection.excerpts(moments: moments, flags: [], segments: [], limit: 3100)
        #expect(out.map(\.offset) == [120, 240, 360])
    }

    @Test func theSpreadFollowsTimeWhenMomentsBunchUp() {
        // 90 moments in the first 9 minutes of slides, then 10 across the next 50 minutes.
        let dense = (0..<90).map { moment(Double($0) * 6, 300) }
        let sparse = (1...10).map { moment(540 + Double($0) * 300, 300) }
        let out = ScreenSelection.excerpts(moments: dense + sparse, flags: [], segments: [], limit: 8 * 316)
        #expect(out.count == 8)
        #expect(out.filter { $0.offset > 540 }.count >= 6)
        #expect(out.contains { $0.offset >= 3000 })
        #expect(ScreenSelection.spread([]).isEmpty)
        #expect(Set(ScreenSelection.spread(dense + sparse)) == Set(0..<100))
    }

    @Test func theTotalStaysWithinTheLimit() {
        let moments = (0..<200).map { moment(Double($0) * 15, 333) }
        let out = ScreenSelection.excerpts(moments: moments, flags: [], segments: [])
        #expect(ScreenSelection.limit == 8000)
        // The block NotesPrompt puts inside <screen_text>, "At mm:ss:" lines and blank lines included.
        let block = out.map { "At \(NotesRenderer.clock($0.offset)):\n\($0.text)" }.joined(separator: "\n\n")
        #expect(block.count <= 8000)
        #expect(out.count == 8000 / (333 + ScreenSelection.excerptOverhead))
        let hours = (0..<30).map { moment(Double($0) * 400 + 360_000, 300) }  // clocks past 100 minutes
        let long = ScreenSelection.excerpts(moments: hours, flags: [], segments: [])
        #expect(long.map { "At \(NotesRenderer.clock($0.offset)):\n\($0.text)" }.joined(separator: "\n\n").count <= 8000)
    }

    @Test func storedTextIsRedactedAgainAndEmptyMomentsAreDropped() {
        let moments = [ScreenMoment(offset: 5, text: "Budget review\npassword: hunter2"),
                       ScreenMoment(offset: 9, text: "PIN 1234")]
        let out = ScreenSelection.excerpts(moments: moments, flags: [], segments: [])
        #expect(out == [Excerpt(offset: 5, text: "Budget review")])
    }

    @Test func aHugeMomentIsClippedToTheLimit() {
        let out = ScreenSelection.excerpts(moments: [moment(10, 20_000)], flags: [], segments: [])
        #expect(out.count == 1 && out[0].text.count == 8000 - ScreenSelection.excerptOverhead)
    }
}

// MARK: - The secure check

@MainActor
struct SecureInputCheckTests {
    @Test func secureTextInputSkips() {
        #expect(SecureInputCheck(secureInputOn: { true }, frontmostBundleID: { "us.zoom.xos" }).shouldSkip())
        #expect(!noSecureInput.shouldSkip())
    }

    @Test func eachPasswordManagerFrontmostSkips() {
        let ids = ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
                   "com.dashlane.Dashlane", "com.keepersecurity.passwordmanager", "com.apple.Passwords",
                   "com.apple.keychainaccess"]
        for id in ids {
            #expect(SecureInputCheck(secureInputOn: { false }, frontmostBundleID: { id }).shouldSkip(), "\(id)")
        }
        for id in ["com.google.Chrome", "us.zoom.xos", "com.apple.Safari", "com.apple.passwordsx"] {
            #expect(!SecureInputCheck.isPasswordManager(id), "\(id)")
        }
        #expect(!SecureInputCheck.isPasswordManager(nil))
    }
}

// MARK: - The capturer's pure parts (the real capture is never run in tests)

struct ScreenCaptureKitCapturerTests {
    @Test func matchesTheCallAppByBundlePrefix() {
        #expect(ScreenCaptureKitCapturer.matches("us.zoom.xos", prefix: "us.zoom"))
        #expect(ScreenCaptureKitCapturer.matches("com.google.Chrome", prefix: "com.google.chrome"))
        #expect(ScreenCaptureKitCapturer.matches("com.microsoft.teams2", prefix: "com.microsoft.teams"))
        #expect(!ScreenCaptureKitCapturer.matches("com.apple.Safari", prefix: "us.zoom"))
        #expect(!ScreenCaptureKitCapturer.matches("us.zoom.xos", prefix: ""))
    }

    @Test func picksTheDisplayShowingMostOfTheWindows() {
        let displays = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        #expect(ScreenCaptureKitCapturer.bestIndex(showing: [CGRect(x: 900, y: 0, width: 300, height: 300)], among: displays) == 1)
        #expect(ScreenCaptureKitCapturer.bestIndex(showing: [CGRect(x: 10, y: 10, width: 50, height: 50)], among: displays) == 0)
        #expect(ScreenCaptureKitCapturer.bestIndex(showing: [], among: displays) == nil)
        #expect(ScreenCaptureKitCapturer.bestIndex(showing: [CGRect(x: 5000, y: 0, width: 10, height: 10)], among: displays) == nil)
    }

    @Test func theFrameIsAtMostMaxWidthWithItsShapeKept() {
        let big = ScreenCaptureKitCapturer.outputSize(points: CGSize(width: 1000, height: 500), scale: 2, maxWidth: 1440)
        #expect(big.width == 1440 && big.height == 720)
        let small = ScreenCaptureKitCapturer.outputSize(points: CGSize(width: 600, height: 400), scale: 1, maxWidth: 1440)
        #expect(small.width == 600 && small.height == 400)
    }

    @Test func unionCoversEveryWindow() {
        #expect(ScreenCaptureKitCapturer.union([]) == nil)
        #expect(ScreenCaptureKitCapturer.union([CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 20, y: 5, width: 10, height: 10)])
                == CGRect(x: 0, y: 0, width: 30, height: 15))
    }

    // MARK: Choosing the windows

    private typealias Window = ScreenCaptureKitCapturer.WindowInfo
    private static let me: pid_t = 100
    private static let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private static let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)

    private func window(_ id: CGWindowID, pid: pid_t? = 200, _ bundle: String = "us.zoom.xos", layer: Int = 0,
                        onScreen: Bool = true, frame: CGRect = CGRect(x: 10, y: 10, width: 400, height: 300)) -> Window {
        Window(id: id, pid: pid, bundleID: bundle, layer: layer, onScreen: onScreen, frame: frame)
    }

    private func plan(_ windows: [Window], prefix: String = "us.zoom.", order: [CGWindowID] = [])
        -> ScreenCaptureKitCapturer.Plan? {
        ScreenCaptureKitCapturer.plan(windows: windows, displays: [Self.left, Self.right], me: Self.me, prefix: prefix,
                                      frontToBack: order)
    }

    @Test func onlyTheCallAppsNormalOnScreenWindowsAreChosenNeverEarshots() {
        let windows = [
            window(1),
            window(2, pid: Self.me, "us.zoom.xos"),  // Earshot itself, even under a matching id
            window(3, onScreen: false),
            window(4, layer: 3),  // a floating panel or overlay
            window(5, frame: CGRect(x: 0, y: 0, width: 1, height: 1)),
            window(6, pid: nil),
            window(7, pid: 300, "com.tinyspeck.slackmacgap"),
            window(8, frame: CGRect(x: 500, y: 400, width: 200, height: 100)),
        ]
        let chosen = plan(windows)
        #expect(chosen?.windows == [0, 7])
        #expect(chosen?.display == 0)
        #expect(chosen?.source == CGRect(x: 10, y: 10, width: 690, height: 490))
        #expect(plan(windows, prefix: "com.apple.FaceTime") == nil)
    }

    @Test func onlyWindowsOnTheChosenDisplayAreKept() {
        let windows = [window(1, frame: CGRect(x: 1100, y: 0, width: 800, height: 600)),
                       window(2, frame: CGRect(x: 10, y: 10, width: 100, height: 100))]
        let chosen = plan(windows)
        #expect(chosen?.display == 1)
        #expect(chosen?.windows == [0])
        #expect(chosen?.source == CGRect(x: 100, y: 0, width: 800, height: 600))
    }

    @Test func aBrowserCallCapturesOnlyTheFrontmostBrowserWindow() {
        let windows = [window(11, "com.google.Chrome"), window(12, "com.google.Chrome"), window(13, "com.google.Chrome"),
                       window(14, pid: Self.me, "com.google.Chrome")]
        // Front to back: another app's window, Earshot's own, then the Meet tab's window, then the user's mail.
        #expect(plan(windows, prefix: "com.google.Chrome", order: [99, 14, 12, 11, 13])?.windows == [1])
        #expect(plan(windows, prefix: "com.google.Chrome.helper", order: [13, 12])?.windows == [2])
        // Without the window order, no browser window is captured rather than all of them.
        #expect(plan(windows, prefix: "com.google.Chrome", order: []) == nil)
        #expect(plan(windows, prefix: "com.google.Chrome", order: [99]) == nil)
    }

    @Test func aDedicatedCallAppKeepsAllItsWindows() {
        let windows = [window(1), window(2, frame: CGRect(x: 600, y: 0, width: 300, height: 300))]
        #expect(plan(windows, order: [2])?.windows == [0, 1])
    }

    @Test func safarisWebKitHelperFindsSafarisWindows() {
        #expect(ScreenCaptureKitCapturer.windowOwnerPrefix("com.apple.WebKit.GPU") == "com.apple.Safari")
        #expect(ScreenCaptureKitCapturer.windowOwnerPrefix("com.apple.WebKit") == "com.apple.Safari")
        #expect(ScreenCaptureKitCapturer.windowOwnerPrefix("com.google.Chrome.helper") == "com.google.Chrome")
        #expect(ScreenCaptureKitCapturer.windowOwnerPrefix("com.microsoft.teams2.helper") == "com.microsoft.teams2")
        #expect(ScreenCaptureKitCapturer.windowOwnerPrefix("us.zoom.") == "us.zoom.")
        #expect(ScreenCaptureKitCapturer.isBrowser("com.apple.safari"))
        #expect(!ScreenCaptureKitCapturer.isBrowser("us.zoom."))
        let windows = [window(21, "com.apple.Safari"), window(22, "com.apple.Safari")]
        #expect(plan(windows, prefix: "com.apple.WebKit.GPU", order: [22, 21])?.windows == [1])
    }

    @Test func wholeDisplayCaptureLeavesOutEarshotsOwnApps() {
        #expect(ScreenCaptureKitCapturer.ownApplicationIndices(pids: [1, Self.me, 300, Self.me], me: Self.me) == [1, 3])
        #expect(ScreenCaptureKitCapturer.ownApplicationIndices(pids: [1, 2], me: Self.me).isEmpty)
    }
}

// MARK: - Device: real OCR on rendered text

@Suite(.enabled(if: deviceTests, "needs EARSHOT_DEVICE_TESTS=1"))
struct DeviceScreenTests {
    /// Black text on white, drawn with Core Text; never a real screen capture.
    private func rendered(_ lines: [String]) -> CGImage {
        let width = 1400, lineHeight = 90
        let context = CGContext(data: nil, width: width, height: lineHeight * (lines.count + 1), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: context.height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 56, nil)
        for (index, text) in lines.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: 40, y: context.height - lineHeight * (index + 1))
            CTLineDraw(line, context)
        }
        return context.makeImage()!
    }

    @Test func readsRenderedTextOnDevice() async throws {
        let text = try await VisionTextRecognizer().recognize(rendered(["Quarterly revenue grew 42 percent",
                                                                         "Next review on Friday"]))
        #expect(text.contains("revenue"))
        #expect(text.contains("42"))
        #expect(text.contains("Friday"))
        #expect(text.split(separator: "\n").count >= 2)
    }
}

import Foundation
import Testing
@testable import EarshotKit

/// Where the webhook may send the meeting (shared by the app and the CLI): https anywhere, plain http only to this
/// Mac or the local network, and never with a user name or password in the URL.
struct WebhookURLPolicyTests {
    private func allows(_ text: String) -> Bool {
        guard let url = URL(string: text) else { return false }
        return WebhookURLPolicy.allows(url)
    }

    @Test func httpsIsAlwaysAllowed() {
        for text in ["https://example.com/hook", "https://hooks.example.co.uk:8443/a/b?x=1", "https://8.8.8.8/hook",
                     "HTTPS://Example.com/hook", "https://localhost/hook"] {
            #expect(allows(text), "\(text)")
        }
    }

    @Test func plainHTTPOnlyReachesThisMacOrTheLocalNetwork() {
        let local = ["http://localhost:8080/hook", "http://LOCALHOST/hook", "http://localhost./hook", "http://127.0.0.1/hook",
                     "http://127.0.0.1:5678/webhook/earshot", "http://[::1]:9000/hook", "http://printer.local/hook",
                     "http://my-mac.LOCAL./hook", "http://10.0.0.5/hook", "http://10.255.255.255/",
                     "http://172.16.0.1/hook", "http://172.31.255.255/hook", "http://192.168.1.10:5678/hook",
                     "http://100.64.0.1/hook", "http://100.127.255.255/hook"]
        for text in local { #expect(allows(text), "\(text)") }
        let remote = ["http://example.com/hook", "http://8.8.8.8/hook", "http://172.15.255.255/", "http://172.32.0.1/",
                      "http://100.63.255.255/", "http://100.128.0.1/", "http://192.169.0.1/", "http://11.0.0.1/",
                      "http://10.0.0.1.example.com/", "http://localhost.example.com/", "http://example.local.com/",
                      "http://local/", "http://010.0.0.1/", "http://10.0.0/", "http://10.0.0.256/", "http://0x0a000001/",
                      "http://[::ffff:10.0.0.1]/", "http://[fe80::1]/", "http://127.0.0.2/"]
        for text in remote { #expect(!allows(text), "\(text)") }
    }

    @Test func credentialsOtherSchemesAndMissingHostsAreRefused() {
        for text in ["https://user:pass@example.com/hook", "https://user@example.com/hook", "https://:pass@example.com/hook",
                     "http://user:pass@localhost/hook", "ftp://example.com/hook", "file:///tmp/hook", "https:///hook",
                     "example.com/hook", "mailto:a@example.com"] {
            #expect(!allows(text), "\(text)")
        }
    }

    @Test func eachProblemHasAPlainReason() {
        #expect(WebhookURLPolicy.problem("") == WebhookURLPolicy.missingURL)
        #expect(WebhookURLPolicy.problem("   ") == WebhookURLPolicy.missingURL)
        #expect(WebhookURLPolicy.problem("not a url") == WebhookURLPolicy.wrongURL)
        #expect(WebhookURLPolicy.problem("http://example.com/hook") == WebhookURLPolicy.wrongURL)
        #expect(WebhookURLPolicy.problem("https://user:pass@example.com/hook") == WebhookURLPolicy.credentials)
        #expect(WebhookURLPolicy.problem(" https://example.com/hook ") == nil)
        #expect(WebhookURLPolicy.problem("http://192.168.1.10:5678/hook") == nil)
        let reasons = [WebhookURLPolicy.missingURL, WebhookURLPolicy.wrongURL, WebhookURLPolicy.credentials]
        #expect(reasons.allSatisfy { !$0.contains("\u{2014}") && !$0.isEmpty })
        // A refused URL's reason never repeats the URL, which may hold a secret.
        #expect(!WebhookURLPolicy.wrongURL.contains("example"))
    }

    @Test func settingsBuildAWebhookOnlyForAnAllowedURL() async throws {
        var s = EarshotSettings()
        s.webhookOn = true
        let cases: [(String, String?)] = [
            ("", WebhookURLPolicy.missingURL), ("not a url", WebhookURLPolicy.wrongURL),
            ("http://example.com/hook", WebhookURLPolicy.wrongURL),
            ("https://user:pass@example.com/hook", WebhookURLPolicy.credentials),
            ("https://example.com/hook", nil), ("http://localhost:5678/hook", nil),
        ]
        for (url, reason) in cases {
            s.webhookURL = url
            let targets = s.targets(secrets: FakeSecrets(), locate: { _ in nil })
            #expect(targets.map(\.id) == ["webhook"], "\(url)")
            if let reason {
                #expect((targets.first as? UnavailableTarget)?.reason == reason, "\(url)")
                #expect(s.unavailableTargets(locate: { _ in nil }).map(\.id) == ["webhook"])
                #expect(s.doTargetLabels(locate: { _ in nil }).isEmpty)
            } else {
                #expect((targets.first as? WebhookTarget)?.url.absoluteString == url, "\(url)")
            }
        }
        // A refused webhook fails the send with its reason, so the meeting row shows what to fix.
        s.webhookURL = "http://example.com/hook"
        let (payload, folder) = try samplePayload()
        let result = await s.targets(secrets: FakeSecrets(), locate: { _ in nil }).first?
            .send(payload, json: try payload.encoded(), folder: folder)
        #expect(result == DispatchResult(ok: false, detail: WebhookURLPolicy.wrongURL))
    }
}

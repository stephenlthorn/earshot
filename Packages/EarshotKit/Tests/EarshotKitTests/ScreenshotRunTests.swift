import Foundation
import Testing
@testable import EarshotKit

/// The plumbing of `Earshot --render-screenshots`: the launch argument, the scratch folder and the notes page crop.
struct ScreenshotRunTests {
    @Test func withoutTheFlagNothingIsRendered() {
        #expect(ScreenshotRun.request(in: []) == nil)
        #expect(ScreenshotRun.request(in: ["/Applications/Earshot.app/Contents/MacOS/Earshot"]) == nil)
        #expect(ScreenshotRun.request(in: ["Earshot", "--e2e-import", "/tmp/a.m4a"]) == nil)
    }

    @Test func theFlagNeedsAFolder() {
        #expect(ScreenshotRun.request(in: ["Earshot", ScreenshotRun.flag]) == .usage)
        #expect(ScreenshotRun.request(in: ["Earshot", ScreenshotRun.flag, ""]) == .usage)
        #expect(ScreenshotRun.request(in: ["Earshot", ScreenshotRun.flag, "--other"]) == .usage)
    }

    @Test func theFolderFollowsTheFlag() {
        let request = ScreenshotRun.request(in: ["Earshot", "-NSDocumentRevisionsDebugMode", "YES",
                                                 ScreenshotRun.flag, "/tmp/shots"])
        #expect(request == .render(URL(fileURLWithPath: "/tmp/shots", isDirectory: true)))
    }

    @Test func theScratchFolderIsInsideTheOutputFolder() {
        let out = URL(fileURLWithPath: "/tmp/shots", isDirectory: true)
        let scratch = ScreenshotRun.scratchFolder(in: out)
        #expect(scratch.deletingLastPathComponent().standardizedFileURL == out.standardizedFileURL)
        #expect(scratch.lastPathComponent == ScreenshotRun.scratchName)
    }

    @Test func theMeasuringCopyRunsOneScriptThatMarksTheCrop() {
        let html = ScreenshotSamples.notesPageHTML()
        #expect(html.contains("Content-Security-Policy"))
        #expect(html.contains("<section class=\"\(ScreenshotRun.cropSection)\">"))
        let copy = ScreenshotRun.measuringCopy(html)
        #expect(!copy.contains("Content-Security-Policy"))
        #expect(copy.contains("section.\(ScreenshotRun.cropSection)"))
        #expect(copy.contains(ScreenshotRun.cropAttribute))
        #expect(copy.components(separatedBy: "<script>").count == 2)
        #expect(copy.range(of: "<script>")!.lowerBound > copy.range(of: "</main>")!.lowerBound)
    }
}

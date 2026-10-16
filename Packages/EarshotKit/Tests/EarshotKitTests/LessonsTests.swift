import Foundation
import Testing
@testable import EarshotKit

private func lesson(_ id: String, at seconds: Double = 0, kind: Lesson.Kind = .notSent, task: String = "Email the board",
                    title: String = "Acme") -> Lesson {
    Lesson(id: id, date: at1530.addingTimeInterval(seconds), style: .general, kind: kind,
           before: Lesson.Item(task: task, owner: "Stephen"), meetingTitle: title)
}

private func ai(_ task: String, owner: String = "Stephen", due: String? = nil) -> ActionItem {
    ActionItem(task: task, owner: owner, due: due, doer: .ai)
}

/// Spec 6: the lessons file and the lessons a Send records.
struct LessonsTests {}

extension LessonsTests {
    struct Store {
        let url = tempDir().appending(path: "Earshot/lessons.json")
        var store: LessonsStore { LessonsStore(url: url) }
        var aside: URL { url.deletingLastPathComponent().appending(path: "lessons.json.corrupt") }

        func writeRaw(_ text: String) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        @Test func theDefaultFileIsInApplicationSupport() {
            #expect(LessonsStore.defaultURL.path(percentEncoded: false)
                .hasSuffix("Library/Application Support/Earshot/lessons.json"))
        }

        @Test func aMissingFileHasNoLessons() {
            #expect(store.all().isEmpty)
            #expect(store.count == 0)
        }

        @Test func addWritesAVersionedFileNewestFirst() throws {
            try store.add([lesson("old", at: 0)])
            try store.add([lesson("new", at: 60)])
            #expect(store.all().map(\.id) == ["new", "old"])
            #expect(store.count == 2)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(object["version"] as? Int == 1)
            #expect((object["lessons"] as? [Any])?.count == 2)
        }

        @Test func aSingleLessonCanBeAdded() throws {
            try store.add(lesson("one"))
            #expect(store.all().map(\.id) == ["one"])
        }

        @Test func lessonsOfOneSendKeepTheirOrder() throws {
            try store.add([lesson("a"), lesson("b"), lesson("c")])
            #expect(store.all().map(\.id) == ["a", "b", "c"])
        }

        @Test func allIsNewestFirstEvenWhenTheFileIsNot() throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONFiles.write(LessonsFile(lessons: [lesson("old", at: 0), lesson("new", at: 60)]), to: url)
            #expect(store.all().map(\.id) == ["new", "old"])
        }

        @Test func addingTheSameLessonTwiceKeepsOne() throws {
            try store.add([lesson("a")])
            try store.add([lesson("a")])
            #expect(store.count == 1)
        }

        @Test func theFileKeepsAtMost200() throws {
            try store.add((0..<150).map { lesson("first-\($0)", at: Double($0)) })
            try store.add((0..<100).map { lesson("second-\($0)", at: Double(1000 + $0)) })
            let all = store.all()
            #expect(all.count == LessonsStore.maxLessons)
            #expect(all.first?.id == "second-99")
            #expect(all.last?.id == "first-50")
        }

        @Test func everyTextIsClippedTo200Characters() throws {
            let long = String(repeating: "x", count: 300)
            try store.add(Lesson(date: at1530, style: .general, kind: .edited,
                                 before: Lesson.Item(task: long, owner: long, due: long),
                                 after: Lesson.Item(task: long, owner: "Dana", due: "Friday"),
                                 instruction: long, meetingTitle: long))
            let saved = try #require(store.all().first)
            for text in [saved.before?.task, saved.before?.owner, saved.before?.due, saved.after?.task,
                         saved.instruction, saved.meetingTitle] {
                #expect(text?.count == LessonsStore.maxTextLength)
            }
            #expect(saved.after?.owner == "Dana" && saved.after?.due == "Friday")
        }

        @Test func aCorruptFileReadsAsEmptyAndIsKeptAsideWhenWrittenOver() throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not json {".utf8).write(to: url)
            #expect(store.all().isEmpty)
            #expect(store.count == 0)
            try store.add([lesson("fresh")])
            #expect(store.all().map(\.id) == ["fresh"])
            let aside = url.deletingLastPathComponent().appending(path: "lessons.json.corrupt")
            #expect(try String(contentsOf: aside, encoding: .utf8) == "not json {")
        }

        @Test func clearForgetsEverything() throws {
            try writeRaw("not json {")
            try store.add([lesson("a"), lesson("b")])
            #expect(FileManager.default.fileExists(atPath: aside.path))
            try store.clear()
            #expect(store.all().isEmpty)
            #expect(store.count == 0)
            #expect(!FileManager.default.fileExists(atPath: aside.path))
            try store.add([lesson("c")])
            #expect(store.all().map(\.id) == ["c"])
        }

        @Test func clearWithNoFileDoesNothing() throws {
            try store.clear()
            #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        }

        @Test func duplicateIdsInOneAddKeepOne() throws {
            try store.add([lesson("a", task: "First"), lesson("a", task: "Second")])
            #expect(store.all().map(\.id) == ["a"])
            #expect(store.all().first?.before?.task == "First")
        }

        @Test func duplicateIdsAlreadyInTheFileAreRemovedOnTheNextAdd() throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONFiles.write(LessonsFile(lessons: [lesson("a", at: 0), lesson("a", at: 0)]), to: url)
            try store.add([lesson("b", at: 60)])
            #expect(store.all().map(\.id) == ["b", "a"])
        }

        @Test func anEmptyInstructionIsNotSaved() throws {
            let blank = LessonDiff.instruction("  \n\t ", style: .general, title: "Acme", date: at1530)
            try store.add(blank)
            #expect(store.count == 0)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            try store.add([blank, lesson("kept")])
            #expect(store.all().map(\.id) == ["kept"])
            try store.add(Lesson(date: at1530, style: .general, kind: .instruction, meetingTitle: "Acme"))
            #expect(store.count == 1)
        }

        @Test func aLessonThisVersionCantReadIsKeptAsideBeforeAWrite() throws {
            let original = """
            {"version": 1, "lessons": [
              {"id": "future", "date": "2026-10-14T15:30:00Z", "style": "general", "kind": "future_kind",
               "meetingTitle": "Acme"},
              {"id": "known", "date": "2026-10-14T15:30:00Z", "style": "general", "kind": "not_sent",
               "before": {"task": "Email the board", "owner": "Stephen"}, "meetingTitle": "Acme"}
            ]}
            """
            try writeRaw(original)
            #expect(store.all().map(\.id) == ["known"])
            try store.add([lesson("fresh", at: 3600 * 24)])
            #expect(store.all().map(\.id) == ["fresh", "known"])
            #expect(try String(contentsOf: aside, encoding: .utf8) == original)
        }

        @Test func lessonsThatAreNotAListAreKeptAsideBeforeAWrite() throws {
            let original = #"{"version": 1, "lessons": {"id": "odd"}}"#
            try writeRaw(original)
            #expect(store.all().isEmpty)
            try store.add([lesson("fresh")])
            #expect(store.all().map(\.id) == ["fresh"])
            #expect(try String(contentsOf: aside, encoding: .utf8) == original)
        }

        @Test func aStyleThisVersionCantReadIsKeptAsideBeforeAWrite() throws {
            let original = """
            {"version": 1, "lessons": [{"id": "styled", "date": "2026-10-14T15:30:00Z", "style": "future_style",
              "kind": "not_sent", "meetingTitle": "Acme"}]}
            """
            try writeRaw(original)
            try store.add([lesson("fresh", at: 3600 * 24)])
            #expect(store.all().map(\.id) == ["fresh", "styled"])
            #expect(try String(contentsOf: aside, encoding: .utf8) == original)
        }

        @Test func unknownTopLevelKeysAreKeptAsideBeforeAWrite() throws {
            let original = #"{"version": 1, "lessons": [], "rules": ["keep me"]}"#
            try writeRaw(original)
            try store.add([lesson("fresh")])
            #expect(try String(contentsOf: aside, encoding: .utf8) == original)
        }

        @Test func aFileThisVersionReadsInFullIsNotKeptAside() throws {
            try store.add([lesson("a", at: 0)])
            try store.add([lesson("b", at: 60)])
            try writeRaw(#"{"lessons": []}"#)
            try store.add([lesson("c", at: 120)])
            #expect(!FileManager.default.fileExists(atPath: aside.path))
        }

        @Test func aNewerVersionsFileIsNeverRewritten() throws {
            let original = """
            {"version": 2, "lessons": [
              {"id": "known", "date": "2026-10-14T15:30:00Z", "style": "general", "kind": "not_sent",
               "meetingTitle": "Acme"}
            ]}
            """
            try writeRaw(original)
            #expect(store.all().map(\.id) == ["known"])
            #expect(throws: LessonsStore.Failure.newerFile) { try store.add([lesson("fresh")]) }
            #expect(try String(contentsOf: url, encoding: .utf8) == original)
            #expect(!FileManager.default.fileExists(atPath: aside.path))
        }

        @Test func anUnreadableFileMakesAddThrowAndIsLeftAlone() throws {
            try store.add([lesson("saved")])
            let original = try Data(contentsOf: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
            #expect(throws: (any Error).self) { try store.add([lesson("fresh")]) }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            #expect(try Data(contentsOf: url) == original)
            #expect(!FileManager.default.fileExists(atPath: aside.path))
        }

        @Test func aFolderInPlaceOfTheFileMakesAddThrow() throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            #expect(throws: (any Error).self) { try store.add([lesson("fresh")]) }
            #expect(!FileManager.default.fileExists(atPath: aside.path))
        }

        @Test func aWriterThatCantGetTheLockGivesUp() throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let lockPath = url.deletingLastPathComponent().appending(path: ".lessons.json.lock").path
            let holder = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
            try #require(holder >= 0)
            defer { close(holder) }
            try #require(flock(holder, LOCK_EX) == 0)
            let impatient = LessonsStore(url: url, lockWait: .milliseconds(100))
            #expect(throws: LessonsStore.Failure.busy) { try impatient.add([lesson("fresh")]) }
            #expect(throws: LessonsStore.Failure.busy) { try impatient.clear() }
            flock(holder, LOCK_UN)
            try impatient.add([lesson("fresh")])
            #expect(store.all().map(\.id) == ["fresh"])
        }

        @Test func anotherWritersLessonsSurvive() throws {
            let app = LessonsStore(url: url)
            let cli = LessonsStore(url: url)
            try app.add([lesson("app", at: 0)])
            try cli.add([lesson("cli", at: 60)])
            try app.add([lesson("app2", at: 120)])
            #expect(app.all().map(\.id) == ["app2", "cli", "app"])
        }

        @Test func concurrentWritersNeverLoseALesson() async throws {
            let url = self.url
            await withTaskGroup(of: Void.self) { group in
                for n in 0..<24 {
                    group.addTask { try? LessonsStore(url: url).add([lesson("w\(n)", at: Double(n))]) }
                }
            }
            #expect(Set(store.all().map(\.id)) == Set((0..<24).map { "w\($0)" }))
        }
    }

}

extension LessonsTests {
    struct Diff {
        let shown = [ai("Draft the scope email"), ai("Book the venue"), ai("Call Dana"), ai("Order lunch")]

        func diff(baseline: Set<Int>, final: [(index: Int, item: ActionItem)]) -> [Lesson] {
            LessonDiff.lessons(shown: shown, baseline: baseline, final: final, style: .salesCall, title: "Acme",
                               date: at1530)
        }

        @Test func noChangeGivesNoLessons() {
            #expect(diff(baseline: [0, 1], final: [(0, shown[0]), (1, shown[1])]).isEmpty)
            #expect(diff(baseline: [], final: []).isEmpty)
        }

        @Test func aDefaultItemUntickedIsNotSent() throws {
            let lessons = diff(baseline: [0, 1], final: [(0, shown[0])])
            let only = try #require(lessons.first)
            #expect(lessons.count == 1)
            #expect(only.kind == .notSent)
            #expect(only.before == Lesson.Item(task: "Book the venue", owner: "Stephen"))
            #expect(only.after == nil)
            #expect(only.style == .salesCall && only.meetingTitle == "Acme" && only.date == at1530)
        }

        @Test func aNonDefaultItemTickedIsSentAnyway() throws {
            let lessons = diff(baseline: [0], final: [(0, shown[0]), (2, shown[2])])
            let only = try #require(lessons.first)
            #expect(lessons.count == 1)
            #expect(only.kind == .sentAnyway)
            #expect(only.after == Lesson.Item(task: "Call Dana", owner: "Stephen"))
        }

        @Test func anEditKeepsBeforeAndAfter() throws {
            let edited = ai("Draft the scope email to Dana", owner: "Ashley", due: "Friday")
            let lessons = diff(baseline: [0], final: [(0, edited)])
            let only = try #require(lessons.first)
            #expect(lessons.count == 1)
            #expect(only.kind == .edited)
            #expect(only.before == Lesson.Item(task: "Draft the scope email", owner: "Stephen"))
            #expect(only.after == Lesson.Item(task: "Draft the scope email to Dana", owner: "Ashley", due: "Friday"))
        }

        @Test func eachEditedFieldCounts() {
            #expect(diff(baseline: [0], final: [(0, ai("Draft the scope email", owner: "Dana"))]).map(\.kind) == [.edited])
            #expect(diff(baseline: [0], final: [(0, ai("Draft the scope email", due: "Monday"))]).map(\.kind) == [.edited])
        }

        @Test func whitespaceAndAnEmptyDueAreNotEdits() {
            let same = ActionItem(task: "  Draft the scope email ", owner: "Stephen\n", due: "", doer: .ai,
                                  context: "changed context", source: "n1")
            #expect(diff(baseline: [0], final: [(0, same)]).isEmpty)
        }

        @Test func aNonDefaultItemTickedAndEditedGivesBoth() {
            let lessons = diff(baseline: [], final: [(3, ai("Order lunch for six"))])
            #expect(lessons.map(\.kind) == [.sentAnyway, .edited])
            #expect(lessons.allSatisfy { $0.after?.task == "Order lunch for six" })
            #expect(lessons[1].before?.task == "Order lunch")
        }

        @Test func severalChangesComeInTheWindowsOrder() {
            let lessons = diff(baseline: [0, 1], final: [(2, shown[2]), (1, ai("Book the bigger venue"))])
            #expect(lessons.map(\.kind) == [.notSent, .edited, .sentAnyway])
            #expect(Set(lessons.map(\.id)).count == 3)
        }

        @Test func indicesOutsideTheWindowAreIgnored() {
            #expect(diff(baseline: [9], final: [(7, ai("Ghost"))]).isEmpty)
            #expect(diff(baseline: [0], final: [(0, shown[0]), (0, ai("Duplicate"))]).isEmpty)
        }

        @Test func anInstructionKeepsTheText() {
            let lesson = LessonDiff.instruction("  Never assign tasks to Dana.\n", style: .general, title: "Acme",
                                                date: at1530)
            #expect(lesson.kind == .instruction)
            #expect(lesson.instruction == "Never assign tasks to Dana.")
            #expect(lesson.before == nil && lesson.after == nil)
            #expect(lesson.style == .general && lesson.meetingTitle == "Acme" && lesson.date == at1530)
        }
    }
}

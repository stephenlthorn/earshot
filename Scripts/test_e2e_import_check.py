#!/usr/bin/env python3
# Scripts/test_e2e_import_check.py: unit tests for e2e_import_check.py, on made-up run folders.
# Run: python3 -m unittest discover -s Scripts -p 'test_*.py'
import contextlib
import io
import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import e2e_import_check as check  # noqa: E402

MEETING_ID = "2026-10-15-1000-ab12"
TITLE = "Acme pilot planning"


def write_json(path, value):
    path.write_text(json.dumps(value))


class Run:
    """A passing run: the meetings folder, one meeting in it and the index folder, each part changeable."""

    def __init__(self, base):
        self.root = base / "meetings"
        self.index = base / "Index"
        self.meeting = self.root / f"2026-10-15 1000 {TITLE}"
        self.meeting.mkdir(parents=True)
        self.index.mkdir()
        (self.root / "e2e-done").write_text("ok")
        (self.root / "e2e-session").write_text(MEETING_ID)
        self.session = {
            "id": MEETING_ID, "title": TITLE, "mode": "notes_and_do", "recording": False, "startedBy": "import",
            "stages": {name: {"status": "done", "failures": 0}
                       for name in ("transcribe", "notes", "dispatch", "compress")},
        }
        self.save_session()
        (self.meeting / "transcript.md").write_text("**Speaker** Let's plan the Acme Pilot.\n")
        write_json(self.meeting / "notes.json", {"title": TITLE, "action_items": [{"task": "Email the scope"}]})
        (self.meeting / "notes.html").write_text(f"<html><h1>{TITLE}</h1></html>")
        write_json(self.meeting / "payload.json", {"version": 1, "items": [{"task": "Research tools"}]})
        write_json(self.index / f"{MEETING_ID}.json", {"version": 1, "id": MEETING_ID, "title": TITLE})

    def save_session(self):
        write_json(self.meeting / "session.json", self.session)

    def problems(self):
        return check.check(self.root, self.index)[0]


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.run_ = Run(pathlib.Path(self.temp.name))

    def tearDown(self):
        self.temp.cleanup()

    def assertProblem(self, words):
        problems = self.run_.problems()
        self.assertTrue(any(words in p for p in problems), f"no problem with {words!r} in {problems}")

    def test_good_run_passes_with_a_summary(self):
        problems, summary = check.check(self.run_.root, self.run_.index)
        self.assertEqual(problems, [])
        self.assertIn(MEETING_ID, summary)
        self.assertIn("1 action item", summary)

    def test_app_error_is_reported_as_is(self):
        (self.run_.root / "e2e-done").write_text("Notes failed: claude not found")
        self.assertEqual(self.run_.problems(), ["Earshot reported: Notes failed: claude not found"])

    def test_missing_done_marker_fails(self):
        (self.run_.root / "e2e-done").unlink()
        self.assertProblem("no e2e-done")

    def test_two_meeting_folders_fail(self):
        (self.run_.root / "another").mkdir()
        self.assertProblem("expected one meeting folder, found 2")

    def test_unfinished_stage_fails(self):
        self.run_.session["stages"]["dispatch"] = {"status": "failed", "error": "boom", "failures": 1}
        self.run_.save_session()
        self.assertProblem("not finished: dispatch")

    def test_missing_stage_fails(self):
        del self.run_.session["stages"]["compress"]
        self.run_.save_session()
        self.assertProblem("not finished: compress")

    def test_still_recording_fails(self):
        self.run_.session["recording"] = True
        self.run_.save_session()
        self.assertProblem("still marked as recording")

    def test_not_an_import_fails(self):
        self.run_.session["startedBy"] = "manual"
        self.run_.save_session()
        self.assertProblem("startedBy is manual")

    def test_wrong_mode_fails(self):
        self.run_.session["mode"] = "notes"
        self.run_.save_session()
        self.assertProblem("mode is notes")

    def test_transcript_without_key_word_fails(self):
        (self.run_.meeting / "transcript.md").write_text("**Speaker** Hello.\n")
        self.assertProblem("transcript doesn't mention")

    def test_no_action_items_fails(self):
        write_json(self.run_.meeting / "notes.json", {"title": TITLE, "action_items": []})
        self.assertProblem("no action items")

    def test_missing_notes_page_fails(self):
        (self.run_.meeting / "notes.html").unlink()
        self.assertProblem("notes.html is missing")

    def test_notes_page_without_title_fails(self):
        (self.run_.meeting / "notes.html").write_text("<html><h1>Something else</h1></html>")
        self.assertProblem("notes.html doesn't show the title")

    def test_title_is_matched_as_the_page_escapes_it(self):
        self.run_.session["title"] = "Dana's \"pilot\" & venue"
        self.run_.save_session()
        page = "<h1>Dana&#39;s &quot;pilot&quot; &amp; venue</h1>"
        (self.run_.meeting / "notes.html").write_text(page)
        self.assertEqual(self.run_.problems(), [])

    def test_payload_with_wrong_version_fails(self):
        write_json(self.run_.meeting / "payload.json", {"version": 2, "items": [{"task": "x"}]})
        self.assertProblem("payload.json isn't version 1")

    def test_payload_without_items_fails(self):
        write_json(self.run_.meeting / "payload.json", {"version": 1, "items": []})
        self.assertProblem("payload.json has no items")

    def test_missing_payload_fails(self):
        (self.run_.meeting / "payload.json").unlink()
        self.assertProblem("payload.json is missing")

    def test_missing_index_entry_fails(self):
        (self.run_.index / f"{MEETING_ID}.json").unlink()
        self.assertProblem("no index entry")

    def test_index_entry_for_another_meeting_fails(self):
        write_json(self.run_.index / f"{MEETING_ID}.json", {"version": 1, "id": "other"})
        self.assertProblem("index entry has id other")

    def test_session_marker_must_match_the_meeting(self):
        (self.run_.root / "e2e-session").write_text("2026-10-15-1000-zz99")
        self.assertProblem("e2e-session says 2026-10-15-1000-zz99")

    def test_missing_session_marker_fails(self):
        (self.run_.root / "e2e-session").unlink()
        self.assertProblem("no e2e-session marker")

    def test_missing_session_file_fails(self):
        (self.run_.meeting / "session.json").unlink()
        self.assertProblem("session.json is missing")

    def test_corrupt_session_file_fails(self):
        (self.run_.meeting / "session.json").write_text('{"id": "2026-')
        self.assertProblem("session.json isn't valid JSON")

    def test_truncated_payload_fails(self):
        (self.run_.meeting / "payload.json").write_text('{"version": 1, "items": [')
        self.assertProblem("payload.json isn't valid JSON")

    def test_corrupt_notes_file_fails(self):
        (self.run_.meeting / "notes.json").write_text("not json")
        self.assertProblem("notes.json isn't valid JSON")

    def test_corrupt_index_entry_fails(self):
        (self.run_.index / f"{MEETING_ID}.json").write_text("{")
        self.assertProblem(f"{MEETING_ID}.json isn't valid JSON")

    def test_json_that_is_not_an_object_fails(self):
        write_json(self.run_.meeting / "payload.json", [1, 2])
        self.assertProblem("payload.json isn't a JSON object")

    def test_main_prints_one_fail_line_for_a_corrupt_session(self):
        (self.run_.meeting / "session.json").write_text("{")
        code, out = self.main()
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("FAIL: session.json isn't valid JSON"), out)
        self.assertEqual(out.count("\n"), 1, out)

    def main(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = check.main([str(self.run_.root), str(self.run_.index)])
        return code, out.getvalue()

    def test_main_exits_zero_and_prints_pass(self):
        code, out = self.main()
        self.assertEqual(code, 0)
        self.assertTrue(out.startswith("PASS: "), out)

    def test_main_exits_one_and_prints_fail_on_a_problem(self):
        (self.run_.meeting / "notes.html").unlink()
        code, out = self.main()
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("FAIL: notes.html is missing"), out)


if __name__ == "__main__":
    unittest.main()

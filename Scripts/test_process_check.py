#!/usr/bin/env python3
# Scripts/test_process_check.py: unit tests for process_check.py, the (k) checker claude-test.sh and local-test.sh
# share, on run folders shaped like real ones.
# Run: python3 -m unittest discover -s Scripts -p 'test_*.py'
import json
import os
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import process_check as check  # noqa: E402

NOTES_MD = "# Proposal review\n\n- [ ] Send Ashley the revised proposal (Stephen, due Friday)\n"
ITEMS = [{"task": "Send Ashley the revised proposal", "owner": "Stephen", "due": "Friday"}]


class ProcessCheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.k = self.temp.name
        os.makedirs(os.path.join(self.k, "index"))
        self.folder = os.path.join(self.k, "meetings", "2026-10-15 Proposal review")
        os.makedirs(self.folder)
        self.write("stderr.txt", "earshot: Transcribing...\nearshot: Writing notes...\n")

    def tearDown(self):
        self.temp.cleanup()

    def write(self, name, text):
        with open(os.path.join(self.k, name), "w") as out:
            out.write(text)

    def finished_run(self, notes=NOTES_MD, indexed=True):
        notes_path = os.path.join(self.folder, "notes.md")
        with open(notes_path, "w") as out:
            out.write(notes)
        with open(os.path.join(self.folder, "notes.json"), "w") as out:
            json.dump({"action_items": ITEMS}, out)
        if indexed:
            open(os.path.join(self.k, "index", "abc.json"), "w").close()
        self.write("report.json", json.dumps({"id": "abc", "folder": self.folder, "notes": notes_path, "finished": True}))

    def test_passes_with_notes_naming_the_proposal_and_friday_in_the_temp_index(self):
        self.finished_run()
        self.assertEqual(check.verdict(self.k, 0),
                         'PASS (k) earshot process writes notes: exit 0; finished=True; items=[["Send Ashley the revised '
                         'proposal", "Stephen", "Friday"]]; temp index=["abc.json"]')

    def test_fails_with_the_end_of_stderr_when_the_run_failed(self):
        self.write("stderr.txt", "earshot: Writing notes failed: " + "x" * 300)
        line = check.verdict(self.k, 1)
        self.assertTrue(line.startswith("FAIL (k) earshot process writes notes: exit 1; finished=None; items=[]; temp index=[]"))
        self.assertTrue(line.endswith("; stderr=" + ("earshot: Writing notes failed: " + "x" * 300)[-200:]))

    def test_fails_when_the_notes_miss_friday_or_the_index_misses_the_meeting(self):
        self.finished_run(notes="# Proposal review\n")
        self.assertTrue(check.verdict(self.k, 0).startswith("FAIL (k)"))
        os.remove(os.path.join(self.k, "index", "abc.json"))
        self.finished_run(indexed=False)
        self.assertTrue(check.verdict(self.k, 0).startswith("FAIL (k)"))

    def test_fails_when_the_meeting_is_outside_this_runs_folder(self):
        self.finished_run()
        report = json.load(open(os.path.join(self.k, "report.json")))
        report["folder"] = "/Users/someone/Documents/Earshot/2026-10-15 Proposal review"
        self.write("report.json", json.dumps(report))
        self.assertTrue(check.verdict(self.k, 0).startswith("FAIL (k)"))


if __name__ == "__main__":
    unittest.main()

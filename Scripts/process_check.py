#!/usr/bin/env python3
# Scripts/process_check.py: reads one `earshot process --json` run from Scripts/claude-test.sh or Scripts/local-test.sh
# and prints one PASS or FAIL line for check (k).
# Usage: python3 process_check.py <run folder> <exit status>
# The run folder holds report.json and stderr.txt from the run, the meetings/ folder it wrote to and its own index/.
import json
import os
import sys


def verdict(k, status):
    """The (k) line: the run finished in this run's meetings folder, its notes name the proposal and Friday, and the
    meeting is in this run's own index."""
    try:
        report = json.load(open(os.path.join(k, "report.json")))
    except Exception:
        report = {}
    notes_md = report.get("notes") or ""
    folder = report.get("folder") or ""
    text = open(notes_md).read() if notes_md and os.path.exists(notes_md) else ""
    try:
        items = json.load(open(os.path.join(folder, "notes.json"))).get("action_items", [])
    except Exception:
        items = []
    index = sorted(os.listdir(os.path.join(k, "index")))
    low = text.lower()
    good = (status == 0 and report.get("finished") and folder.startswith(os.path.join(k, "meetings"))
            and "proposal" in low and "friday" in low and f"{report.get('id')}.json" in index)
    err = " ".join(open(os.path.join(k, "stderr.txt")).read().split())[-200:]
    return (("PASS" if good else "FAIL") + " (k) earshot process writes notes: exit " + str(status)
            + "; finished=" + str(report.get("finished")) + "; items=" + json.dumps([[i.get("task"), i.get("owner"), i.get("due")] for i in items])
            + "; temp index=" + json.dumps(index) + ("" if good else "; stderr=" + err))


if __name__ == "__main__":
    print(verdict(sys.argv[1], int(sys.argv[2])))

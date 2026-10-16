#!/usr/bin/env python3
# Scripts/e2e_check.py: checks one e2e run's output folder. Exit 0 and PASS, or exit 1 with the reason.
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
done = (root / "e2e-done").read_text().strip()
if done != "ok":
    sys.exit(f"FAIL: Earshot reported: {done}")
folders = [p for p in root.iterdir() if p.is_dir()]
if len(folders) != 1:
    sys.exit(f"FAIL: expected one meeting folder, found {len(folders)}")
meeting = folders[0]
transcript = (meeting / "transcript.md").read_text()
notes = json.loads((meeting / "notes.json").read_text())
payload = json.loads((meeting / "payload.json").read_text())
tasks = " | ".join(item["task"].lower() for item in notes["action_items"])
problems = []
if "Them:" not in transcript or "pilot" not in transcript.lower():
    problems.append("the call audio wasn't transcribed")
if "scope" not in tasks:
    problems.append(f"no scope-email action item in: {tasks}")
if "venue" not in tasks:
    problems.append(f"no venue action item in: {tasks}")
if payload.get("version") != 1 or not payload.get("items"):
    problems.append("the command target got no payload items")
if any(item["doer"] != "ai" for item in payload.get("items", [])):
    problems.append("send-without-asking sent a non-AI item")
if not list(meeting.glob("*.m4a")) or list(meeting.glob("*.caf")):
    problems.append("audio wasn't compressed")
if problems:
    sys.exit("FAIL: " + "; ".join(problems))
print(f"PASS: {meeting.name}: {len(notes['action_items'])} action items, {len(payload['items'])} sent")

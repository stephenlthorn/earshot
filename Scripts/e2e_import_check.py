#!/usr/bin/env python3
# Scripts/e2e_import_check.py: checks one `--e2e-import` run. Exit 0 and PASS, or exit 1 with every problem found.
# Usage: e2e_import_check.py <meetings folder> [<index folder>]
# The index folder defaults to ~/Library/Application Support/Earshot/Index.
import html
import json
import pathlib
import sys

DEFAULT_INDEX = pathlib.Path.home() / "Library/Application Support/Earshot/Index"
KEY_WORD = "pilot"  # said in Scripts/meeting-script.txt
STAGES = ("transcribe", "notes", "dispatch", "compress")  # notes_and_do


def load_json(path):
    """(object, None), or (None, the problem) when the file is missing, unreadable or not a JSON object."""
    try:
        value = json.loads(path.read_text())
    except FileNotFoundError:
        return None, f"{path.name} is missing"
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None, f"{path.name} isn't valid JSON"
    except OSError as error:
        return None, f"{path.name} can't be read ({error.strerror or error})"
    if not isinstance(value, dict):
        return None, f"{path.name} isn't a JSON object"
    return value, None


def page_escape(text):
    """The way NotesPageRenderer.escape writes text into notes.html."""
    return html.escape(text, quote=True).replace("&#x27;", "&#39;")


def check_session(session, marker):
    problems = []
    if marker and marker != session.get("id"):
        problems.append(f"e2e-session says {marker} but the meeting is {session.get('id')}")
    if session.get("recording"):
        problems.append("session.json is still marked as recording")
    if session.get("mode") != "notes_and_do":
        problems.append(f"mode is {session.get('mode')}, not notes_and_do")
    if session.get("startedBy") != "import":
        problems.append(f"startedBy is {session.get('startedBy')}, not import")
    stages = session.get("stages") or {}
    unfinished = [name for name in STAGES if (stages.get(name) or {}).get("status") != "done"]
    if unfinished:
        errors = [f"{name}: {stages[name]['error']}" for name in unfinished if (stages.get(name) or {}).get("error")]
        problems.append("not finished: " + ", ".join(unfinished) + (f" ({'; '.join(errors)})" if errors else ""))
    return problems


def check_files(meeting, title):
    problems = []
    transcript = meeting / "transcript.md"
    if not transcript.exists() or KEY_WORD not in transcript.read_text(errors="replace").lower():
        problems.append(f"the transcript doesn't mention \"{KEY_WORD}\"")
    notes, problem = load_json(meeting / "notes.json")
    if problem:
        problems.append(problem)
    elif not notes.get("action_items"):
        problems.append("notes.json has no action items")
    page = meeting / "notes.html"
    if not page.exists():
        problems.append("notes.html is missing")
    elif not title or page_escape(title) not in page.read_text(errors="replace"):
        problems.append(f"notes.html doesn't show the title {title!r}")
    payload, problem = load_json(meeting / "payload.json")
    if problem:
        problems.append(problem + (": the command target didn't run" if problem.endswith("missing") else ""))
    else:
        if payload.get("version") != 1:
            problems.append(f"payload.json isn't version 1 (it says {payload.get('version')})")
        if not payload.get("items"):
            problems.append("payload.json has no items")
    counts = (len((notes or {}).get("action_items") or []), len((payload or {}).get("items") or []))
    return problems, counts


def check_index(index, meeting_id):
    entry_file = index / f"{meeting_id}.json"
    if not entry_file.exists():
        return [f"no index entry at {entry_file}"]
    entry, problem = load_json(entry_file)
    if problem:
        return [problem]
    if entry.get("id") != meeting_id:
        return [f"the index entry has id {entry.get('id')}, not {meeting_id}"]
    return []


def check(root, index=DEFAULT_INDEX):
    """(problems, summary) for the run in `root`. No problems means it passed."""
    root, index = pathlib.Path(root), pathlib.Path(index)
    done_file = root / "e2e-done"
    if not done_file.exists():
        return ["no e2e-done marker: Earshot didn't finish"], ""
    done = done_file.read_text(errors="replace").strip()
    if done != "ok":
        return [f"Earshot reported: {done}"], ""
    folders = [p for p in root.iterdir() if p.is_dir()]
    if len(folders) != 1:
        return [f"expected one meeting folder, found {len(folders)}"], ""
    meeting = folders[0]
    session, problem = load_json(meeting / "session.json")
    if problem:
        return [problem], ""
    marker_file = root / "e2e-session"
    marker = marker_file.read_text(errors="replace").strip() if marker_file.exists() else None
    # The app writes the meeting id here once the import is saved, so the run can be matched to its meeting.
    problems = [] if marker else ["no e2e-session marker: the run can't be matched to its meeting"]
    problems += check_session(session, marker)
    file_problems, (count, payload_items) = check_files(meeting, session.get("title"))
    problems += file_problems
    problems += check_index(index, session.get("id"))
    if problems:
        return problems, ""
    plural = "" if count == 1 else "s"
    summary = (f"{session.get('id')} \"{session.get('title')}\": {count} action item{plural}, "
               f"{payload_items} sent, index entry found")
    return problems, summary


def main(argv):
    if not argv:
        print("usage: e2e_import_check.py <meetings folder> [<index folder>]", file=sys.stderr)
        return 2
    problems, summary = check(argv[0], argv[1] if len(argv) > 1 else DEFAULT_INDEX)
    if problems:
        print("FAIL: " + "; ".join(problems))
        return 1
    print(f"PASS: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

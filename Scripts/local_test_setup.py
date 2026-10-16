#!/usr/bin/env python3
# Scripts/local_test_setup.py: the two setup steps of Scripts/local-test.sh.
#   python3 local_test_setup.py models <base url> <model>
#       The preflight: GET <base url>/models must list <model>. Prints one line; exit 1 with a FAIL line when it doesn't.
#   python3 local_test_setup.py settings <plist> <base url> <model>
#       Writes a settings domain that sets Earshot to the local model, for `earshot process` (EARSHOT_SETTINGS_DOMAIN is
#       the plist's path without .plist). The key "settings" holds the settings JSON as data, as EarshotSettings.save
#       writes it; every setting it leaves out keeps Earshot's default.
import json
import plistlib
import sys
import urllib.request


def model_ids(listing):
    """The ids in an OpenAI list (data[].id) and in Ollama's and llama.cpp's (models[].name, models[].model), sorted
    and deduplicated, or None when the reply is neither shape (the same rules as LocalModelStatus)."""
    if not isinstance(listing, dict):
        return None
    openai, ollama = listing.get("data"), listing.get("models")
    if not isinstance(openai, list) and not isinstance(ollama, list):
        return None
    ids = [m.get("id") for m in openai or [] if isinstance(m, dict)]
    ids += [m.get(key) for m in ollama or [] if isinstance(m, dict) for key in ("name", "model")]
    return sorted({i for i in ids if isinstance(i, str) and i})


def matches(chosen, listed):
    """The same model, allowing for Ollama's :latest tag on either side."""
    bare = lambda name: name[: -len(":latest")] if name.endswith(":latest") else name
    return chosen == listed or bare(chosen) == bare(listed)


def fetch_json(url, timeout=10):
    with urllib.request.urlopen(urllib.request.Request(url, method="GET"), timeout=timeout) as reply:
        return json.load(reply)


def preflight(base, model, fetch=fetch_json):
    """(ok, line): whether <base>/models lists <model>, and the line to print."""
    url = base.rstrip("/") + "/models"
    try:
        ids = model_ids(fetch(url))
    except Exception as error:
        return False, f"FAIL (preflight) can't read {url}: {error}"
    if ids is None:
        return False, f"FAIL (preflight) {url} didn't answer with a model list"
    if any(matches(model, listed) for listed in ids):
        return True, f"== Local model server: {url} lists {model}"
    has = ", ".join(ids) if ids else "no models"
    return False, f"FAIL (preflight) {url} doesn't list {model}. It lists: {has}"


def write_settings(path, base, model):
    settings = {"provider": "local", "localURL": base, "localModel": model}
    with open(path, "wb") as out:
        plistlib.dump({"settings": json.dumps(settings).encode()}, out, fmt=plistlib.FMT_BINARY)


def main(argv):
    if len(argv) == 4 and argv[1] == "models":
        ok, line = preflight(argv[2], argv[3], fetch_json)
        print(line)
        return 0 if ok else 1
    if len(argv) == 5 and argv[1] == "settings":
        write_settings(argv[2], argv[3], argv[4])
        return 0
    print("usage: local_test_setup.py models <base url> <model> | settings <plist> <base url> <model>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

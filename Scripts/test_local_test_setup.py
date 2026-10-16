#!/usr/bin/env python3
# Scripts/test_local_test_setup.py: unit tests for local_test_setup.py, on model lists shaped like real servers' ones.
# Run: python3 -m unittest discover -s Scripts -p 'test_*.py'
import json
import pathlib
import plistlib
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import local_test_setup as setup  # noqa: E402

# llama.cpp lists one model in both shapes.
LLAMA = {"object": "list", "data": [{"id": "qwen3-8b"}], "models": [{"name": "qwen3-8b", "model": "qwen3-8b"}]}
OLLAMA = {"models": [{"name": "llama3.1:latest", "model": "llama3.1:latest"}, {"name": "qwen3:8b", "model": "qwen3:8b"}]}
LM_STUDIO = {"object": "list", "data": [{"id": "qwen/qwen3-8b"}, {"id": "text-embedding-nomic"}]}


def fetching(reply):
    seen = []

    def fetch(url):
        seen.append(url)
        if isinstance(reply, Exception):
            raise reply
        return reply

    return fetch, seen


class ModelIdsTests(unittest.TestCase):
    def test_reads_both_shapes_sorted_and_deduplicated(self):
        self.assertEqual(setup.model_ids(LLAMA), ["qwen3-8b"])
        self.assertEqual(setup.model_ids(OLLAMA), ["llama3.1:latest", "qwen3:8b"])
        self.assertEqual(setup.model_ids(LM_STUDIO), ["qwen/qwen3-8b", "text-embedding-nomic"])

    def test_anything_else_is_not_a_list(self):
        self.assertIsNone(setup.model_ids({"error": "nope"}))
        self.assertIsNone(setup.model_ids([1, 2]))
        self.assertEqual(setup.model_ids({"data": []}), [])

    def test_latest_matches_either_way(self):
        self.assertTrue(setup.matches("llama3.1", "llama3.1:latest"))
        self.assertTrue(setup.matches("mistral:latest", "mistral"))
        self.assertFalse(setup.matches("qwen3", "qwen3:8b"))


class PreflightTests(unittest.TestCase):
    def test_passes_when_the_model_is_listed(self):
        fetch, seen = fetching(LLAMA)
        ok, line = setup.preflight("http://127.0.0.1:18300/v1/", "qwen3-8b", fetch)
        self.assertTrue(ok)
        self.assertEqual(seen, ["http://127.0.0.1:18300/v1/models"])
        self.assertEqual(line, "== Local model server: http://127.0.0.1:18300/v1/models lists qwen3-8b")
        self.assertFalse(line.startswith(("PASS", "FAIL")), "the preflight never counts as a check")

    def test_one_fail_line_names_what_the_server_lists(self):
        fetch, _ = fetching(OLLAMA)
        ok, line = setup.preflight("http://localhost:11434/v1", "qwen3:14b", fetch)
        self.assertFalse(ok)
        self.assertEqual(line, "FAIL (preflight) http://localhost:11434/v1/models doesn't list qwen3:14b. It lists: llama3.1:latest, qwen3:8b")
        fetch, _ = fetching({"data": []})
        self.assertTrue(setup.preflight("http://localhost:1234/v1", "m", fetch)[1].endswith("It lists: no models"))

    def test_a_server_that_isnt_there_fails(self):
        fetch, _ = fetching(OSError("Connection refused"))
        ok, line = setup.preflight("http://localhost:8080/v1", "m", fetch)
        self.assertFalse(ok)
        self.assertEqual(line, "FAIL (preflight) can't read http://localhost:8080/v1/models: Connection refused")
        fetch, _ = fetching({"error": "no"})
        self.assertIn("didn't answer with a model list", setup.preflight("http://localhost:8080/v1", "m", fetch)[1])

    def test_main_without_its_arguments_is_a_usage_error(self):
        self.assertEqual(setup.main(["x", "models"]), 2)

    def run_main(self, reply):
        fetch, seen = fetching(reply)
        out = StringIO()
        with mock.patch.object(setup, "fetch_json", fetch), redirect_stdout(out):
            status = setup.main(["x", "models", "http://127.0.0.1:18300/v1", "qwen3-8b"])
        return status, out.getvalue(), seen

    def test_main_exits_0_when_the_model_is_listed(self):
        status, out, seen = self.run_main(LLAMA)
        self.assertEqual((status, seen), (0, ["http://127.0.0.1:18300/v1/models"]))
        self.assertEqual(out, "== Local model server: http://127.0.0.1:18300/v1/models lists qwen3-8b\n")

    def test_main_exits_1_with_one_fail_line_otherwise(self):
        for reply in (OLLAMA, OSError("Connection refused"), {"error": "no"}):
            status, out, _ = self.run_main(reply)
            self.assertEqual(status, 1, reply)
            self.assertEqual(len(out.splitlines()), 1, reply)
            self.assertTrue(out.startswith("FAIL (preflight) "), reply)


class SettingsTests(unittest.TestCase):
    def test_writes_the_settings_json_as_data_under_settings(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "defaults.plist"
            self.assertEqual(setup.main(["x", "settings", str(path), "http://127.0.0.1:18300/v1", "qwen3-8b"]), 0)
            with open(path, "rb") as stream:
                domain = plistlib.load(stream)
            self.assertEqual(list(domain), ["settings"])
            self.assertIsInstance(domain["settings"], bytes)
            self.assertEqual(json.loads(domain["settings"]),
                             {"provider": "local", "localURL": "http://127.0.0.1:18300/v1", "localModel": "qwen3-8b"})


if __name__ == "__main__":
    unittest.main()

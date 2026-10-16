#!/usr/bin/env python3
# Scripts/test_group_timeout.py: tests for group-timeout.pl, the guard claude-test.sh runs `swift test` under.
# Run: python3 -m unittest discover -s Scripts -p 'test_*.py'
import os
import pathlib
import signal
import subprocess
import tempfile
import time
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent / "group-timeout.pl"


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # A zombie still answers kill 0; ps shows it as Z.
    state = subprocess.run(["ps", "-o", "state=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(state) and not state.startswith("Z")


class GroupTimeoutTests(unittest.TestCase):
    def run_guard(self, seconds, command, grace="1"):
        env = dict(os.environ, GROUP_TIMEOUT_GRACE=grace)
        return subprocess.run(["perl", str(SCRIPT), str(seconds), *command], capture_output=True, text=True,
                              env=env, timeout=60)

    def test_a_command_that_finishes_keeps_its_status(self):
        self.assertEqual(self.run_guard(10, ["sh", "-c", "exit 0"]).returncode, 0)
        self.assertEqual(self.run_guard(10, ["sh", "-c", "exit 3"]).returncode, 3)

    def test_a_timeout_stops_the_children_the_command_started(self):
        with tempfile.TemporaryDirectory() as folder:
            pids = pathlib.Path(folder) / "pids"
            # The command starts two sleepers (as swift test starts runners, and they start claude -p) and waits.
            script = f"sleep 300 & echo $! >> {pids}; sh -c 'sleep 300 & echo $! >> {pids}; wait' & wait"
            started = time.monotonic()
            out = self.run_guard(1, ["sh", "-c", script])
            self.assertEqual(out.returncode, 124)
            self.assertIn("Stopped after 1 seconds", out.stderr)
            self.assertLess(time.monotonic() - started, 20)
            children = [int(line) for line in pids.read_text().split()]
            self.assertEqual(len(children), 2)
            time.sleep(0.2)
            self.assertFalse([pid for pid in children if alive(pid)], "every child stopped with the command")

    def test_a_child_that_ignores_sigterm_is_killed(self):
        out = self.run_guard(1, ["sh", "-c", "trap '' TERM; sleep 300 & wait"])
        self.assertEqual(out.returncode, 124)

    def stop_by_signal(self, signum):
        """Starts the guard on two sleepers, sends it `signum` once both are running, and returns (status, sleepers)."""
        children = []
        with tempfile.TemporaryDirectory() as folder:
            pids = pathlib.Path(folder) / "pids"
            script = f"sleep 300 & echo $! >> {pids}; sh -c 'sleep 300 & echo $! >> {pids}; wait' & wait"
            env = dict(os.environ, GROUP_TIMEOUT_GRACE="1")
            guard = subprocess.Popen(["perl", str(SCRIPT), "120", "sh", "-c", script], env=env,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline and (not pids.exists() or len(pids.read_text().split()) < 2):
                    time.sleep(0.05)
                children = [int(line) for line in pids.read_text().split()]
                self.assertEqual(len(children), 2)
                guard.send_signal(signum)
                guard.wait(timeout=20)
                time.sleep(0.2)
                return guard.returncode, [pid for pid in children if alive(pid)]
            finally:
                # Never leave a sleeper behind, even when the guard failed.
                if guard.poll() is None:
                    guard.kill()
                    guard.wait()
                for pid in children:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_ctrl_c_on_the_guard_stops_the_children_the_command_started(self):
        status, running = self.stop_by_signal(signal.SIGINT)
        self.assertEqual(status, 128 + signal.SIGINT)
        self.assertFalse(running, "every child stopped with the guard")

    def test_sigterm_on_the_guard_stops_the_children_the_command_started(self):
        status, running = self.stop_by_signal(signal.SIGTERM)
        self.assertEqual(status, 128 + signal.SIGTERM)
        self.assertFalse(running, "every child stopped with the guard")

    def test_a_closed_terminal_stops_the_children_the_command_started(self):
        status, running = self.stop_by_signal(signal.SIGHUP)
        self.assertEqual(status, 128 + signal.SIGHUP)
        self.assertFalse(running, "every child stopped with the guard")

    def test_a_bad_call_is_refused(self):
        self.assertNotEqual(self.run_guard("soon", ["true"]).returncode, 0)


if __name__ == "__main__":
    unittest.main()

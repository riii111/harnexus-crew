"""The acceptance harness itself: a difference it is meant to find must show, and a repeated request or a lost result must not be hidden."""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from harness import expected
from harness.bridge import Bridge
from harness.cases import load_cases, make_case, parse_case, InvalidCase
from harness.compare import compare
from harness.execute import observe
from harness.normalize import normalize


class Harness(unittest.TestCase):
    def setUp(self):
        directory = tempfile.mkdtemp(prefix="hxc-stub-")
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        self.stub_path = Path(directory) / "stub.py"
        self.stub_path.write_text(STUB, encoding="utf-8")

    def test_json_compares_by_meaning_not_by_member_order(self):
        reordered = {**BASE, "stdout": '{"b":[1,2],"a":1}\n'}
        self.assertEqual([], self.observe_differences(stub_case(), BASE, BASE))
        self.assertEqual([], self.observe_differences(stub_case(), BASE, reordered))

    def test_a_boolean_is_not_a_number(self):
        found = self.observe_differences(stub_case(), {**BASE, "stdout": '{"a":1}\n'}, {**BASE, "stdout": '{"a":true}\n'})
        self.assertEqual(["stdout"], self.fields(found))

    def test_detects_a_different_result(self):
        for name, change, field in (
            ("stdout meaning", {"stdout": '{"a":2,"b":[1,2]}\n'}, "stdout"),
            ("stderr text", {"stderr": "other\n"}, "stderr"),
            ("exit code", {"exit": 3}, "exitCode"),
            ("state content", {"state": {"taskctl/k1/state.json": '{"x":2}'}}, "files.state/taskctl/k1/state.json"),
            ("state key", {"state": {"taskctl/k2/state.json": '{"x":1}'}}, "files.state/taskctl/k1/state.json"),
            ("request body", {"requests": ['{"tool":"send_message_to_thread"}']}, "requests[0]"),
            ("command arguments", {"command": ["codex", "resume"]}, "commands[0]"),
        ):
            with self.subTest(name):
                found = self.observe_differences(stub_case(), BASE, {**BASE, **change})
                self.assertIn(field, self.fields(found))

    def test_detects_a_request_sent_twice(self):
        twice = {**BASE, "requests": [*BASE["requests"], *BASE["requests"]]}
        found = self.observe_differences(stub_case(), BASE, twice)
        self.assertIn({"field": "requests.count", "expected": 1, "actual": 2}, found)

    def test_lines_keep_their_boundaries_in_a_session(self):
        session = stub_case(kind="session", bridge=None, commands={}, env={})
        found = self.observe_differences(session, {"stdout": '{"id":1}\n{"id":2}\n'}, {"stdout": '{"id":1}{"id":2}\n'})
        self.assertIn("stdout.lines", self.fields(found))

    def test_a_session_passes_each_stdin_line_to_stdout_in_order(self):
        session = stub_case(
            kind="session",
            bridge=None,
            commands={},
            env={},
            steps=[{"send": '{"id":1}'}, {"wait": 1}, {"send": '{"id":2}'}],
        )
        observation, _ = observe(["/bin/cat"], session)
        self.assertEqual('{"id":1}\n{"id":2}\n', observation["stdout"])
        self.assertEqual(0, observation["exitCode"])

    def test_a_case_with_an_unknown_member_is_refused(self):
        with self.assertRaises(InvalidCase):
            parse_case({"name": "x", "kind": "command", "argv": [], "extra": 1})

    def observe_differences(self, case, expected_options, actual_options):
        first, first_root = observe(self.stub(expected_options), case)
        second, second_root = observe(self.stub(actual_options), case)
        return compare(case, normalize(first, first_root), normalize(second, second_root))

    def stub(self, options):
        return [sys.executable, "-I", str(self.stub_path), json.dumps(options)]

    def fields(self, found):
        return [difference["field"] for difference in found]


class BridgeSynchronization(unittest.TestCase):
    def test_finished_requests_waits_for_queued_and_unread_connections(self):
        accept_gate = threading.Event()
        serve_gate = threading.Event()
        serve_started = threading.Event()
        snapshot_done = threading.Event()
        original_accept = Bridge._accept_loop
        original_serve = Bridge._serve

        def delayed_accept(bridge):
            accept_gate.wait()
            original_accept(bridge)

        def delayed_serve(bridge, connection, recorded):
            serve_started.set()
            serve_gate.wait()
            original_serve(bridge, connection, recorded)

        with tempfile.TemporaryDirectory(prefix="hxc-bridge-") as directory:
            with patch.object(Bridge, "_accept_loop", delayed_accept), patch.object(Bridge, "_serve", delayed_serve):
                bridge = Bridge(os.path.join(directory, "bridge.sock"), [])
                result = []
                try:
                    for payload in (b"", b"partial"):
                        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                            client.connect(bridge.path)
                            client.sendall(payload)

                    def collect():
                        try:
                            result.append(bridge.collect_finished_requests(timeout=5))
                        finally:
                            snapshot_done.set()

                    collector = threading.Thread(target=collect)
                    collector.start()
                    self.assertFalse(snapshot_done.wait(0.05))
                    accept_gate.set()
                    self.assertTrue(serve_started.wait(5))
                    self.assertFalse(snapshot_done.wait(0.05))
                    serve_gate.set()
                    collector.join(5)
                    self.assertFalse(collector.is_alive())
                    self.assertEqual(["", "partial"], sorted(result[0]))
                    self.assertEqual(["", "partial"], sorted(bridge.collect_finished_requests()))
                finally:
                    accept_gate.set()
                    serve_gate.set()
                    bridge.stop()

    def test_finished_requests_does_not_record_its_own_barrier(self):
        with tempfile.TemporaryDirectory(prefix="hxc-bridge-") as directory:
            bridge = Bridge(os.path.join(directory, "bridge.sock"), [])
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.connect(bridge.path)
                    client.sendall(b'{"tool":"create_thread"}\n')

                self.assertEqual(['{"tool":"create_thread"}'], bridge.collect_finished_requests())
            finally:
                bridge.stop()


class CasesAndRecordings(unittest.TestCase):
    def test_every_case_has_a_recording_and_every_recording_has_a_case(self):
        names = {case.name for case in load_cases()}
        recorded = {path.stem for path in (expected.EXPECTED / "cases").glob("*.json")}
        self.assertEqual(names, recorded)


def stub_case(**overrides):
    fields = {
        "name": "stub-case",
        "env": {"HARNEXUS_CALL_SOCKET": "{{bridge}}"},
        "bridge": [{"answer": {"outcome": "done"}}, {"answer": {"outcome": "done"}}],
        "commands": {"codex": {"stdout": "ok\n"}},
    }
    return make_case(**{**fields, **overrides})


# A stand-in CLI: it writes the state files, sends the requests, runs the command, prints and exits as its options say.
STUB = r'''
import json, os, socket, subprocess, sys
options = json.loads(sys.argv[1])
for path, text in options.get("state", {}).items():
    target = os.path.join(os.environ["XDG_STATE_HOME"], path)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "w") as written:
        written.write(text)
for line in options.get("requests", []):
    connection = socket.socket(socket.AF_UNIX)
    try:
        connection.connect(os.environ["HARNEXUS_CALL_SOCKET"])
        connection.sendall((line + "\n").encode())
        while connection.recv(4096):
            pass
    except OSError:
        pass
    finally:
        connection.close()
if options.get("command"):
    subprocess.run(options["command"], input=b"prompt", capture_output=True)
sys.stdout.write(options.get("stdout", ""))
sys.stderr.write(options.get("stderr", ""))
sys.exit(options.get("exit", 0))
'''

BASE = {
    "stdout": '{"a":1,"b":[1,2]}\n',
    "stderr": "note\n",
    "exit": 0,
    "state": {"taskctl/k1/state.json": '{"x":1}'},
    "requests": ['{"tool":"create_thread"}'],
    "command": ["codex", "review"],
}


if __name__ == "__main__":
    unittest.main()

"""The adapter runs as a process, because what a bridge relies on is its standard streams and its exit."""

import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

from harness import jsonvalue
from harness.binaries import require_binary

LINE_TIMEOUT_SECONDS = 20


def frame(line):
    return jsonvalue.dumps({"v": 1, **line}) + "\n"


HELLO = frame({"type": "hello", "mode": "write", "versions": [1]})


READY = frame({"type": "ready", "bindings": [], "conflicts": []})


def review_records(head):
    return [
        {
            "type": "assistant",
            "uuid": f"a-{head}",
            "message": {"content": [{"type": "tool_use", "id": head, "name": "Bash", "input": {}}]},
        },
        {
            "type": "user",
            "uuid": f"u-{head}",
            "message": {
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": head,
                        "content": jsonvalue.dumps(
                            {"status": "completed", "reviewer": "R1", "head": head, "answer": f"ok {head}"}
                        ),
                        "is_error": False,
                    }
                ]
            },
        },
    ]


def records_frame(event_id, phase, items):
    return frame(
        {
            "type": "event",
            "event": "session_records",
            "eventId": event_id,
            "sessionId": "session_one",
            "parentThreadId": "parent",
            "phase": phase,
            "linkedAt": None,
            "records": items,
        }
    )


class Adapter:
    """A running adapter: its lines are collected as they arrive, one whole line at a time."""

    def __init__(self, root):
        self.process = subprocess.Popen(
            [require_binary("HARNEXUS_CREW_NATIVE"), "adapter", "serve", "--id", "test"],
            env={
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "HOME": str(Path(root) / "home"),
                "XDG_STATE_HOME": str(Path(root) / "state"),
            },
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.lines = []
        self.rest = b""
        self.unreadable_line = None
        self._errors = []
        self._lock = threading.Lock()
        self._readers = [
            threading.Thread(target=self._read_lines, daemon=True),
            threading.Thread(target=self._read_errors, daemon=True),
        ]
        for reader in self._readers:
            reader.start()

    def _read_lines(self):
        while True:
            chunk = self.process.stdout.read1(65536)
            if chunk == b"":
                return
            with self._lock:
                self.rest += chunk
                while True:
                    end = self.rest.find(b"\n")
                    if end == -1:
                        break
                    text = self.rest[:end]
                    self.rest = self.rest[end + 1 :]
                    parsed = jsonvalue.try_loads(text.decode("utf-8", errors="replace"))
                    if parsed is None:
                        self.unreadable_line = text
                    else:
                        self.lines.append(parsed[0])

    def _read_errors(self):
        self._errors.append(self.process.stderr.read())

    def send(self, text):
        self.process.stdin.write(text.encode("utf-8"))
        self.process.stdin.flush()

    def close_input(self):
        self.process.stdin.close()

    def count(self):
        with self._lock:
            return len(self.lines)

    def snapshot(self):
        with self._lock:
            return list(self.lines)

    def wait_for(self, count):
        started = time.monotonic()
        while self.count() < count:
            if time.monotonic() - started > LINE_TIMEOUT_SECONDS:
                raise TimeoutError(f"only {self.count()} of {count} lines arrived")
            time.sleep(0.002)

    def wait_exit_code(self, timeout=None):
        try:
            return self.process.wait(timeout)
        except subprocess.TimeoutExpired:
            return None

    def finish(self):
        """Waits for the adapter to end and returns (code, stderr, unterminated output, unreadable line)."""
        code = self.process.wait()
        for reader in self._readers:
            reader.join()
        self.process.stdout.close()
        self.process.stderr.close()
        return code, b"".join(self._errors).decode("utf-8", errors="replace"), self.rest, self.unreadable_line

    def dispose(self):
        """Stops an adapter a test left running, and closes its pipes."""
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait()
        for reader in self._readers:
            reader.join()
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if not stream.closed:
                try:
                    stream.close()
                except OSError:
                    pass

    def kill(self):
        self.process.kill()


def count_open_fds(pid):
    # The adapter finishes writing its records after the last line it prints, so a count taken at once can catch a file still open.
    time.sleep(0.3)
    proc = Path(f"/proc/{pid}/fd")
    if proc.is_dir():
        return len(list(proc.iterdir()))
    listed = subprocess.run(["lsof", "-p", str(pid)], capture_output=True)
    return len([line for line in listed.stdout.decode("utf-8", errors="replace").split("\n") if line])


class NativeAdapterProcess(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="hxn-adapter-")
        (Path(self.root) / "home").mkdir()
        self.adapters = []
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def spawn(self):
        adapter = Adapter(self.root)
        self.adapters.append(adapter)
        self.addCleanup(adapter.dispose)
        return adapter

    def test_writes_each_of_many_answers_given_at_once_as_one_whole_line(self):
        adapter, (_, _, rest, unreadable_line) = self.close_after_many_requests()

        self.assertEqual((b"", None), (rest, unreadable_line))
        answered = [line["id"] for line in adapter.snapshot() if line.get("type") == "response"]
        self.assertEqual(sorted(f"h{index}" for index in range(MANY_REQUESTS)), sorted(answered))

    def test_ends_with_exit_code_0_and_no_error_output_when_the_bridge_closes_its_end_after_many_requests(self):
        _, (code, errors, _, _) = self.close_after_many_requests()

        self.assertEqual((0, ""), (code, errors))

    def test_sends_its_hello_before_the_answers_to_many_requests(self):
        adapter, _ = self.close_after_many_requests()

        self.assertEqual({"v": 1, "type": "hello", "adapterId": "test", "bindings": []}, adapter.snapshot()[0])

    def test_ends_with_exit_code_0_when_the_bridge_closes_its_end_with_a_request_unanswered(self):
        _, code = self.close_with_a_request_unanswered()

        self.assertEqual(0, code)

    def test_keeps_the_review_for_the_next_connection_when_the_bridge_closes_its_end_with_a_request_unanswered(self):
        self.close_with_a_request_unanswered()

        waiting = jsonvalue.loads((self.observe_directory() / "pending.json").read_text(encoding="utf-8"))
        self.assertEqual(["aaa1111"], [entry["review"]["head"] for entry in waiting])

    def test_releases_its_locks_when_the_bridge_closes_its_end_with_a_request_unanswered(self):
        self.close_with_a_request_unanswered()

        pending = self.observe_directory() / "pending.json"
        locks = self.observe_directory() / "locks"
        names = [path.name for path in locks.iterdir()] if locks.is_dir() else []
        self.assertTrue(pending.is_file())
        self.assertEqual([], [name for name in names if name.endswith(".lock")])

    def test_keeps_its_open_descriptors_flat_over_many_round_trips(self):
        reviews = Path(self.root) / "home" / ".local" / "state" / "harnexus" / "cloud-reviews"
        reviews.mkdir(parents=True)
        (reviews / "chats.json").write_text('{"R1":"chat-r1"}', encoding="utf-8")
        adapter = self.spawn()
        adapter.send(HELLO + READY + records_frame("e0", "linked", []))
        adapter.wait_for(2)
        handled = [2]

        def round_trip(index):
            # The last record of the previous event leads, so the adapter finds its cursor again.
            lead = [review_records(f"h{index - 1}")[1]] if index > 1 else []
            adapter.send(records_frame(f"e{index}", "continued", [*lead, *review_records(f"h{index}")]))
            adapter.wait_for(handled[0] + 2)
            handled[0] += 2
            request = adapter.snapshot()[-1]
            self.assertEqual("post", request.get("op"))
            adapter.send(frame({"type": "response", "id": request.get("id"), "outcome": "done"}))

        for index in range(1, 11):
            round_trip(index)
        before = count_open_fds(adapter.process.pid)
        for index in range(11, 161):
            round_trip(index)
        after = count_open_fds(adapter.process.pid)

        self.assertEqual(160, len([line for line in adapter.snapshot() if line.get("op") == "post"]))
        self.assertEqual(before, after)

    def close_after_many_requests(self):
        adapter = self.spawn()
        requests = [
            frame({"type": "request", "id": f"h{index}", "op": "history", "threadId": "x"}) for index in range(MANY_REQUESTS)
        ]
        adapter.send(HELLO + "".join(requests))
        adapter.close_input()
        return adapter, adapter.finish()

    def close_with_a_request_unanswered(self):
        adapter = self.spawn()
        adapter.send(HELLO + READY + records_frame("e1", "linked", []) + records_frame("e2", "continued", review_records("aaa1111")))
        adapter.wait_for(4)
        self.assertEqual("list_projects", adapter.snapshot()[-1].get("op"))
        adapter.close_input()
        code = adapter.wait_exit_code(15)
        if code is None:
            adapter.kill()
        return adapter, code

    def observe_directory(self):
        return Path(self.root) / "state" / "harnexus-crew" / "cloud-observe"


MANY_REQUESTS = 400


if __name__ == "__main__":
    unittest.main()

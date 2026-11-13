"""The state store runs as separate processes here, because locks and atomic writes are promises about other processes."""

import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from harness import jsonvalue
from harness.binaries import binary
from harness.cases import REPO

EXPECTATIONS = jsonvalue.loads((REPO / "test" / "native" / "store-expectations.json").read_text(encoding="utf-8"))


def start(*args):
    return subprocess.Popen([binary("HARNEXUS_STORE_PROBE"), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def reply(process):
    out, err = process.communicate()
    if process.returncode != 0:
        raise RuntimeError(f"probe exited {process.returncode}: {err.decode('utf-8', errors='replace')}")
    return jsonvalue.loads(out.decode("utf-8").strip().split("\n")[-1])


def run(*args):
    return reply(start(*args))


def run_together(count, arguments):
    """Starts `count` probes at once and returns their replies; `arguments(index)` gives each one's arguments."""
    processes = [start(*arguments(index)) for index in range(count)]
    return [reply(process) for process in processes]


def soon():
    """Processes started one by one begin together at a time a little ahead."""
    return str(int(time.time() * 1000) + 1500)


def dead_pid():
    finished = subprocess.Popen(["true"])
    finished.wait()
    return finished.pid


def leave_lock(lock, pid):
    Path(lock).write_text(jsonvalue.dumps({"pid": pid, "token": "dead"}), encoding="utf-8")


def token_in(lock):
    return jsonvalue.loads(Path(lock).read_text(encoding="utf-8"))["token"]


def hold(lock, kind):
    """Starts a holder and returns it with the line it printed once it holds the lock."""
    holder = start("hold", str(lock), kind)
    first = holder.stdout.readline()
    return holder, jsonvalue.loads(first.decode("utf-8"))


def stop(holder):
    holder.kill()
    holder.wait()
    holder.stdout.close()
    holder.stderr.close()


class StoreBetweenProcesses(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="harnexus-store-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.counter = 0

    def sandbox(self):
        self.counter += 1
        directory = self.root / f"case-{self.counter}"
        directory.mkdir()
        return directory


class LockBetweenProcesses(StoreBetweenProcesses):
    def test_of_several_runs_started_together_only_one_takes_the_lock(self):
        lock = self.sandbox() / "lock.json"
        at = soon()

        replies = run_together(16, lambda _: ("acquire", str(lock), "review", "600", at))

        taken = [answer for answer in replies if answer["ok"] is True]
        self.assertEqual(1, len(taken))
        for answer in [item for item in replies if item["ok"] is False]:
            self.assertRegex(answer["message"], r"^another review( \(pid \d+\))? is using this session$")
        self.assertFalse(lock.exists())

    def test_runs_racing_for_a_dead_holders_lock_never_hold_it_together(self):
        lock = self.sandbox() / "lock.json"
        leave_lock(lock, dead_pid())
        at = soon()

        replies = run_together(12, lambda _: ("acquire", str(lock), "review", "150", at))

        spans = sorted(
            ([int(answer["from"]), int(answer["to"])] for answer in replies if answer["ok"] is True),
            key=lambda span: span[0],
        )
        self.assertGreaterEqual(len(spans), 1)
        for index in range(1, len(spans)):
            self.assertGreaterEqual(spans[index][0], spans[index - 1][1])
        self.assertFalse(Path(f"{lock}.reap").exists())
        self.assertIs(True, run("acquire", str(lock), "review", "0", "0")["ok"])

    def test_a_killed_holders_lock_is_taken_over_and_the_new_holders_token_differs(self):
        lock = self.sandbox() / "lock.json"
        holder, held = hold(lock, "review")
        self.assertIs(True, held["ok"])

        stop(holder)
        taken = run("acquire", str(lock), "review", "0", "0")

        self.assertIs(True, taken["ok"])
        self.assertNotEqual(held["token"], taken["token"])

    def test_a_run_that_died_while_taking_over_leaves_the_lock_closed_until_its_marker_is_removed(self):
        lock = self.sandbox() / "lock.json"
        marker = Path(f"{lock}.reap")
        leave_lock(lock, dead_pid())
        self.assertIs(True, run("marker-die", str(lock))["ok"])
        at = soon()

        replies = run_together(6, lambda _: ("acquire", str(lock), "review", "0", at))

        for answer in replies:
            self.assertIs(False, answer["ok"])
            self.assertIn(f"left {lock} and {marker}", answer["message"])
        self.assertEqual("dead", token_in(lock))

        marker.unlink()
        self.assertIs(True, run("acquire", str(lock), "review", "0", "0")["ok"])

    def test_work_under_the_lock_loses_no_update_across_processes(self):
        directory = self.sandbox()
        locks = directory / "locks"
        counter = directory / "counter"
        at = soon()

        replies = run_together(6, lambda _: ("with-lock", str(locks), "chats", str(counter), "15", at, "20000"))

        for answer in replies:
            self.assertIs(True, answer["ok"])
        self.assertEqual("90", counter.read_text(encoding="utf-8"))
        self.assertEqual([], list(locks.iterdir()))

    def test_a_run_that_waits_longer_than_allowed_fails_and_names_the_holder(self):
        directory = self.sandbox()
        locks = directory / "locks"
        locks.mkdir()
        holder, _ = hold(locks / "chats.lock", "review")

        waited = run("with-lock", str(locks), "chats", str(directory / "counter"), "1", "0", "300")
        stop(holder)

        self.assertIs(False, waited["ok"])
        self.assertRegex(
            waited["message"],
            r"chats\.lock stayed locked: another harnexus-crew adapter \(pid \d+\) is using this session$",
        )


class FilesWrittenByProcesses(StoreBetweenProcesses):
    def test_of_several_writers_only_one_creates_the_file_with_its_whole_content(self):
        directory = self.sandbox()
        target = directory / "created.json"
        at = soon()
        contents = [str(index) * 200000 for index in range(16)]

        replies = run_together(16, lambda index: ("exclusive", str(target), str(index), "200000", at))

        winners = [index for index, answer in enumerate(replies) if answer["created"] is True]
        self.assertEqual(1, len(winners))
        self.assertEqual(contents[winners[0]], target.read_text(encoding="utf-8"))
        self.assertEqual(["created.json"], [path.name for path in directory.iterdir()])

    def test_a_reader_sees_a_whole_file_even_when_writers_are_killed_in_the_middle(self):
        directory = self.sandbox()
        target = directory / "state.json"
        size = 262144
        writers = [start("atomic-loop", str(target), letter, str(size), "1500") for letter in "abcd"]
        target.write_text("a" * size, encoding="utf-8")
        torn = []
        until = time.monotonic() + 1.2
        reads = 0
        killed = False

        while time.monotonic() < until:
            seen = target.read_text(encoding="utf-8")
            reads += 1
            if len(seen) != size or len(set(seen)) != 1:
                torn.append(seen[:20])
            if not killed and reads > 20:
                writers[1].kill()
                writers[3].kill()
                killed = True

        survivors = [reply(writers[0]), reply(writers[2])]
        for writer in (writers[1], writers[3]):
            writer.wait()
            writer.stdout.close()
            writer.stderr.close()

        for answer in survivors:
            self.assertGreater(int(answer["writes"]), 0)
        self.assertEqual([], torn)
        self.assertGreater(reads, 20)
        last = target.read_text(encoding="utf-8")
        self.assertEqual(size, len(last))
        self.assertEqual(1, len(set(last)))
        self.assertEqual(["state.json"], [path.name for path in directory.iterdir() if not path.name.endswith(".tmp")])

    def test_lines_appended_by_several_processes_arrive_whole(self):
        directory = self.sandbox()
        journal = directory / "logs" / "journal.jsonl"
        at = soon()
        names = ["p0", "p1", "p2", "p3", "p4"]

        replies = run_together(
            5,
            lambda index: ("append", str(journal), '{"from":"%s","pad":"%s"}' % (names[index], "x" * 5000), "40", at),
        )

        for answer in replies:
            self.assertIs(True, answer["ok"])
        lines = journal.read_text(encoding="utf-8").split("\n")
        self.assertEqual("", lines.pop())
        self.assertEqual(200, len(lines))
        counts = {}
        for line in lines:
            sender = jsonvalue.loads(line)["from"]
            counts[sender] = counts.get(sender, 0) + 1
        self.assertEqual([40, 40, 40, 40, 40], list(counts.values()))


class ReadingAndWritingFiles(StoreBetweenProcesses):
    def test_text_is_read_as_node_reads_it_including_a_byte_order_mark_and_invalid_bytes(self):
        directory = self.sandbox()
        for sample in EXPECTATIONS["reads"]:
            path = directory / sample["name"]
            if sample["name"] == "large":
                text = "0123456789" * 30000
                path.write_bytes(text.encode("utf-8"))
            else:
                path.write_bytes(bytes(sample["bytes"]))
                text = sample["text"]

            self.assertEqual(text, run("read", str(path))["text"], sample["name"])

    def test_a_missing_file_reads_as_null_and_a_fifo_is_refused_without_waiting(self):
        directory = self.sandbox()
        fifo = directory / "fifo"
        os.mkfifo(fifo)

        self.assertIsNone(run("read", str(directory / "missing"))["text"])
        refused = run("read-regular", str(fifo))

        self.assertEqual(f"cannot read {fifo}", refused["message"])

    def test_a_saved_record_reads_back_as_the_json_it_was_given(self):
        directory = self.sandbox()
        for index, document in enumerate(EXPECTATIONS["saved"]):
            path = directory / "nested" / f"{index}.json"

            answer = run("save-json", str(path), document["source"], "replace")

            self.assertIs(True, answer["ok"])
            self.assertEqual(jsonvalue.loads(document["source"]), jsonvalue.loads(path.read_text(encoding="utf-8")), document["source"])

    def test_a_record_file_is_owner_only_and_so_is_the_directory_made_for_it(self):
        directory = self.sandbox()
        path = directory / "made" / "deeper" / "state.json"

        run("save-json", str(path), '{"a":1}', "replace")

        self.assertEqual(0o600, path.stat().st_mode & 0o777)
        self.assertEqual(0o700, path.parent.stat().st_mode & 0o777)
        self.assertEqual(0o700, path.parent.parent.stat().st_mode & 0o777)

    def test_an_exclusive_record_is_refused_when_one_exists(self):
        path = self.sandbox() / "pending.json"

        first = run("save-json", str(path), '{"a":1}', "exclusive")
        second = run("save-json", str(path), '{"a":2}', "exclusive")

        self.assertIs(True, first["ok"])
        self.assertEqual(f"another harnexus-crew run is sending; inspect {path}", second["message"])
        self.assertEqual({"a": 1}, jsonvalue.loads(path.read_text(encoding="utf-8")))


class StateDirectories(unittest.TestCase):
    def test_keys_are_named_as_the_typescript_build_named_them(self):
        for name, kind, key in (
            ("a path key", "launch", "/Users/x/work\ntask-1"),
            ("a Japanese key", "review", "日本語のキー😀"),
            ("an empty key", "review", ""),
        ):
            with self.subTest(name):
                answer = run("state-directory", "/state/harnexus-crew", kind, key)

                digest = hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]
                self.assertEqual(f"/state/harnexus-crew/{kind}/{digest}", answer["path"])


if __name__ == "__main__":
    unittest.main()

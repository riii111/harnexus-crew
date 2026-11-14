"""The state store runs as separate processes here, because locks and atomic writes are promises about other processes."""

import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from harness import jsonvalue
from harness.binaries import require_binary
from harness.cases import REPO
from harness.processes import make_dead_pid


class StoreBetweenProcesses(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="harnexus-store-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.counter = 0

    def make_case_directory(self):
        self.counter += 1
        directory = self.root / f"case-{self.counter}"
        directory.mkdir()

        return directory


class LockBetweenProcesses(StoreBetweenProcesses):
    def test_of_several_runs_started_together_only_one_takes_the_lock(self):
        lock = self.make_case_directory() / "lock.json"
        at = shared_start_time()

        replies = run_together(16, lambda _: ("acquire", str(lock), "review", "600", at))

        taken = [answer for answer in replies if answer["ok"] is True]

        self.assertEqual(1, len(taken))

        for answer in [item for item in replies if item["ok"] is False]:
            self.assertRegex(answer["message"], r"^another review( \(pid \d+\))? is using this session$")

        self.assertFalse(lock.exists())

    def test_runs_racing_for_a_dead_holders_lock_never_hold_it_together(self):
        replies, _ = self.race_for_a_dead_holders_lock()

        spans = sorted(
            ([int(answer["from"]), int(answer["to"])] for answer in replies if answer["ok"] is True),
            key=lambda span: span[0],
        )

        self.assertGreaterEqual(len(spans), 1)

        for index in range(1, len(spans)):
            self.assertGreaterEqual(spans[index][0], spans[index - 1][1])

    def test_runs_racing_for_a_dead_holders_lock_leave_it_free_and_leave_no_takeover_marker(self):
        replies, lock = self.race_for_a_dead_holders_lock()

        self.assertGreaterEqual(len([answer for answer in replies if answer["ok"] is True]), 1)
        self.assertFalse(Path(f"{lock}.reap").exists())
        self.assertIs(True, run("acquire", str(lock), "review", "0", "0")["ok"])

    def test_a_killed_holders_lock_is_taken_over_with_a_new_token(self):
        lock = self.make_case_directory() / "lock.json"
        holder, held = hold(lock, "review")

        self.assertIs(True, held["ok"])

        stop(holder)
        taken = run("acquire", str(lock), "review", "0", "0")

        self.assertIs(True, taken["ok"])
        self.assertNotEqual(held["token"], taken["token"])

    def test_a_run_that_died_while_taking_over_leaves_the_lock_closed_until_its_marker_is_removed(self):
        lock = self.make_case_directory() / "lock.json"
        marker = Path(f"{lock}.reap")
        leave_lock(lock, make_dead_pid())

        self.assertIs(True, run("marker-die", str(lock))["ok"])
        at = shared_start_time()

        replies = run_together(6, lambda _: ("acquire", str(lock), "review", "0", at))

        for answer in replies:
            self.assertIs(False, answer["ok"])
            self.assertIn(f"left {lock} and {marker}", answer["message"])

        self.assertEqual("dead", read_token(lock))

        marker.unlink()

        self.assertIs(True, run("acquire", str(lock), "review", "0", "0")["ok"])

    def test_work_under_the_lock_loses_no_update_across_processes(self):
        replies, _, counter = self.work_under_the_lock()

        for answer in replies:
            self.assertIs(True, answer["ok"])

        self.assertEqual("90", counter.read_text(encoding="utf-8"))

    def test_work_under_the_lock_leaves_no_lock_file_behind(self):
        replies, locks, _ = self.work_under_the_lock()

        for answer in replies:
            self.assertIs(True, answer["ok"])

        self.assertEqual([], list(locks.iterdir()))

    def test_a_run_that_waits_longer_than_allowed_fails_and_names_the_holder(self):
        directory = self.make_case_directory()
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

    def race_for_a_dead_holders_lock(self):
        lock = self.make_case_directory() / "lock.json"
        leave_lock(lock, make_dead_pid())
        at = shared_start_time()

        replies = run_together(12, lambda _: ("acquire", str(lock), "review", "150", at))

        return replies, lock

    def work_under_the_lock(self):
        directory = self.make_case_directory()
        locks = directory / "locks"
        counter = directory / "counter"
        at = shared_start_time()

        replies = run_together(6, lambda _: ("with-lock", str(locks), "chats", str(counter), "15", at, "20000"))

        return replies, locks, counter


class FilesWrittenByProcesses(StoreBetweenProcesses):
    def test_of_several_writers_only_one_creates_the_file_with_its_whole_content(self):
        directory = self.make_case_directory()
        target = directory / "created.json"
        at = shared_start_time()
        contents = [str(index) * 200000 for index in range(16)]

        replies = run_together(16, lambda index: ("exclusive", str(target), str(index), "200000", at))

        winners = [index for index, answer in enumerate(replies) if answer["created"] is True]

        self.assertEqual(1, len(winners))
        self.assertEqual(contents[winners[0]], target.read_text(encoding="utf-8"))
        self.assertEqual(["created.json"], [path.name for path in directory.iterdir()])

    def test_a_reader_sees_a_whole_file_even_when_writers_are_killed_in_the_middle(self):
        directory = self.make_case_directory()
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

        survivors = [read_reply(writers[0]), read_reply(writers[2])]

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


class ReadingAndWritingFiles(StoreBetweenProcesses):
    def test_text_is_read_as_node_reads_it_including_a_byte_order_mark_and_invalid_bytes(self):
        directory = self.make_case_directory()

        for sample in EXPECTATIONS["reads"]:
            path = directory / sample["name"]

            if sample["name"] == "large":
                text = "0123456789" * 30000
                path.write_bytes(text.encode("utf-8"))
            else:
                path.write_bytes(bytes(sample["bytes"]))
                text = sample["text"]

            with self.subTest(sample["name"]):
                self.assertEqual(text, run("read", str(path))["text"])

    def test_a_missing_file_reads_as_null(self):
        directory = self.make_case_directory()
        (directory / "present").write_text("kept", encoding="utf-8")

        self.assertEqual("kept", run("read", str(directory / "present"))["text"])
        self.assertIsNone(run("read", str(directory / "missing"))["text"])

    def test_a_fifo_is_refused_without_waiting(self):
        fifo = self.make_case_directory() / "fifo"
        os.mkfifo(fifo)

        refused = run("read-regular", str(fifo))

        self.assertEqual(f"cannot read {fifo}", refused["message"])

    def test_a_record_file_is_owner_only(self):
        path = self.make_case_directory() / "made" / "deeper" / "state.json"

        run("save-json", str(path), '{"a":1}', "replace")

        self.assertEqual(0o600, path.stat().st_mode & 0o777)

    def test_the_directories_made_for_a_record_file_are_owner_only(self):
        path = self.make_case_directory() / "made" / "deeper" / "state.json"

        run("save-json", str(path), '{"a":1}', "replace")

        self.assertEqual((0o700, 0o700), (path.parent.stat().st_mode & 0o777, path.parent.parent.stat().st_mode & 0o777))

    def test_an_exclusive_record_is_refused_when_one_exists(self):
        path = self.make_case_directory() / "pending.json"

        first = run("save-json", str(path), '{"a":1}', "exclusive")
        second = run("save-json", str(path), '{"a":2}', "exclusive")

        self.assertIs(True, first["ok"])
        self.assertEqual(f"another harnexus-crew run is sending; inspect {path}", second["message"])
        self.assertEqual({"a": 1}, jsonvalue.loads(path.read_text(encoding="utf-8")))


def shared_start_time():
    """Processes started one by one begin together at a time a little ahead."""
    return str(int(time.time() * 1000) + 1500)


def run_together(count, arguments):
    """Starts `count` probes at once and returns their replies; `arguments(index)` gives each one's arguments."""
    processes = [start(*arguments(index)) for index in range(count)]

    return [read_reply(process) for process in processes]


def run(*args):
    return read_reply(start(*args))


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


def leave_lock(lock, pid):
    Path(lock).write_text(jsonvalue.dumps({"pid": pid, "token": "dead"}), encoding="utf-8")


def read_token(lock):
    return jsonvalue.loads(Path(lock).read_text(encoding="utf-8"))["token"]


def read_reply(process):
    out, err = process.communicate()

    if process.returncode != 0:
        raise RuntimeError(f"probe exited {process.returncode}: {err.decode('utf-8', errors='replace')}")

    return jsonvalue.loads(out.decode("utf-8").strip().split("\n")[-1])


def start(*args):
    return subprocess.Popen([require_binary("HARNEXUS_STORE_PROBE"), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)


EXPECTATIONS = jsonvalue.loads((REPO / "test" / "native" / "store-expectations.json").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()

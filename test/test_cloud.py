"""Cloud reviews (Codex CLI in a Claude Code cloud session) run as processes against a stand-in Codex CLI."""

import hashlib
import os
import shutil
import subprocess
import time
import unittest
from pathlib import Path

from harness import jsonvalue
from harness.asserts import ScenarioAsserts
from harness.cases import REPO
from harness.rig import observed, parsed_or_text, recorded, with_rig

REVIEWER = "01a18d52-e03a-74c1-a50e-4e697b47172b"
OTHER = "01a18d52-e03a-74c1-a50e-4e697b47172c"
BASE = "af314261c610837f3606d61aa2dff1981debda94"
HEAD_1 = "a6bc63c9fd9d736a274586bb4a3989bc27297649"

REPO_PATH = "{{root}}/cloud/repo"
REQUEST = {
    "taskId": "example",
    "workerAI": "Claude",
    "checkout": REPO_PATH,
    "baseBranch": "base",
    "documentRefs": ["https://example.com/task"],
    "prUrl": None,
}
REPOSITORY = [
    ["init", "-q", REPO_PATH],
    ["-C", REPO_PATH, "commit", "--allow-empty", "-qm", "test: initial"],
    ["-C", REPO_PATH, "branch", "base"],
    ["-C", REPO_PATH, "commit", "--allow-empty", "-qm", "test: candidate 1"],
]
FAKE = str(REPO / "test" / "native" / "mocks" / "fake-cli.sh")
REVIEW = ["review", "--request", "review.json"]
ASK = [*REVIEW, "--ask", "ask.md"]
TIMED = {"HARNEXUS_REVIEW_TIMEOUT_MS": "400", "HARNEXUS_REVIEW_KILL_GRACE_MS": "400"}
RUN_TIMEOUT_SECONDS = 60


def events(thread_id, answer):
    return "\n".join(
        jsonvalue.dumps(event)
        for event in [
            {"type": "thread.started", "thread_id": thread_id},
            {"type": "turn.started"},
            {"type": "item.completed", "item": {"id": "item_0", "type": "agent_message", "text": answer}},
            {"type": "turn.completed", "usage": {"input_tokens": 1, "output_tokens": 1}},
        ]
    )


def planned(runs):
    """The stand-in for codex replays run n from these files, and records what it was given in the same directory."""
    files = {}
    for index, run in enumerate(runs):
        n = index + 1
        files[f"fake/out.{n}"] = run.get("out", "")
        files[f"fake/exit.{n}"] = str(run.get("exit", 0))
        if "stderr" in run:
            files[f"fake/stderr.{n}"] = run["stderr"]
        if "sleep" in run:
            files[f"fake/sleep.{n}"] = run["sleep"]
    return files


def scenario_fields(runs, env=None, files=None, request=None):
    return {
        "env": {
            "CLAUDE_CODE_REMOTE": "true",
            "CLAUDE_CODE_SESSION_ID": "worker-session",
            "HARNEXUS_CODEX_BIN": FAKE,
            "FAKE_DIR": "{{root}}/fake",
            "HOME": "{{root}}/cloud",
            **(env or {}),
        },
        "seed": {"skills": "test/fixtures/task-skills"},
        "git": REPOSITORY,
        # The recorded arguments, directories and prompts of the stand-in are compared with the state.
        "snapshot": ["state", "fake", "work"],
        "files": {
            "config/harnexus/task.json": jsonvalue.dumps(
                {"templates": {"reviewer": "{{root}}/skills/task-review-cycle/references/reviewer.md"}}
            ),
            "work/review.json": jsonvalue.dumps(request or REQUEST),
            "work/ask.md": "B1 はまだ残っていますか",
            **planned(runs),
            **(files or {}),
        },
    }


def dead_pid():
    """A process that has ended, whose ID no run is using."""
    finished = subprocess.Popen(["true"])
    finished.wait()
    return finished.pid


def candidate(rig, message):
    rig.commit(message, REPO_PATH)


def codes(steps):
    return [step["code"] for step in steps]


def state_directories(rig):
    base = Path(rig.sandbox.root) / "state" / "harnexus-crew" / "cloud-review"
    return sorted(base.iterdir()) if base.is_dir() else []


def lock_held(rig):
    """Waits until a run holds the session's lock."""
    for _ in range(400):
        for directory in state_directories(rig):
            if (directory / "lock.json").exists():
                return directory
        time.sleep(0.025)
    raise AssertionError("no run took the lock")


def state_of(stdout):
    path = Path(stdout["state"])
    return path, jsonvalue.loads(path.read_text(encoding="utf-8"))


def without_pid(node, pid):
    """The ID of a process that has ended differs on every run, so it is named <DEAD_PID>."""
    if isinstance(node, dict):
        return {key: "<DEAD_PID>" if key == "pid" and value == pid else without_pid(value, pid) for key, value in node.items()}
    if isinstance(node, list):
        return [without_pid(item, pid) for item in node]
    if isinstance(node, str):
        return node.replace(f'"pid":{pid}', '"pid":"<DEAD_PID>"')
    return node


def write_json(path, value):
    Path(path).write_text(jsonvalue.dumps(value), encoding="utf-8")


class CloudReviews(ScenarioAsserts, unittest.TestCase):
    def scenario(self, name, runs, body, **options):
        """Runs the scenario on the Native build and checks it against what the TypeScript build did."""
        done = with_rig({"name": name, **scenario_fields(runs, **options)}, body, timeout=RUN_TIMEOUT_SECONDS)
        native = observed(done, steady=True)
        self.assertSameJson(recorded(name, done), without_pid(native, self.dead))
        return native

    def setUp(self):
        self.dead = dead_pid()

    def test_review_the_first_head_resume_the_reviewer_on_a_new_one_and_refuse_a_head_already_judged(self):
        def body(rig):
            first = rig.run(REVIEW)
            again = rig.run(REVIEW)
            candidate(rig, "test: candidate 2")
            second = rig.run(REVIEW)
            third = rig.run(REVIEW)
            return [first, again, second, third]

        native = self.scenario(
            "cloud-review-flow",
            [{"out": events(REVIEWER, "判定: 修正必要\n対象: …")}, {"out": events(REVIEWER, "判定: LGTM")}],
            body,
        )
        steps = native["result"]
        self.assertEqual([0, 1, 0, 1], codes(steps))
        self.assertMatches(
            steps[0]["stdout"],
            {"status": "completed", "verdict": "修正必要", "base": BASE, "head": HEAD_1, "reviewer": REVIEWER},
        )
        self.assertIn(
            f"head {HEAD_1} was already reviewed by {REVIEWER}; commit a fix before asking again",
            steps[1]["stderr"],
        )
        self.assertMatches(steps[2]["stdout"], {"verdict": "LGTM", "base": BASE, "reviewer": REVIEWER})
        files = native["files"]
        self.assertIn("--sandbox\nread-only", files["fake/args.1"])
        self.assertIn(f"resume\n{REVIEWER}", files["fake/args.2"])
        self.assertEqual("2\n", files["fake/count"])

    def test_send_a_head_again_when_the_reviewer_could_not_judge_it_or_gave_no_verdict(self):
        native = self.scenario(
            "cloud-review-unjudged",
            [
                {"out": events(REVIEWER, "判定: 判定保留")},
                {"out": events(REVIEWER, "指摘は以上です")},
                {"out": events(REVIEWER, "判定: LGTM")},
            ],
            lambda rig: [rig.run(REVIEW), rig.run(REVIEW), rig.run(REVIEW), rig.run(REVIEW)],
        )
        self.assertEqual([0, 0, 0, 1], codes(native["result"]))
        self.assertEqual("3\n", native["files"]["fake/count"])

    def test_count_a_head_recorded_before_verdicts_were_kept_as_judged(self):
        def body(rig):
            first = rig.run(REVIEW)
            path, state = state_of(parsed_or_text(first["stdout"]))
            del state["verdict"]
            path.write_text(jsonvalue.dumps(state), encoding="utf-8")
            return [first, rig.run(REVIEW)]

        native = self.scenario(
            "cloud-review-old-state",
            [{"out": events(REVIEWER, "判定: 修正必要")}, {"out": events(REVIEWER, "判定: LGTM")}],
            body,
        )
        self.assertEqual([0, 1], codes(native["result"]))
        self.assertEqual("1\n", native["files"]["fake/count"])

    def test_leave_nothing_pending_after_a_run_that_reviewed_nothing_and_keep_the_reviewer(self):
        def body(rig):
            first = rig.run(REVIEW)
            candidate(rig, "test: candidate 2")
            failed = rig.run(REVIEW)
            retried = rig.run(REVIEW)
            return [first, failed, retried]

        native = self.scenario(
            "cloud-review-failed-run",
            [
                {"out": events(REVIEWER, "判定: 修正必要")},
                {"exit": 1, "stderr": "network down"},
                {"out": events(OTHER, "判定: LGTM")},
            ],
            body,
        )
        steps = native["result"]
        self.assertEqual([0, 1, 0], codes(steps))
        self.assertIn("codex did not review (exit 1): network down", steps[1]["stderr"])
        # The third run resumed the kept reviewer, and takes the thread its events name.
        self.assertMatches(steps[2]["stdout"], {"reviewer": OTHER})
        self.assertIn(f"resume\n{REVIEWER}", native["files"]["fake/args.3"])
        self.assertFalse(any(path.endswith("pending.json") for path in native["files"]))

    def test_start_a_new_reviewer_once_the_old_one_is_gone_from_the_machine(self):
        def body(rig):
            first = rig.run(REVIEW)
            candidate(rig, "test: candidate 2")
            gone = rig.run(REVIEW)
            started = rig.run(REVIEW)
            return [first, gone, started]

        native = self.scenario(
            "cloud-review-reviewer-gone",
            [
                {"out": events(REVIEWER, "判定: 修正必要")},
                {"exit": 1, "stderr": f"ERROR: no rollout found for thread id {REVIEWER}"},
                {"out": events(OTHER, "判定: LGTM")},
            ],
            body,
        )
        steps = native["result"]
        self.assertEqual([0, 1, 0], codes(steps))
        self.assertIn(
            f"reviewer {REVIEWER} is gone from this machine; run review again to start a new reviewer",
            steps[1]["stderr"],
        )
        self.assertMatches(steps[2]["stdout"], {"reviewer": OTHER})
        self.assertNotIn("resume", native["files"]["fake/args.3"])

    def test_hold_a_review_that_was_stopped_until_it_is_discarded_and_send_it_again(self):
        native = self.scenario(
            "cloud-review-stopped",
            [{"out": events(REVIEWER, "判定: LGTM"), "sleep": "5"}, {"out": events(REVIEWER, "判定: LGTM")}],
            lambda rig: [
                rig.run(REVIEW),
                rig.run(REVIEW),
                rig.run([*REVIEW, "--recover", "discard"]),
                rig.run([*REVIEW, "--recover", "discard"]),
            ],
            env=TIMED,
        )
        steps = native["result"]
        self.assertEqual([1, 1, 0, 1], codes(steps))
        self.assertIn("codex was stopped (timeout)", steps[0]["stderr"])
        self.assertIn(f"the review of head {HEAD_1} did not report back", steps[1]["stderr"])
        self.assertIn("--recover applies only when a review is pending", steps[3]["stderr"])
        self.assertEqual("2\n", native["files"]["fake/count"])

    def test_stop_a_run_whose_output_passes_the_limit(self):
        def body(rig):
            os.chmod(os.path.join(rig.sandbox.root, "loud.sh"), 0o755)
            return [rig.run(REVIEW), rig.run(REVIEW)]

        native = self.scenario(
            "cloud-review-output-limit",
            [],
            body,
            env={"HARNEXUS_CODEX_BIN": "{{root}}/loud.sh", "HARNEXUS_REVIEW_KILL_GRACE_MS": "400"},
            files={"loud.sh": "#!/bin/sh\ncat > /dev/null\nhead -c 17000000 /dev/zero | tr '\\0' 'x'\nsleep 5\n"},
        )
        steps = native["result"]
        self.assertEqual([1, 1], codes(steps))
        self.assertIn("codex was stopped (output over the limit)", steps[0]["stderr"])

    def test_pass_a_question_to_the_reviewer_and_answer_with_its_reply_leaving_the_state_as_it_was(self):
        def body(rig):
            before = rig.run(ASK)
            first = rig.run(REVIEW)
            path, kept = state_of(parsed_or_text(first["stdout"]))
            asked = rig.run(ASK)
            self.assertEqual(kept, jsonvalue.loads(path.read_text(encoding="utf-8")))
            return [before, first, asked]

        native = self.scenario(
            "cloud-review-ask",
            [
                {"out": events(REVIEWER, "判定: 修正必要")},
                {"out": events(REVIEWER, "B1 は残っています。\n判定: LGTM")},
            ],
            body,
        )
        steps = native["result"]
        self.assertEqual([1, 0, 0], codes(steps))
        self.assertIn("this task has no reviewer yet; run review first", steps[0]["stderr"])
        self.assertMatches(
            steps[2]["stdout"],
            {
                "status": "completed",
                "kind": "reply",
                "verdict": "LGTM",
                "head": HEAD_1,
                "reviewer": REVIEWER,
                "answer": "B1 は残っています。\n判定: LGTM",
            },
        )
        self.assertEqual("B1 はまだ残っていますか", native["files"]["fake/stdin.2"])

    def test_refuse_a_question_with_no_text_with_a_missing_file_and_for_a_stopped_run(self):
        def body(rig):
            rig.run(REVIEW)
            return [
                rig.run([*REVIEW, "--ask", "blank.md"]),
                rig.run([*REVIEW, "--ask", "absent.md"]),
                rig.run(ASK),
                rig.run(ASK),
            ]

        native = self.scenario(
            "cloud-review-ask-refused",
            [
                {"out": events(REVIEWER, "判定: 修正必要")},
                {"out": events(REVIEWER, "x"), "sleep": "5"},
                {"exit": 2, "stderr": "no model"},
            ],
            body,
            env=TIMED,
            files={"work/blank.md": " \n　\n"},
        )
        steps = native["result"]
        self.assertEqual([1, 1, 1, 1], codes(steps))
        self.assertIn("the --ask file is empty", steps[0]["stderr"])
        self.assertIn("cannot read absent.md", steps[1]["stderr"])
        self.assertIn(f"codex was stopped (timeout) in reviewer {REVIEWER}; it may have answered", steps[2]["stderr"])
        self.assertIn(f"reviewer {REVIEWER} did not answer (exit 2): no model", steps[3]["stderr"])

    def test_refuse_a_second_run_while_one_holds_the_session_and_take_over_a_dead_runs_session(self):
        def body(rig):
            holder = rig.start(REVIEW)
            directory = lock_held(rig)
            refused = rig.run(REVIEW)
            refused_ask = rig.run(ASK)
            finished = holder.ended()
            # A run that died leaves its lock, which the next run takes over.
            write_json(directory / "lock.json", {"pid": self.dead, "token": "gone", "startedAt": "x"})
            candidate(rig, "test: candidate 2")
            taken = rig.run(REVIEW)
            lock = (directory / "lock.json").exists()
            return [refused, refused_ask, finished, taken, {"lock": lock}]

        native = self.scenario(
            "cloud-review-lock",
            [{"out": events(REVIEWER, "判定: LGTM"), "sleep": "2"}, {"out": events(REVIEWER, "判定: 修正必要")}],
            body,
        )
        steps = native["result"]
        self.assertEqual([1, 1, 0, 0], codes(steps[:4]))
        self.assertIn("another review (pid <PID>) is using this session", steps[0]["stderr"])
        self.assertEqual({"lock": False}, steps[4])

    def test_refuse_to_take_over_a_session_while_a_takeover_died_half_way(self):
        def body(rig):
            first = rig.run(REVIEW)
            directory = state_directories(rig)[0]
            write_json(directory / "lock.json", {"pid": self.dead, "token": "gone", "startedAt": "x"})
            write_json(directory / "lock.json.reap", {"pid": self.dead})
            candidate(rig, "test: candidate 2")
            return [first, rig.run(REVIEW)]

        native = self.scenario(
            "cloud-review-takeover-died", [{"out": events(REVIEWER, "判定: LGTM")}], body
        )
        steps = native["result"]
        self.assertEqual([0, 1], codes(steps))
        self.assertIn("a run that was taking over this session died before it finished", steps[1]["stderr"])


RECORDED_ROOT = "/tmp/taskctl-legacy"
LEGACY_FIXTURE = REPO / "test" / "fixtures" / "legacy-state" / "cloud" / "state" / "taskctl"


def place_legacy_state(rig):
    """Paths in the recorded state read @ROOT@, and directories keyed by a path are moved to the key of the test's own root."""
    root = rig.sandbox.root
    state = Path(root) / "state" / "harnexus-crew" / "cloud-review"
    state.mkdir(parents=True, exist_ok=True)
    for recorded_key, task in (("3e52769db5ac05f8", "judged"), ("470a1ab24e770f8c", "lost")):
        recorded_at = hashlib.sha256(f"{RECORDED_ROOT}/cloud/repo\0{task}".encode("utf-8")).hexdigest()[:16]
        if recorded_at != recorded_key:
            raise AssertionError("the recorded review key no longer matches the SHA-256 layout")
        key = hashlib.sha256(jsonvalue.lossy_bytes(f"{root}/cloud/repo\0{task}")).hexdigest()[:16]
        target = state / key
        shutil.copytree(LEGACY_FIXTURE / "cloud-review" / recorded_key, target)
        for path in target.iterdir():
            path.write_text(path.read_text(encoding="utf-8").replace("@ROOT@", root), encoding="utf-8")


def task_request(task):
    return {**REQUEST, "taskId": task}


class CloudReviewsHarnexusTaskLeft(ScenarioAsserts, unittest.TestCase):
    def scenario(self, name, runs, body, **options):
        done = with_rig({"name": name, **scenario_fields(runs, **options)}, body, timeout=RUN_TIMEOUT_SECONDS)
        native = observed(done, steady=True)
        self.assertSameJson(recorded(name, done), native)
        return native

    def test_ask_the_same_reviewer_and_re_review_a_new_head_with_it_from_the_recorded_base(self):
        def body(rig):
            place_legacy_state(rig)
            asked = rig.run(ASK)
            candidate(rig, "test: fix B1")
            reviewed = rig.run(REVIEW)
            return [asked, reviewed]

        native = self.scenario(
            "cloud-review-legacy-judged",
            [{"out": events(REVIEWER, "B1 は残っています。")}, {"out": events(REVIEWER, "判定: LGTM")}],
            body,
            request=task_request("judged"),
            files={"work/ask.md": "B1 はまだ残っていますか"},
        )
        steps = native["result"]
        self.assertEqual([0, 0], codes(steps))
        self.assertMatches(
            steps[0]["stdout"],
            {"kind": "reply", "head": HEAD_1, "reviewer": REVIEWER, "answer": "B1 は残っています。"},
        )
        self.assertMatches(steps[1]["stdout"], {"verdict": "LGTM", "base": BASE, "reviewer": REVIEWER})
        for n in (1, 2):
            self.assertIn(f"exec\nresume\n{REVIEWER}\n", native["files"][f"fake/args.{n}"])

    def test_hold_the_review_whose_result_was_unknown_until_it_is_discarded_then_send_it_again(self):
        def body(rig):
            place_legacy_state(rig)
            held = rig.run(REVIEW)
            recovered = rig.run([*REVIEW, "--recover", "discard"])
            return [held, recovered]

        native = self.scenario(
            "cloud-review-legacy-lost",
            [{"out": events(REVIEWER, "判定: 修正必要")}],
            body,
            request=task_request("lost"),
        )
        steps = native["result"]
        self.assertEqual([1, 0], codes(steps))
        self.assertIn("--recover discard", steps[0]["stderr"])
        self.assertMatches(steps[1]["stdout"], {"verdict": "修正必要", "base": BASE, "head": HEAD_1})
        self.assertNotIn("resume", native["files"]["fake/args.1"])


if __name__ == "__main__":
    unittest.main()

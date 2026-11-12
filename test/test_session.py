"""The session commands (launch, review, state, resolve, name) run as processes against a stand-in bridge."""

import hashlib
import os
import shutil
import time
import unittest
from pathlib import Path

from harness import jsonvalue
from harness.asserts import ScenarioAsserts
from harness.cases import REPO
from harness.rig import observed, recorded, wait_for, with_rig

SKILLS = {"skills": "test/fixtures/task-skills"}
CONFIG = {
    "config/harnexus/task.json": jsonvalue.dumps(
        {
            "templates": {
                "worker": "{{root}}/skills/task-session-launch/references/worker.md",
                "reviewer": "{{root}}/skills/task-review-cycle/references/reviewer.md",
            }
        }
    )
}
ENV = {"HARNEXUS_CALL_SOCKET": "{{bridge}}", "CODEX_THREAD_ID": "w1"}
CAPS = {
    "match": {"query": "capabilities"},
    "answer": {
        "version": 1,
        "outcome": "done",
        "operations": ["list_projects", "create_thread", "send_message_to_thread", "name_thread"],
    },
}


def answer(tool, reply):
    return {"match": {"tool": tool}, "answer": {"version": 1, **reply}}


LIST = answer(
    "list_projects",
    {"outcome": "done", "result": {"projects": [{"projectId": "p-review", "path": "{{home}}/review-home"}]}},
)
LAUNCH_REQUEST = {
    "taskId": "TR1",
    "documentRefs": ["https://example.com/task"],
    "completionTarget": "draft_pr",
    "projectId": "project",
}
REPO_PATH = "{{home}}/.codex/worktrees/ab12/repo"
REVIEW_REQUEST = {
    "taskId": "TR1",
    "workerAI": "Codex",
    "projectId": "project",
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
LAUNCH = ["launch", "--request", "launch.json"]
REVIEW = ["review", "--request", "review.json"]
BASE = "af314261c610837f3606d61aa2dff1981debda94"
HEAD_2 = "5455abba46706efa2a58a43a55b97e9d40eaa4ec"


def launch_fields(bridge):
    return {
        "env": ENV,
        "seed": SKILLS,
        "bridge": bridge,
        "files": {**CONFIG, "work/launch.json": jsonvalue.dumps(LAUNCH_REQUEST)},
    }


def review_fields(bridge):
    return {
        "env": ENV,
        "seed": SKILLS,
        "bridge": bridge,
        "git": REPOSITORY,
        "files": {**CONFIG, "work/review.json": jsonvalue.dumps(REVIEW_REQUEST)},
    }


def candidate(rig, message, repository=REPO_PATH):
    rig.commit(message, repository)


def codes(steps):
    return [step["code"] for step in steps]


def key_directory(key):
    return hashlib.sha256(jsonvalue.lossy_bytes(key)).hexdigest()[:16]


class SessionCommands(ScenarioAsserts, unittest.TestCase):
    def scenario(self, name, fields, body, strip=lambda seen: seen):
        """Runs the scenario on the Native build and checks it against what the TypeScript build did."""
        done = with_rig({"name": name, **fields}, body)
        native = observed(done)
        self.assertSameJson(strip(recorded(name, done)), strip(native))
        return native

    def test_keep_one_worker_per_task_and_show_rename_and_link_it(self):
        native = self.scenario(
            "session-launch-flow",
            {
                **launch_fields(
                    [
                        CAPS,
                        answer(
                            "create_thread",
                            {"outcome": "done", "threadId": "w1", "model": "claude-sonnet-5-5", "effort": "high"},
                        ),
                        CAPS,
                        answer("name_thread", {"outcome": "done"}),
                    ]
                ),
                "commands": {"pr-wake": {"stdout": '{"watched":"https://github.com/o/r/pull/3"}\n'}},
            },
            lambda rig: [
                rig.run(LAUNCH),
                rig.run(LAUNCH),
                rig.run(["state", "--request", "launch.json"]),
                rig.run(["name", "--pr", "https://github.com/o/r/pull/3"]),
            ],
        )
        steps = native["result"]
        self.assertEqual([0, 0, 0, 0], codes(steps))
        self.assertMatches(steps[1]["stdout"], {"existing": "w1"})
        self.assertMatches(
            steps[3]["stdout"], {"title": "Impl TR1 PR#3", "watched": "https://github.com/o/r/pull/3"}
        )
        created = [r for r in native["requests"] if isinstance(r, dict) and r.get("tool") == "create_thread"]
        self.assertEqual(1, len(created))

    def test_hold_a_launch_whose_answer_was_lost_until_the_user_settles_it(self):
        native = self.scenario(
            "session-launch-lost",
            launch_fields(
                [CAPS, answer("create_thread", {"outcome": "unknown", "error": "timed out"})]
            ),
            lambda rig: [
                rig.run(LAUNCH),
                rig.run(LAUNCH),
                rig.run(["resolve", "--request", "launch.json", "--sent", "--thread-id", "w9"]),
                rig.run(LAUNCH),
            ],
        )
        steps = native["result"]
        self.assertEqual([1, 1, 0, 0], codes(steps))
        self.assertIn("previous create_thread ended as unknown; never resend", steps[1]["stderr"])
        self.assertMatches(steps[3]["stdout"], {"existing": "w9"})
        self.assertEqual(2, len(native["requests"]))
        self.assertFalse(any(path.endswith("pending.json") for path in native["files"]))

    def test_start_no_second_worker_after_a_run_that_was_sent_and_then_released(self):
        native = self.scenario(
            "session-launch-not-sent",
            launch_fields(
                [
                    CAPS,
                    answer("create_thread", {"outcome": "unknown", "error": "lost"}),
                    CAPS,
                    answer(
                        "create_thread",
                        {"outcome": "done", "threadId": "w2", "model": "claude-sonnet-5-5", "effort": "high"},
                    ),
                ]
            ),
            lambda rig: [
                rig.run(LAUNCH),
                rig.run(["resolve", "--request", "launch.json", "--not-sent"]),
                rig.run(LAUNCH),
            ],
        )
        steps = native["result"]
        self.assertEqual([1, 0, 0], codes(steps))
        self.assertEqual({"released": "create_thread", "status": "unknown"}, steps[1]["stdout"])
        self.assertMatches(steps[2]["stdout"], {"threadId": "w2"})

    def test_keep_a_reviewer_send_each_head_once_and_send_a_new_head_to_the_same_reviewer(self):
        def body(rig):
            first = rig.run(REVIEW)
            again = rig.run(REVIEW)
            candidate(rig, "test: candidate 2")
            second = rig.run(REVIEW)
            shown = rig.run(["state", "--request", "review.json"])
            return [first, again, second, shown]

        native = self.scenario(
            "session-review-flow",
            review_fields(
                [
                    CAPS,
                    LIST,
                    CAPS,
                    answer(
                        "create_thread",
                        {"outcome": "done", "threadId": "r1", "model": "gpt-6.1-sol", "effort": "medium"},
                    ),
                    CAPS,
                    answer("send_message_to_thread", {"outcome": "done", "threadId": "r1"}),
                ]
            ),
            body,
        )
        steps = native["result"]
        self.assertEqual([0, 1, 0, 0], codes(steps))
        self.assertIn("was already sent to reviewer r1; wait for its result", steps[1]["stderr"])
        self.assertMatches(steps[2]["stdout"], {"tool": "send_message_to_thread", "threadId": "r1"})
        self.assertMatches(
            steps[3]["stdout"],
            {"reviewerThreadId": "r1", "workerThreadId": "w1", "baseBranch": "base", "pending": None},
        )

    def test_refuse_a_changed_base_branch_until_the_base_is_updated(self):
        def body(rig):
            rig.run(REVIEW)
            rig.git("-C", rig.sandbox.expand(REPO_PATH), "branch", "other")
            candidate(rig, "test: candidate 2")
            rig.write_work("review.json", jsonvalue.dumps({**REVIEW_REQUEST, "baseBranch": "other"}))
            refused = rig.run(REVIEW)
            updated = rig.run([*REVIEW, "--update-base"])
            return [refused, updated]

        native = self.scenario(
            "session-review-base",
            review_fields(
                [
                    CAPS,
                    LIST,
                    CAPS,
                    answer("create_thread", {"outcome": "done", "threadId": "r1"}),
                    CAPS,
                    answer("send_message_to_thread", {"outcome": "done", "threadId": "r1"}),
                ]
            ),
            body,
        )
        steps = native["result"]
        self.assertIn("baseBranch changed; use --update-base after integrating upstream", steps[0]["stderr"])
        self.assertEqual(0, steps[1]["code"])

    def test_hold_a_review_whose_answer_was_lost_and_send_the_head_again_once_it_is_settled(self):
        def body(rig):
            lost = rig.run(REVIEW)
            candidate(rig, "test: candidate 2")
            blocked = rig.run(REVIEW)
            resolved = rig.run(["resolve", "--request", "review.json", "--sent"])
            candidate(rig, "test: candidate 3")
            resent = rig.run(REVIEW)
            return [lost, blocked, resolved, resent]

        native = self.scenario(
            "session-review-lost",
            review_fields(
                [
                    CAPS,
                    LIST,
                    CAPS,
                    answer(
                        "create_thread", {"outcome": "unknown", "threadId": "r1", "error": "timed out"}
                    ),
                    CAPS,
                    answer("send_message_to_thread", {"outcome": "done", "threadId": "r1"}),
                ]
            ),
            body,
        )
        steps = native["result"]
        self.assertEqual([1, 1, 0, 0], codes(steps))
        self.assertIn("previous create_thread ended as unknown; never resend", steps[1]["stderr"])
        self.assertMatches(steps[3]["stdout"], {"tool": "send_message_to_thread", "threadId": "r1"})

    def test_keep_a_refused_first_turn_apart_until_it_is_resolved_as_not_sent(self):
        def body(rig):
            refused = rig.run(REVIEW)
            blocked = rig.run(REVIEW)
            sent = rig.run(["resolve", "--request", "review.json", "--sent"])
            released = rig.run(["resolve", "--request", "review.json", "--not-sent"])
            shown = rig.run(["state", "--request", "review.json"])
            again = rig.run(REVIEW)
            return [refused, blocked, sent, released, shown, again]

        native = self.scenario(
            "session-review-refused",
            review_fields(
                [
                    CAPS,
                    LIST,
                    CAPS,
                    answer(
                        "create_thread",
                        {
                            "outcome": "model_mismatch",
                            "threadId": "r1",
                            "expected": {"model": "gpt-6.1-sol", "effort": "medium"},
                            "actual": {"model": "other", "effort": "medium"},
                        },
                    ),
                    CAPS,
                    LIST,
                    CAPS,
                    answer(
                        "create_thread",
                        {"outcome": "done", "threadId": "r2", "model": "gpt-6.1-sol", "effort": "medium"},
                    ),
                ]
            ),
            body,
        )
        steps = native["result"]
        self.assertEqual([1, 1, 1, 0, 0, 0], codes(steps))
        self.assertIn("a refused first turn never ran; use --not-sent", steps[2]["stderr"])
        self.assertMatches(steps[4]["stdout"], {"refusedThreadIds": ["r1"]})

    def test_refuse_a_second_run_while_the_first_is_sending_and_keep_its_record_when_that_run_dies(self):
        def body(rig):
            first = rig.start(LAUNCH)
            wait_for(
                lambda: any('"create_thread"' in line for line in rig.requests()),
                "the first run to send",
            )
            before_second = time.monotonic()
            second = rig.run(LAUNCH)
            second_took = int((time.monotonic() - before_second) * 1000)
            # The run dies without an answer, so nothing releases its record.
            first.kill()
            first.ended()
            third = rig.run(LAUNCH)
            released = rig.run(["resolve", "--request", "launch.json", "--not-sent"])
            fourth = rig.run(LAUNCH)
            return {"steps": [second, third, released, fourth], "secondTook": second_took}

        def steps_only(seen):
            return {**seen, "result": {"steps": seen["result"]["steps"]}}

        # The bridge holds the first create, so that run is still sending.
        fields = launch_fields(
            [
                CAPS,
                {"match": {"tool": "create_thread"}, "answer": "silent"},
                CAPS,
                answer("create_thread", {"outcome": "done", "threadId": "w2"}),
            ]
        )
        done = with_rig({"name": "session-launch-sending", **fields}, body)
        native = observed(done)
        self.assertSameJson(steps_only(recorded("session-launch-sending", done)), steps_only(native))
        steps = native["result"]["steps"]
        self.assertEqual([1, 1, 0, 0], codes(steps))
        self.assertIn("previous create_thread ended as sending; never resend", steps[0]["stderr"])
        # Busy is answered at once, not after a wait on the first run.
        self.assertLess(native["result"]["secondTook"], 5000)
        self.assertMatches(steps[3]["stdout"], {"threadId": "w2"})

    def test_send_once_when_runs_for_the_same_task_start_together(self):
        fields = {
            "name": "session-launch-race",
            # Each of the four runs may ask for the capabilities first, so each has an answer; the create is planned once.
            **launch_fields(
                [
                    CAPS,
                    CAPS,
                    CAPS,
                    CAPS,
                    answer(
                        "create_thread",
                        {"outcome": "done", "threadId": "w1", "model": "claude-sonnet-5-5", "effort": "high"},
                    ),
                ]
            ),
        }
        for _ in range(5):
            done = with_rig(fields, lambda rig: [started.ended() for started in [rig.start(LAUNCH) for _ in range(4)]])
            created = [line for line in done.requests if '"create_thread"' in line]
            self.assertEqual(1, len(created))
            for ran in done.result:
                # A run is the one that sent, finds that worker, or is refused because another run is sending.
                self.assertTrue(
                    ran["code"] == 0
                    or any(
                        phrase in ran["stderr"]
                        for phrase in (
                            "another harnexus-crew run is sending",
                            "previous create_thread ended as sending",
                            "changed the state",
                        )
                    ),
                    ran["stderr"],
                )
            self.assertTrue(any(ran["code"] == 0 for ran in done.result))
            kept = [(path, content) for path, content in done.files.items() if path.endswith("/state.json")]
            self.assertEqual(1, len(kept))
            self.assertMatches(jsonvalue.loads(kept[0][1]), {"threadId": "w1"})
            self.assertFalse(any(path.endswith("pending.json") for path in done.files))


LEGACY_FIXTURES = REPO / "test" / "fixtures" / "legacy-state" / "app"
RECORDED_ROOT = "/tmp/taskctl-legacy"
LEGACY_CHECKOUT = "{{root}}/app/codex/worktrees/ab12/checkout"


def place_legacy_state(rig):
    """Copies the state harnexus-task left in the app under the sandbox's, naming the review directory by the key of the sandbox's own checkout."""
    root = rig.sandbox.root
    state = Path(root) / "state"
    shutil.copytree(LEGACY_FIXTURES / "state", state, dirs_exist_ok=True)
    (state / "taskctl").rename(state / "harnexus-crew")
    for directory, _, names in os.walk(state):
        for name in names:
            if not name.endswith(".json"):
                continue
            path = Path(directory) / name
            text = path.read_text(encoding="utf-8")
            path.write_text(
                text.replace("@ROOT@", root).replace("@SKILLS@", str(REPO / "test" / "fixtures" / "task-skills")),
                encoding="utf-8",
            )
    recorded_key = f"{RECORDED_ROOT}/app/codex/worktrees/ab12/checkout\nw1"
    if key_directory(recorded_key) != "d6efc365839bb319":
        raise AssertionError("the recorded review key no longer matches the SHA-256 layout")
    source = state / "harnexus-crew" / "review" / "d6efc365839bb319"
    target = state / "harnexus-crew" / "review" / key_directory(f"{rig.sandbox.expand(LEGACY_CHECKOUT)}\nw1")
    target.parent.mkdir(parents=True, exist_ok=True)
    source.rename(target)


def legacy_fields():
    checkout = LEGACY_CHECKOUT
    return {
        "env": {**ENV, "CODEX_HOME": "{{root}}/app/codex"},
        "seed": SKILLS,
        "git": [
            ["init", "-q", checkout],
            ["-C", checkout, "commit", "--allow-empty", "-qm", "test: initial"],
            ["-C", checkout, "branch", "base"],
            ["-C", checkout, "commit", "--allow-empty", "-qm", "test: candidate 1"],
            ["-C", checkout, "commit", "--allow-empty", "-qm", "test: candidate 2"],
        ],
        "bridge": [CAPS, answer("send_message_to_thread", {"outcome": "done", "threadId": "r1"})],
        "files": {
            **CONFIG,
            "work/launch.json": jsonvalue.dumps(LAUNCH_REQUEST),
            "work/review.json": jsonvalue.dumps({**REVIEW_REQUEST, "checkout": checkout}),
        },
    }


class LegacyAppState(ScenarioAsserts, unittest.TestCase):
    """The state harnexus-task left in the app, moved to where this build keeps it and continued."""

    def scenario(self, name, body):
        done = with_rig({"name": name, **legacy_fields()}, body)
        native = observed(done)
        self.assertSameJson(recorded(name, done), native)
        return native

    def test_keep_the_launched_worker_and_its_reviewer_resolving_the_re_review_whose_answer_was_lost(self):
        def body(rig):
            place_legacy_state(rig)
            launched = rig.run(LAUNCH)
            held = rig.run(REVIEW)
            resolved = rig.run(["resolve", "--request", "review.json", "--sent"])
            candidate(rig, "test: candidate 3", LEGACY_CHECKOUT)
            resent = rig.run(REVIEW)
            shown = rig.run(["state", "--request", "review.json"])
            return [launched, held, resolved, resent, shown]

        native = self.scenario("session-legacy-app-resent", body)
        steps = native["result"]
        self.assertMatches(steps[0]["stdout"], {"existing": "w1"})
        self.assertEqual(1, steps[1]["code"])
        self.assertIn("previous send_message_to_thread ended as unknown; never resend", steps[1]["stderr"])
        self.assertMatches(steps[2]["stdout"], {"tool": "send_message_to_thread", "threadId": "r1"})
        self.assertEqual(0, steps[3]["code"])
        self.assertMatches(
            steps[4]["stdout"],
            {
                "reviewerThreadId": "r1",
                "workerThreadId": "w1",
                "base": BASE,
                "pending": None,
                "requested": {"model": "gpt-6.1-sol", "effort": "medium"},
            },
        )
        self.assertEqual(2, len(native["requests"]))
        self.assertIn(f"{BASE}...", jsonvalue.dumps(native["requests"][1]))

    def test_send_the_lost_head_again_to_the_same_reviewer_once_it_is_resolved_as_not_sent(self):
        def body(rig):
            place_legacy_state(rig)
            released = rig.run(["resolve", "--request", "review.json", "--not-sent"])
            resent = rig.run(REVIEW)
            return [released, resent]

        native = self.scenario("session-legacy-app-not-sent", body)
        steps = native["result"]
        self.assertMatches(steps[1]["stdout"], {"threadId": "r1"})
        self.assertIn(f"{BASE}...{HEAD_2}", jsonvalue.dumps(native["requests"][1]))


if __name__ == "__main__":
    unittest.main()

"""The session commands (launch, review, state, resolve, name) run as processes against a stand-in bridge."""

import time
import unittest

from harness import jsonvalue
from harness.asserts import ScenarioAsserts
from harness.rig import candidate_repository, codes, observed, read_recorded, wait_for, with_rig


class SessionCommands(ScenarioAsserts, unittest.TestCase):
    def test_launch_keeps_one_worker_per_task_and_name_titles_and_watches_its_pull_request(self):
        native = self.run_scenario(
            "session-launch-flow",
            {
                **launch_fields(
                    [
                        answer(
                            "create_thread",
                            {"outcome": "done", "threadId": "w1", "model": "claude-sonnet-5-5", "effort": "high"},
                        ),
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

    def test_launch_is_held_after_a_lost_answer_until_the_user_settles_it(self):
        native = self.run_scenario(
            "session-launch-lost",
            launch_fields([answer("create_thread", {"outcome": "unknown", "error": "timed out"})]),
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
        self.assertEqual(1, len(native["requests"]))
        recorded_state = sorted(path.rsplit("/", 1)[-1] for path in native["files"] if path.startswith("state/"))
        self.assertEqual(["state.json"], recorded_state)

    def test_launch_creates_a_new_worker_once_a_lost_launch_is_resolved_as_not_sent(self):
        native = self.run_scenario(
            "session-launch-not-sent",
            launch_fields(
                [
                    answer("create_thread", {"outcome": "unknown", "error": "lost"}),
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

    def test_review_sends_each_head_once_sends_a_new_head_to_the_same_reviewer_and_state_shows_it(self):
        def body(rig):
            first = rig.run(REVIEW)
            again = rig.run(REVIEW)
            rig.commit("test: candidate 2", REPO_PATH)
            second = rig.run(REVIEW)
            shown = rig.run(["state", "--request", "review.json"])

            return [first, again, second, shown]

        native = self.run_scenario(
            "session-review-flow",
            review_fields(
                [
                    LIST,
                    answer(
                        "create_thread",
                        {"outcome": "done", "threadId": "r1", "model": "gpt-6.1-sol", "effort": "medium"},
                    ),
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

    def test_review_refuses_a_changed_base_branch_until_the_base_is_updated(self):
        def body(rig):
            rig.run(REVIEW)
            rig.run_git("-C", rig.sandbox.expand(REPO_PATH), "branch", "other")
            rig.commit("test: candidate 2", REPO_PATH)
            rig.write_work("review.json", jsonvalue.dumps({**REVIEW_REQUEST, "baseBranch": "other"}))
            refused = rig.run(REVIEW)
            updated = rig.run([*REVIEW, "--update-base"])

            return [refused, updated]

        native = self.run_scenario(
            "session-review-base",
            review_fields(
                [
                    LIST,
                    answer("create_thread", {"outcome": "done", "threadId": "r1"}),
                    answer("send_message_to_thread", {"outcome": "done", "threadId": "r1"}),
                ]
            ),
            body,
        )
        steps = native["result"]

        self.assertIn("baseBranch changed; use --update-base after integrating upstream", steps[0]["stderr"])
        self.assertEqual(0, steps[1]["code"])

    def test_review_is_held_after_a_lost_answer_and_sends_the_head_again_once_it_is_settled(self):
        def body(rig):
            lost = rig.run(REVIEW)
            rig.commit("test: candidate 2", REPO_PATH)
            blocked = rig.run(REVIEW)
            resolved = rig.run(["resolve", "--request", "review.json", "--sent"])
            rig.commit("test: candidate 3", REPO_PATH)
            resent = rig.run(REVIEW)

            return [lost, blocked, resolved, resent]

        native = self.run_scenario(
            "session-review-lost",
            review_fields(
                [
                    LIST,
                    answer(
                        "create_thread", {"outcome": "unknown", "threadId": "r1", "error": "timed out"}
                    ),
                    answer("send_message_to_thread", {"outcome": "done", "threadId": "r1"}),
                ]
            ),
            body,
        )
        steps = native["result"]

        self.assertEqual([1, 1, 0, 0], codes(steps))
        self.assertIn("previous create_thread ended as unknown; never resend", steps[1]["stderr"])
        self.assertMatches(steps[3]["stdout"], {"tool": "send_message_to_thread", "threadId": "r1"})

    def test_review_keeps_a_refused_first_turn_apart_until_it_is_resolved_as_not_sent(self):
        def body(rig):
            refused = rig.run(REVIEW)
            blocked = rig.run(REVIEW)
            sent = rig.run(["resolve", "--request", "review.json", "--sent"])
            released = rig.run(["resolve", "--request", "review.json", "--not-sent"])
            shown = rig.run(["state", "--request", "review.json"])
            again = rig.run(REVIEW)

            return [refused, blocked, sent, released, shown, again]

        native = self.run_scenario(
            "session-review-refused",
            review_fields(
                [
                    LIST,
                    answer(
                        "create_thread",
                        {
                            "outcome": "model_mismatch",
                            "threadId": "r1",
                            "expected": {"model": "gpt-6.1-sol", "effort": "medium"},
                            "actual": {"model": "other", "effort": "medium"},
                        },
                    ),
                    LIST,
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

    def test_launch_refuses_a_second_run_while_the_first_is_sending_and_keeps_its_record_when_that_run_dies(self):
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
            first.wait_for_end()
            third = rig.run(LAUNCH)
            released = rig.run(["resolve", "--request", "launch.json", "--not-sent"])
            fourth = rig.run(LAUNCH)

            return {"steps": [second, third, released, fourth], "secondTook": second_took}

        def steps_only(seen):
            return {**seen, "result": {"steps": seen["result"]["steps"]}}

        # The bridge holds the first create, so that run is still sending.
        fields = launch_fields(
            [
                {"match": {"tool": "create_thread"}, "answer": "silent"},
                answer("create_thread", {"outcome": "done", "threadId": "w2"}),
            ]
        )

        done = with_rig({"name": "session-launch-sending", **fields}, body)
        native = observed(done)

        self.assertSameJson(steps_only(read_recorded("session-launch-sending", done)), steps_only(native))
        steps = native["result"]["steps"]
        self.assertEqual([1, 1, 0, 0], codes(steps))
        self.assertIn("previous create_thread ended as sending; never resend", steps[0]["stderr"])
        # Busy is answered at once, not after a wait on the first run.
        self.assertLess(native["result"]["secondTook"], 5000)
        self.assertMatches(steps[3]["stdout"], {"threadId": "w2"})

    def test_launch_sends_once_when_runs_for_the_same_task_start_together(self):
        fields = {
            "name": "session-launch-race",
            **launch_fields(
                [
                    answer(
                        "create_thread",
                        {"outcome": "done", "threadId": "w1", "model": "claude-sonnet-5-5", "effort": "high"},
                    ),
                ]
            ),
        }

        for _ in range(5):
            done = with_rig(fields, lambda rig: [started.wait_for_end() for started in [rig.start(LAUNCH) for _ in range(4)]])

            created = [line for line in done.requests if '"create_thread"' in line]
            self.assertEqual(1, len(created), f"runs: {done.result!r}; requests: {done.requests!r}; files: {done.files!r}")

            # Every run either sent, found that worker, or was refused because another run was sending.
            unexplained = [
                ran["stderr"]
                for ran in done.result
                if ran["code"] != 0
                and not any(
                    phrase in ran["stderr"]
                    for phrase in (
                        "another harnexus-crew run is sending",
                        "previous create_thread ended as sending",
                        "changed the state",
                    )
                )
            ]

            self.assertEqual([], unexplained)
            self.assertIn(0, codes(done.result))

            kept = [(path, content) for path, content in done.files.items() if path.endswith("/state.json")]
            self.assertEqual(1, len(kept))
            self.assertMatches(jsonvalue.loads(kept[0][1]), {"threadId": "w1"})
            self.assertEqual([], [path for path in done.files if path.endswith("pending.json")])

    def run_scenario(self, name, fields, body, strip=lambda seen: seen):
        """Runs the scenario on the Native build and checks it against the recorded expectation."""
        done = with_rig({"name": name, **fields}, body)
        native = observed(done)
        self.assertSameJson(strip(read_recorded(name, done)), strip(native))

        return native


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


def answer(tool, reply):
    return {"match": {"tool": tool}, "answer": {"version": 1, **reply}}


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
REPOSITORY = candidate_repository(REPO_PATH)
LAUNCH = ["launch", "--request", "launch.json"]
REVIEW = ["review", "--request", "review.json"]


if __name__ == "__main__":
    unittest.main()

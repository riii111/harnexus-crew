"""Template filling: the cases of the TypeScript build's template tests, run against the Native build's filling through its probe."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from harness import jsonvalue
from harness.binaries import binary
from harness.cases import REPO

SKILLS = REPO / "test" / "fixtures" / "task-skills"

WORKER_FIELDS = {"task_id": "TR1", "document_refs": "- /docs/agreement.md", "completion_target": "draft_pr"}
REVIEWER_FIELDS = {
    "task_id": "TR1",
    "document_refs": "- /docs/agreement.md",
    "worker_ai": "Codex",
    "reply_to": "Codex",
    "worker_chat_id": "worker",
    "checkout": "/checkout",
    "pr_url": "null",
    "base": "1" * 40,
    "head": "2" * 40,
}
MISSING_LINK_AFTER = [
    ("a code span", "`[a](b.md)` then [c](missing.md)\n"),
    ("a lone backtick a CRLF blank line before another", "Type a ` to start.\r\n\r\n[c](missing.md)\r\n\r\nThen `x`.\r\n"),
    ("a lone backtick a heading before another", "Type a backtick: `\n# Instructions\n[c](missing.md)\nUse `x`.\n"),
    ("an escaped backtick", "Write \\` then [c](missing.md) and `x`.\n"),
]
REFUSED_LINKS = [
    ("a real path with a space", "[$s](spaced/SKILL.md)", "TR1", "whose path has a space, parenthesis, # or backslash"),
    ("a real path with #", "[$s](hashed/SKILL.md)", "TR1", "whose path has a space, parenthesis, # or backslash"),
    ("a target with a title", '[n](notes/task.md "notes")', "TR1", "without angle brackets, spaces or a title"),
    ("a target opening with escaped braces", "[n]({{task_id}}/task.md)", "TR1", "which is not a file"),
    ("a target opening with a full-width space", "[n](　notes/task.md)", "TR1", "without angle brackets, spaces or a title"),
    ("a target in angle brackets", "[n](<notes/task.md>)", "TR1", "without angle brackets, spaces or a title"),
    (
        "a field holding a path",
        "[n](notes/{task_id}.md)",
        "x/../../task",
        "{task_id} may hold only letters, digits, _ and - inside a link target",
    ),
    (
        "a field whose value would break the anchor",
        "[n](notes/task.md#{task_id})",
        "#42",
        "{task_id} may hold only letters, digits, _ and - inside a link target",
    ),
    ("a field that is not a request value", "[n](notes/{constructor}.md)", "TR1", "unknown template field {constructor}"),
]
REFUSED_CONFIGS = [
    ("a missing config", None, "harnexus/task.json does not exist; set templates.worker"),
    ("a config without the worker template", {"templates": {"reviewer": "/reviewer.md"}}, "templates.worker is not set in"),
    ("a relative template path", {"templates": {"worker": "worker.md"}}, "must be absolute"),
    ("an unknown config field", {"templates": {}, "prompts": {}}, "is invalid"),
    (
        "a missing template",
        {"templates": {"worker": "/nonexistent/worker.md"}},
        "the worker template /nonexistent/worker.md: cannot read /nonexistent/worker.md",
    ),
]


class Fixture:
    def __init__(self, test):
        self.root = Path(os.path.realpath(tempfile.mkdtemp(prefix="harnexus-templates-")))
        test.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.home = self.root / "config"

    def configure(self, config):
        if config is None:
            return
        (self.home / "harnexus").mkdir(parents=True, exist_ok=True)
        (self.home / "harnexus" / "task.json").write_text(json.dumps(config), encoding="utf-8")

    def use_worker(self, template):
        self.configure({"templates": {"worker": str(template)}})

    def prompt(self, kind, fields=None):
        """Returns (True, filled text) or (False, the refusal)."""
        fields = WORKER_FIELDS if fields is None else fields
        ran = subprocess.run(
            [
                binary("HARNEXUS_PROMPT_PROBE"),
                str(self.root),
                str(self.home),
                kind,
                *[f"{name}={value}" for name, value in fields.items()],
            ],
            capture_output=True,
        )
        if ran.returncode != 0:
            raise RuntimeError(f"probe exited {ran.returncode}: {ran.stderr.decode('utf-8', errors='replace')}")
        reply = jsonvalue.loads(ran.stdout.decode("utf-8"))
        if "prompt" in reply:
            return True, reply["prompt"]
        return False, reply.get("error", "")


class NativeTemplateFilling(unittest.TestCase):
    def test_links_the_reviewer_prompt_to_the_files_beside_its_template(self):
        fixture = Fixture(self)
        fixture.configure({"templates": {"reviewer": str(SKILLS / "task-review-cycle" / "references" / "reviewer.md")}})

        def real(path):
            return os.path.realpath(SKILLS / path)

        ok, text = fixture.prompt("reviewer", REVIEWER_FIELDS)

        self.assertTrue(ok, text)
        self.assertIn(f"[$ai-code-review]({real('ai-code-review/SKILL.md')})", text)
        self.assertIn(f"({real('task-review-cycle/SKILL.md')}#レビュー時の確認事項)", text)
        self.assertIn(f"[返却方法]({real('task-review-cycle/references/reply-Codex.md')})", text)

    def test_fills_a_template_of_its_own_without_resolving_links_in_the_values(self):
        fixture = Fixture(self)
        root = fixture.root
        linked = root / "linked.md"
        document = root / "a](linked.md)"
        escaped = root / "{task_id}.md"
        for path in (linked, escaped, document):
            path.write_text("", encoding="utf-8")
        template = root / "templates" / "worker.md"
        template.parent.mkdir()
        template.write_text(
            "{{task_id}} is {task_id}\n{document_refs}\n"
            "[guide](https://example.com/guide) [local](/nowhere.md) [top](#top) [linked](../linked.md) [escaped](../{{task_id}}.md)\n"
            "[ref][r]\n\n[r]: ../linked.md\n[注意]: 先に読むこと\n",
            encoding="utf-8",
        )
        fixture.use_worker(template)

        ok, text = fixture.prompt("worker", {**WORKER_FIELDS, "task_id": "manual/TR1", "document_refs": f"- {document}"})

        self.assertEqual(
            (
                True,
                f"{{task_id}} is manual/TR1\n- {document}\n"
                f"[guide](https://example.com/guide) [local](/nowhere.md) [top](#top) [linked]({linked}) [escaped]({escaped})\n"
                "[ref][r]\n\n[r]: ../linked.md\n[注意]: 先に読むこと\n",
            ),
            (ok, text),
        )

    def test_leaves_links_in_code_as_examples_and_resolves_the_link_after_them(self):
        fixture = Fixture(self)
        linked = fixture.root / "linked.md"
        linked.write_text("", encoding="utf-8")
        template = fixture.root / "worker.md"
        examples = (
            "Cite as `[file](path/to/file.ts)` or ``[a](b`c.md)``.\n"
            "```md\n[x](missing.md)\n```\n"
            "~~~\n[y](gone.md)\n```\nstill code [z](none.md)\n~~~\n"
            "1. Output format:\n\n    ~~~md\n    [file](path/to/file.ts)\n    ~~~\n\n"
            "> ```\n> [q](quoted.md)\n> ```\n\n"
        )
        template.write_text(
            f"{examples}<!--\n- [old](gone.md)\n\n# Old\n[x](gone.md)\n-->\nWrite `[text](` then <rules>\n[$s](linked.md)\n</rules>\n\n    ![i](linked.md)\n",
            encoding="utf-8",
        )
        fixture.use_worker(template)

        ok, text = fixture.prompt("worker")

        self.assertEqual(
            (
                True,
                f"{examples}<!--\n- [old](gone.md)\n\n# Old\n[x](gone.md)\n-->\nWrite `[text](` then <rules>\n[$s]({linked})\n</rules>\n\n    ![i]({linked})\n",
            ),
            (ok, text),
        )

    def test_refuses_a_missing_link_after_code_or_a_lone_backtick(self):
        for name, text in MISSING_LINK_AFTER:
            with self.subTest(name):
                fixture = Fixture(self)
                template = fixture.root / "worker.md"
                template.write_text(text, encoding="utf-8")
                fixture.use_worker(template)

                ok, message = fixture.prompt("worker")

                self.assertFalse(ok)
                self.assertIn(
                    f"the worker template {template}: links to {fixture.root / 'missing.md'}, which is not a file",
                    message,
                )

    def test_fills_anchors_and_field_led_targets_and_resolves_beside_a_symlinked_templates_real_file(self):
        fixture = Fixture(self)
        root = fixture.root
        source = root / "source"
        (source / "notes").mkdir(parents=True)
        (source / "notes" / "task.md").write_text("", encoding="utf-8")
        (source / "worker.md").write_text("[note](notes/task.md#{task_id}) [id]({task_id})\n", encoding="utf-8")
        (root / "linked").mkdir()
        template = root / "linked" / "worker.md"
        template.symlink_to(source / "worker.md")
        fixture.use_worker(template)

        ok, text = fixture.prompt("worker", {**WORKER_FIELDS, "task_id": "TR-42"})

        self.assertEqual((True, f"[note]({source / 'notes' / 'task.md'}#TR-42) [id](TR-42)\n"), (ok, text))

    def test_refuses_a_link_to_a_target_the_filling_cannot_trust(self):
        for name, link, task_id, error in REFUSED_LINKS:
            with self.subTest(name):
                fixture = Fixture(self)
                root = fixture.root
                (root / "notes").mkdir()
                (root / "notes" / "task.md").write_text("", encoding="utf-8")
                (root / "My Skills").mkdir()
                (root / "My Skills" / "SKILL.md").write_text("", encoding="utf-8")
                (root / "spaced").symlink_to(root / "My Skills")
                (root / "c#").mkdir()
                (root / "c#" / "SKILL.md").write_text("", encoding="utf-8")
                (root / "hashed").symlink_to(root / "c#")
                template = root / "worker.md"
                template.write_text(f"{link}\n", encoding="utf-8")
                fixture.use_worker(template)

                ok, message = fixture.prompt("worker", {**WORKER_FIELDS, "task_id": task_id})

                self.assertFalse(ok)
                self.assertIn(error, message)

    def test_refuses_a_config_it_cannot_use(self):
        for name, config, error in REFUSED_CONFIGS:
            with self.subTest(name):
                fixture = Fixture(self)
                fixture.configure(config)

                ok, message = fixture.prompt("worker")

                self.assertFalse(ok)
                self.assertIn(error, message)


if __name__ == "__main__":
    unittest.main()

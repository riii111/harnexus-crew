"""The Markdown link judgement as `Bun.markdown.render` makes it on a template with its link targets swapped for markers."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from harness import jsonvalue
from harness.binaries import require_binary
from harness.cases import REPO


class MarkdownLinkJudgement(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="harnexus-markdown-"))
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)

    def test_each_case_selects_the_links_the_recorded_judgement_selects(self):
        for item in JUDGEMENT["cases"]:
            with self.subTest(item["name"]):
                template = item["text"] if "text" in item else (REPO / item["file"]).read_text(encoding="utf-8")

                reply = self.judge(template)

                self.assertIn("selected", reply)
                selected = reply["selected"]
                self.assertEqual(item["selected"], [link["index"] for link in selected])
                self.assertEqual([item["candidates"][at] for at in item["selected"]], [link["raw"] for link in selected])

    def judge(self, template):
        path = self.directory / "template.md"
        path.write_bytes(jsonvalue.lossy_bytes(template))
        ran = subprocess.run([require_binary("HARNEXUS_MARKDOWN_PROBE"), str(path)], capture_output=True)
        if ran.returncode != 0:
            raise RuntimeError(f"probe exited {ran.returncode}: {ran.stderr.decode('utf-8', errors='replace')}")

        return jsonvalue.loads(ran.stdout.decode("utf-8"))


JUDGEMENT = jsonvalue.loads((REPO / "test" / "native" / "markdown-link-judgement.json").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()

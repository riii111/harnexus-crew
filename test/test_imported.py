"""The cases and stand-ins imported from the migration's trial are still in the repository."""

import unittest

from harness import jsonvalue
from harness.cases import REPO

NATIVE = REPO / "test" / "native"


class ImportedCases(unittest.TestCase):
    def test_the_boundary_cases_are_the_21_verified_cases_with_unique_ids(self):
        parsed = jsonvalue.loads((NATIVE / "boundary-cases.json").read_text(encoding="utf-8"))
        self.assertEqual(40, len(parsed["baseline"]))
        ids = [item["id"] for item in parsed["socket"]["cases"] + parsed["process"]["cases"]]
        self.assertEqual(21, len(ids))
        self.assertEqual(21, len(set(ids)))

    def test_the_stand_ins_are_in_the_repository(self):
        for name in ("socket_server.py", "child.sh", "noexec.sh", "badshebang.sh", "fake-cli.sh", "pr-wake.sh"):
            with self.subTest(name):
                self.assertTrue((NATIVE / "mocks" / name).is_file())

    def test_the_markdown_cases_name_files_that_exist(self):
        parsed = jsonvalue.loads((NATIVE / "markdown-link-judgement.json").read_text(encoding="utf-8"))
        for item in parsed["cases"]:
            self.assertTrue(all(at < len(item["candidates"]) for at in item["selected"]), item["name"])
            self.assertTrue("text" in item or "file" in item, item["name"])
            if "file" in item:
                self.assertTrue((REPO / item["file"]).is_file(), item["name"])


if __name__ == "__main__":
    unittest.main()

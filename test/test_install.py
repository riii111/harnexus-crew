"""scripts/install.sh builds a commit, checks the binary, and replaces the installed one only when everything held."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from harness.cases import REPO

SCRIPT = REPO / "scripts" / "install.sh"
BUILD_TIMEOUT_SECONDS = 600


def run(args, env=None):
    ran = subprocess.run(
        ["bash", str(SCRIPT), *args],
        env={
            "PATH": os.environ["PATH"],
            "HOME": os.environ.get("HOME", "/nonexistent"),
            "XDG_CONFIG_HOME": "/nonexistent/config",
            **(env or {}),
        },
        capture_output=True,
        timeout=BUILD_TIMEOUT_SECONDS,
    )
    return ran.returncode, ran.stdout.decode("utf-8", errors="replace"), ran.stderr.decode("utf-8", errors="replace")


def usage_line(program):
    ran = subprocess.run([program, "launch"], capture_output=True)
    return ran.stderr.decode("utf-8", errors="replace").split("\n")[-2]


def head():
    return subprocess.run(["git", "-C", str(REPO), "rev-parse", "HEAD"], capture_output=True, check=True).stdout.decode().strip()


class InstallScript(unittest.TestCase):
    def scratch(self):
        directory = Path(tempfile.mkdtemp(prefix="harnexus-crew-install-test-"))
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        return directory

    def test_is_valid_bash(self):
        self.assertEqual(0, subprocess.run(["bash", "-n", str(SCRIPT)]).returncode)

    def test_rejects_what_it_cannot_install_from(self):
        for name, args, message in (
            ("a relative prefix", ["--prefix", "bin"], "--prefix must be an absolute path"),
            ("a relative moon path", ["--prefix", "/tmp/x", "--moon", "./moon"], "--moon must be an absolute path"),
            ("a repository without a commit", ["--prefix", "/tmp/x", "--repo", str(REPO)], "--repo needs --rev"),
            ("an unknown option", ["--nope"], "usage:"),
        ):
            with self.subTest(name):
                status, _, stderr = run(args)

                self.assertEqual(2, status)
                self.assertIn(message, stderr)

    def test_installs_the_requested_commit_and_keeps_it_when_a_later_install_fails(self):
        prefix = self.scratch() / "bin"
        installed = run(["--prefix", str(prefix), "--repo", str(REPO), "--rev", head()])
        before = (prefix / "harnexus-crew").stat()
        failed = run(["--prefix", str(prefix), "--rev", "0000000"])
        after = (prefix / "harnexus-crew").stat()

        self.assertEqual((0, ""), (installed[0], installed[2]))
        self.assertIn(f"from {head()}", installed[1])
        self.assertEqual("harnexus-crew: --request is required", usage_line(str(prefix / "harnexus-crew")))
        self.assertEqual(1, failed[0])
        self.assertIn("commit 0000000 is not in", failed[2])
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_installs_to_a_prefix_that_does_not_exist_yet_and_the_binary_works(self):
        prefix = self.scratch() / "made" / "bin"

        status, stdout, stderr = run(["--prefix", str(prefix)])

        self.assertEqual((0, ""), (status, stderr))
        self.assertIn(f"installed {prefix}/harnexus-crew", stdout)
        ran = subprocess.run([str(prefix / "harnexus-crew"), "--help"], capture_output=True)
        self.assertEqual(0, ran.returncode)
        self.assertTrue(ran.stdout.decode().startswith("usage:\n"))
        self.assertEqual(0o755, (prefix / "harnexus-crew").stat().st_mode & 0o777)
        self.assertEqual(["harnexus-crew"], sorted(path.name for path in prefix.iterdir()))

    def test_keeps_the_installed_binary_when_the_build_fails(self):
        root = self.scratch()
        prefix = root / "bin"
        self.assertEqual(0, run(["--prefix", str(prefix)])[0])
        before = (prefix / "harnexus-crew").stat()
        broken = root / "moon"
        broken.write_text("#!/bin/sh\necho 'cannot build' >&2\nexit 1\n", encoding="utf-8")
        broken.chmod(0o755)

        status, _, stderr = run(["--prefix", str(prefix), "--moon", str(broken)])
        after = (prefix / "harnexus-crew").stat()

        self.assertEqual(1, status)
        self.assertIn("the build failed; nothing was replaced", stderr)
        self.assertIn("cannot build", stderr)
        self.assertEqual(before.st_ino, after.st_ino)
        self.assertEqual(["harnexus-crew"], sorted(path.name for path in prefix.iterdir()))

    def test_keeps_the_installed_binary_when_configured_templates_cannot_be_filled(self):
        root = self.scratch()
        prefix = root / "bin"
        installed = run(["--prefix", str(prefix)])
        before = (prefix / "harnexus-crew").stat()
        config = root / "config"
        (config / "harnexus").mkdir(parents=True)
        (root / "worker.md").write_text("[skill](missing/SKILL.md)\n", encoding="utf-8")
        (config / "harnexus" / "task.json").write_text(
            json.dumps({"templates": {"worker": str(root / "worker.md")}}), encoding="utf-8"
        )

        failed = run(["--prefix", str(prefix)], {"XDG_CONFIG_HOME": str(config)})
        after = (prefix / "harnexus-crew").stat()

        self.assertEqual(0, installed[0])
        self.assertEqual(1, failed[0])
        self.assertIn("cannot use the configured templates", failed[2])
        self.assertEqual(before.st_ino, after.st_ino)


if __name__ == "__main__":
    unittest.main()

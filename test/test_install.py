"""scripts/install.sh builds a commit, checks the binary, and replaces the installed one only when everything held."""

import functools
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from harness.cases import REPO

SCRIPT = REPO / "scripts" / "install.sh"
BUILD_TIMEOUT_SECONDS = 600
INSTALL_BUILD_ARGS = ["build", "cmd/main", "--target", "native", "--release"]


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


def read_usage_line(program):
    ran = subprocess.run([program, "launch"], capture_output=True)
    return ran.stderr.decode("utf-8", errors="replace").split("\n")[-2]


def read_head():
    return subprocess.run(["git", "-C", str(REPO), "rev-parse", "HEAD"], capture_output=True, check=True).stdout.decode().strip()


@functools.cache
def install_real_build():
    """The one real build of the committed HEAD, installed into a prefix that does not exist yet."""
    directory = Path(tempfile.mkdtemp(prefix="harnexus-crew-install-test-"))
    unittest.addModuleCleanup(shutil.rmtree, directory, ignore_errors=True)
    prefix = directory / "made" / "bin"
    return prefix, run(["--prefix", str(prefix), "--repo", str(REPO), "--rev", read_head()])


def write_moon_with_real_binary(directory):
    """A moon whose build result is the binary the real build made, so install.sh runs its own checks against a real harnexus-crew."""
    prefix, installed = install_real_build()
    binary = prefix / "harnexus-crew"
    if not binary.is_file():
        raise FileNotFoundError(f"the real build left no {binary}: {installed}")
    moon = directory / "moon"
    moon.write_text(
        "#!/bin/sh\n"
        "mkdir -p _build/native/release/build/cmd/main\n"
        f"cp {shlex.quote(str(binary))} _build/native/release/build/cmd/main/main.exe\n",
        encoding="utf-8",
    )
    moon.chmod(0o755)
    return moon


class InstallScript(unittest.TestCase):
    def make_scratch_directory(self):
        directory = Path(tempfile.mkdtemp(prefix="harnexus-crew-install-test-"))
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        return directory

    def install_the_real_binary(self, root):
        prefix = root / "bin"
        moon = write_moon_with_real_binary(root)
        installed = run(["--prefix", str(prefix), "--moon", str(moon)])
        self.assertEqual((0, ""), (installed[0], installed[2]))
        return prefix, moon

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

    def test_reports_the_installed_path_and_commit_when_the_prefix_does_not_exist_yet(self):
        prefix, (status, stdout, stderr) = install_real_build()

        self.assertEqual((0, ""), (status, stderr))
        self.assertIn(f"installed {prefix}/harnexus-crew from {read_head()}", stdout)

    def test_installs_a_binary_that_starts_into_a_prefix_that_does_not_exist_yet(self):
        prefix, _ = install_real_build()

        self.assertEqual("harnexus-crew: --request is required", read_usage_line(str(prefix / "harnexus-crew")))
        ran = subprocess.run([str(prefix / "harnexus-crew"), "--help"], capture_output=True)
        self.assertEqual(0, ran.returncode)
        self.assertEqual("usage:", ran.stdout.decode().split("\n")[0])

    def test_installs_the_binary_as_executable(self):
        prefix, _ = install_real_build()

        self.assertEqual(0o755, (prefix / "harnexus-crew").stat().st_mode & 0o777)

    def test_leaves_only_the_binary_in_the_prefix(self):
        prefix, _ = install_real_build()

        self.assertEqual(["harnexus-crew"], sorted(path.name for path in prefix.iterdir()))

    def test_keeps_the_installed_binary_when_the_requested_commit_is_missing(self):
        prefix, _ = self.install_the_real_binary(self.make_scratch_directory())
        before = (prefix / "harnexus-crew").stat()

        failed = run(["--prefix", str(prefix), "--rev", "0000000"])
        after = (prefix / "harnexus-crew").stat()

        self.assertEqual(1, failed[0])
        self.assertIn("commit 0000000 is not in", failed[2])
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_keeps_the_installed_binary_when_the_build_fails(self):
        prefix, before, _, failed = self.fail_to_build_over_an_installed_binary()

        after = (prefix / "harnexus-crew").stat()

        self.assertEqual(1, failed[0])
        self.assertEqual(before.st_ino, after.st_ino)

    def test_leaves_only_the_binary_in_the_prefix_when_the_build_fails(self):
        prefix, _, _, failed = self.fail_to_build_over_an_installed_binary()

        self.assertEqual(1, failed[0])
        self.assertEqual(["harnexus-crew"], sorted(path.name for path in prefix.iterdir()))

    def test_reports_the_build_output_when_the_build_fails(self):
        _, _, _, (status, _, stderr) = self.fail_to_build_over_an_installed_binary()

        self.assertEqual(1, status)
        self.assertIn("the build failed; nothing was replaced", stderr)
        self.assertIn("cannot build", stderr)

    def test_builds_the_command_with_the_install_arguments(self):
        _, _, asked, (status, _, _) = self.fail_to_build_over_an_installed_binary()

        self.assertEqual(1, status)
        self.assertEqual(" ".join(INSTALL_BUILD_ARGS), asked.read_text(encoding="utf-8").strip())

    def test_keeps_the_installed_binary_when_configured_templates_cannot_be_filled(self):
        root = self.make_scratch_directory()
        prefix, moon = self.install_the_real_binary(root)
        before = (prefix / "harnexus-crew").stat()
        config = root / "config"
        (config / "harnexus").mkdir(parents=True)
        (root / "worker.md").write_text("[skill](missing/SKILL.md)\n", encoding="utf-8")
        (config / "harnexus" / "task.json").write_text(
            json.dumps({"templates": {"worker": str(root / "worker.md")}}), encoding="utf-8"
        )

        failed = run(["--prefix", str(prefix), "--moon", str(moon)], {"XDG_CONFIG_HOME": str(config)})
        after = (prefix / "harnexus-crew").stat()

        self.assertEqual(1, failed[0])
        self.assertIn("cannot use the configured templates", failed[2])
        self.assertEqual(before.st_ino, after.st_ino)

    def fail_to_build_over_an_installed_binary(self):
        root = self.make_scratch_directory()
        prefix, _ = self.install_the_real_binary(root)
        before = (prefix / "harnexus-crew").stat()
        asked = root / "asked"
        broken = root / "broken-moon"
        broken.write_text(f"#!/bin/sh\necho \"$@\" >{shlex.quote(str(asked))}\necho 'cannot build' >&2\nexit 1\n", encoding="utf-8")
        broken.chmod(0o755)

        failed = run(["--prefix", str(prefix), "--moon", str(broken)])
        return prefix, before, asked, failed


if __name__ == "__main__":
    unittest.main()

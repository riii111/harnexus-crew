"""One run's own home, config, state and temporary directories, so two runs never share state."""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from . import jsonvalue
from .cases import REPO

SHIM = Path(__file__).with_name("shim.py")

# A repository made twice must have the same commits, so the author, committer and dates are fixed.
GIT_FIXED = {
    "GIT_AUTHOR_NAME": "Test",
    "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test",
    "GIT_COMMITTER_EMAIL": "test@example.com",
    "GIT_AUTHOR_DATE": "2026-11-01T00:00:00Z",
    "GIT_COMMITTER_DATE": "2026-11-01T00:00:00Z",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "1",
}


def run_git(root, argv):
    """Runs git for the sandbox's own setup, outside the CLI under test."""
    ran = subprocess.run(
        ["git", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main", *argv],
        cwd=root,
        env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), **GIT_FIXED},
        capture_output=True,
    )
    if ran.returncode != 0:
        raise RuntimeError(f"git {' '.join(argv)}: {ran.stderr.decode('utf-8', errors='replace')}")
    return ran.stdout.decode("utf-8", errors="replace").strip()


@dataclass
class Sandbox:
    root: str
    env: dict
    cwd: str
    bridge_socket: str
    dirs: dict

    def expand(self, text):
        replaced = text
        for name, value in (
            ("root", self.root),
            ("bridge", self.bridge_socket),
            ("home", self.dirs["home"]),
            ("config", self.dirs["config"]),
            ("state", self.dirs["state"]),
            ("tmp", self.dirs["tmp"]),
            ("work", self.dirs["work"]),
        ):
            replaced = replaced.replace("{{" + name + "}}", value)
        return replaced

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


def _make_empty_root(case):
    # The root is named by the case and this process, so a state key made from a path in the root is the same on every run of it.
    name = hashlib.sha1(case.name.encode("utf-8")).hexdigest()[:8]
    root = os.path.join(os.path.realpath(tempfile.gettempdir()), f"hxc-{name}-{os.getpid()}")
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(root)
    return root


def create_sandbox(case):
    root = _make_empty_root(case)
    dirs = {name: os.path.join(root, name) for name in ("home", "config", "state", "tmp", "work", "bin")}
    for path in dirs.values():
        os.makedirs(path, exist_ok=True)
    sandbox = Sandbox(
        root=root,
        env={},
        cwd=dirs["work"],
        bridge_socket=os.path.join(root, "bridge.sock"),
        dirs=dirs,
    )
    for target, source in case.seed.items():
        shutil.copytree(REPO / source, os.path.join(root, target), symlinks=True, dirs_exist_ok=True)
    for path, text in case.files.items():
        target = os.path.join(root, path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as written:
            written.write(jsonvalue.lossy_bytes(sandbox.expand(text)))
    for argv in case.git:
        run_git(root, [sandbox.expand(arg) for arg in argv])
    _write_shims(dirs["bin"], case)
    # The shims come first, so a command the CLI starts by name is the recorded one.
    sandbox.env = {
        "PATH": f"{dirs['bin']}:{os.path.dirname(sys.executable)}:/usr/bin:/bin",
        "HOME": dirs["home"],
        "XDG_CONFIG_HOME": dirs["config"],
        "XDG_STATE_HOME": dirs["state"],
        "TMPDIR": dirs["tmp"],
    }
    for key, value in case.env.items():
        sandbox.env[key] = sandbox.expand(value)
    return sandbox


def _write_shims(bin_dir, case):
    with open(os.path.join(bin_dir, "plan.json"), "w", encoding="utf-8") as plan:
        json.dump(case.commands, plan)
    for name in case.commands:
        path = os.path.join(bin_dir, name)
        with open(path, "w", encoding="utf-8") as script:
            script.write(f"#!/bin/sh\nexec '{sys.executable}' -I '{SHIM}' '{bin_dir}' '{name}' \"$@\"\n")
        os.chmod(path, 0o755)


def read_commands(root):
    try:
        with open(os.path.join(root, "records.jsonl"), encoding="utf-8") as records:
            text = records.read()
    except FileNotFoundError:
        return []
    return [json.loads(line) for line in text.split("\n") if line != ""]


def snapshot_files(root, dirs):
    """Regular files under the snapshot directories, by path relative to the root.
    Sockets and links are not state, and neither is what git keeps in .git, which differs between git versions.
    """
    files = {}

    def walk(relative):
        try:
            entries = list(os.scandir(os.path.join(root, relative)))
        except OSError:
            return
        for entry in entries:
            path = os.path.join(relative, entry.name)
            if entry.is_dir(follow_symlinks=False):
                if entry.name != ".git":
                    walk(path)
            elif entry.is_file(follow_symlinks=False):
                with open(os.path.join(root, path), encoding="utf-8", errors="replace", newline="") as read:
                    files[path] = read.read()

    for directory in dirs:
        walk(directory)
    return files

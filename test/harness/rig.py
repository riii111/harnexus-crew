"""A scenario's sandbox: a case's files, repositories, stand-in commands and bridge plan, with the CLI run by hand."""

import os
import re
import time
from contextlib import contextmanager
from dataclasses import dataclass, field

from . import expected, jsonvalue
from .binaries import require_binary
from .cases import REPO, make_case
from .execute import Running, RUN_TIMEOUT_SECONDS, start_bridge
from .normalize import ROOT_MARK
from .sandbox import create_sandbox, read_commands, run_git, snapshot_files


def parsed_or_text(text):
    parsed = jsonvalue.try_loads(text)
    return parsed[0] if parsed is not None else text


@dataclass
class Started:
    running: Running

    def kill(self):
        self.running.kill()

    def wait_for_end(self):
        code, _, stdout, stderr = self.running.end()
        return {"code": code, "stdout": stdout, "stderr": stderr}


@dataclass
class Rig:
    sandbox: object
    bridge: object
    cli: list = field(default_factory=list)
    timeout: float = RUN_TIMEOUT_SECONDS

    def start(self, argv):
        running = Running([*self.cli, *argv], self.sandbox, self.timeout)
        running.close_stdin()
        return Started(running)

    def run(self, argv):
        return self.start(argv).wait_for_end()

    def run_git(self, *argv):
        return run_git(self.sandbox.root, list(argv))

    def commit(self, message, repository):
        self.run_git("-C", self.sandbox.expand(repository), "commit", "--allow-empty", "-qm", message)

    def write_work(self, name, text):
        with open(os.path.join(self.sandbox.cwd, name), "wb") as written:
            written.write(jsonvalue.lossy_bytes(self.sandbox.expand(text)))

    def requests(self):
        return list(self.bridge.requests) if self.bridge else []


@dataclass
class Done:
    result: object
    root: str
    requests: list
    commands: list
    files: dict


@contextmanager
def _open_sandbox(fields):
    case = make_case(**fields)
    sandbox = create_sandbox(case)
    bridge = start_bridge(case, sandbox)
    try:
        yield case, sandbox, bridge
    finally:
        if bridge:
            bridge.stop()
        sandbox.cleanup()


def with_rig(fields, body, timeout=RUN_TIMEOUT_SECONDS):
    """Runs `body(rig)` in a fresh sandbox and returns what the scenario did."""
    with _open_sandbox(fields) as (case, sandbox, bridge):
        rig = Rig(sandbox, bridge, [require_binary("HARNEXUS_CREW_NATIVE")], timeout)
        result = body(rig)
        return Done(
            result=result,
            root=sandbox.root,
            requests=bridge.collect_finished_requests() if bridge else [],
            commands=read_commands(sandbox.root),
            files=snapshot_files(sandbox.root, case.snapshot),
        )


REPO_MARK = "<REPO>"


def _replace_root(node, root):
    """The sandbox root and the checkout this suite runs from are named alike, as neither is the same on every machine."""
    if isinstance(node, str):
        return node.replace(root, ROOT_MARK).replace(str(REPO), REPO_MARK)
    if isinstance(node, list):
        return [_replace_root(item, root) for item in node]
    if isinstance(node, dict):
        return {_replace_root(name, root): _replace_root(item, root) for name, item in node.items()}
    return node


def _parse_stdout_json(node, name=""):
    if isinstance(node, list):
        return [_parse_stdout_json(item, name) for item in node]
    if isinstance(node, dict):
        return {key: _parse_stdout_json(item, key) for key, item in node.items()}
    if isinstance(node, str) and name == "stdout":
        return parsed_or_text(node)
    return node


_TIME = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z", re.ASCII)
_PID = re.compile(r"\(pid \d+\)", re.ASCII)


def _mask_time_and_pid(node):
    """Times and process IDs differ from run to run, and nothing else is replaced."""
    if isinstance(node, str):
        return _PID.sub("(pid <PID>)", _TIME.sub("<TIME>", node))
    if isinstance(node, list):
        return [_mask_time_and_pid(item) for item in node]
    if isinstance(node, dict):
        return {_mask_time_and_pid(name): _mask_time_and_pid(item) for name, item in node.items()}
    return node


def observed(done, steady=False):
    """What a scenario did, with the root named alike and JSON read as JSON, so two builds compare by meaning."""
    plain = _replace_root(
        {
            "result": done.result,
            "requests": done.requests,
            "commands": done.commands,
            "files": done.files,
        },
        done.root,
    )
    if steady:
        plain = _mask_time_and_pid(plain)
    return {
        "result": _parse_stdout_json(plain["result"]),
        "requests": [parsed_or_text(line) for line in plain["requests"]],
        "commands": plain["commands"],
        "files": {
            path: parsed_or_text(content) if path.endswith(".json") else content
            for path, content in plain["files"].items()
        },
    }


def read_recorded(name, done):
    """The expectation recorded for scenario `name`, with its state keys made from this run's root."""
    return expected.load_expanded("scenarios", name, done.root)


def wait_for(ready, what):
    started = time.monotonic()
    while not ready():
        if time.monotonic() - started > RUN_TIMEOUT_SECONDS:
            raise TimeoutError(f"timed out waiting for {what}")
        time.sleep(0.005)


def codes(steps):
    return [step["code"] for step in steps]


def candidate_repository(path):
    """The git commands that make a repository with a `base` branch and one commit past it."""
    return [
        ["init", "-q", path],
        ["-C", path, "commit", "--allow-empty", "-qm", "test: initial"],
        ["-C", path, "branch", "base"],
        ["-C", path, "commit", "--allow-empty", "-qm", "test: candidate 1"],
    ]

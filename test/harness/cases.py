"""Acceptance cases: each file in test/cases describes one run of the CLI and, under test/expected, what it must do."""

import json
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CASES = REPO / "test" / "cases"

KINDS = ("command", "session")
MODES = ("json", "lines", "exact")
DEFAULT_SNAPSHOT = ["config", "state", "work", "home/.local", "home/.config"]


class InvalidCase(Exception):
    pass


@dataclass
class Case:
    name: str
    kind: str
    argv: list
    env: dict = field(default_factory=dict)
    stdin: str = ""
    steps: list = field(default_factory=list)
    files: dict = field(default_factory=dict)
    seed: dict = field(default_factory=dict)
    git: list = field(default_factory=list)
    bridge: list | None = None
    commands: dict = field(default_factory=dict)
    snapshot: list = field(default_factory=lambda: list(DEFAULT_SNAPSHOT))
    compare: dict = field(default_factory=dict)


def _check(condition, name, message):
    if not condition:
        raise InvalidCase(f"{name}: {message}")


def _strings(value):
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


def _string_map(value):
    return isinstance(value, dict) and all(isinstance(item, str) for item in value.values())


def parse_case(data):
    """Refuses an unknown member or a wrong type."""
    _check(isinstance(data, dict), "case", "must be an object")
    name = data.get("name")
    _check(isinstance(name, str) and name != "", "case", "name must be a non-empty string")
    allowed = {
        "name", "kind", "argv", "env", "stdin", "steps", "files", "seed",
        "git", "bridge", "commands", "snapshot", "compare",
    }
    _check(set(data) <= allowed, name, f"unknown members {sorted(set(data) - allowed)}")
    _check(data.get("kind") in KINDS, name, "kind is unknown")
    _check(_strings(data.get("argv")), name, "argv must be strings")
    _check(_string_map(data.get("env", {})), name, "env must map strings")
    _check(isinstance(data.get("stdin", ""), str), name, "stdin must be a string")
    for step in data.get("steps", []):
        _check(
            (set(step) == {"send"} and isinstance(step["send"], str))
            or (set(step) == {"wait"} and isinstance(step["wait"], int) and step["wait"] > 0),
            name,
            "a step is send or wait",
        )
    _check(_string_map(data.get("files", {})), name, "files must map strings")
    _check(_string_map(data.get("seed", {})), name, "seed must map strings")
    _check(
        isinstance(data.get("git", []), list) and all(_strings(item) for item in data.get("git", [])),
        name,
        "git must be lists of strings",
    )
    for step in data.get("bridge") or []:
        _check(set(step) <= {"match", "answer"} and "answer" in step, name, "a bridge step has match and answer")
        _check(
            isinstance(step["answer"], dict) or step["answer"] in ("drop", "silent"),
            name,
            "a bridge answer is an object, drop or silent",
        )
    for command in data.get("commands", {}).values():
        _check(set(command) <= {"stdout", "stderr", "exit"}, name, "a command has stdout, stderr and exit")
    _check(_strings(data.get("snapshot", [])), name, "snapshot must be strings")
    compare = data.get("compare", {})
    _check(set(compare) <= {"stdout", "stderr"} and set(compare.values()) <= set(MODES), name, "compare is invalid")
    return Case(
        name=name,
        kind=data["kind"],
        argv=data["argv"],
        env=data.get("env", {}),
        stdin=data.get("stdin", ""),
        steps=data.get("steps", []),
        files=data.get("files", {}),
        seed=data.get("seed", {}),
        git=data.get("git", []),
        bridge=data.get("bridge"),
        commands=data.get("commands", {}),
        snapshot=data.get("snapshot", list(DEFAULT_SNAPSHOT)),
        compare=compare,
    )


def make_case(**fields):
    """A case built in code, such as a scenario's: it is checked like one read from a file."""
    base = {"kind": "command", "argv": []}
    return parse_case({**base, **fields})


def load_cases():
    cases = []
    for path in sorted(CASES.glob("*.json")):
        case = parse_case(json.loads(path.read_text(encoding="utf-8")))
        if f"{case.name}.json" != path.name:
            raise InvalidCase(f"{path.name} must be named after its case, {case.name}")
        cases.append(case)
    return cases

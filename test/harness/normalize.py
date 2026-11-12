"""Replacements applied to what a run did, so values that differ on every run compare equal without hiding a repeated request or a lost result."""

import re

ROOT_MARK = "<ROOT>"


def _replace_in(case, scope, text):
    for rule in case.normalize:
        if scope in rule["scopes"]:
            replacement = rule["with"]
            text = re.sub(rule["pattern"], lambda _match: replacement, text, flags=re.ASCII)
    return text


def normalize(observation, case, root):
    """Replaces text inside values only: nothing is dropped, merged or reordered, and file paths keep their state keys."""

    def text(scope, value):
        return _replace_in(case, scope, value.replace(root, ROOT_MARK))

    return {
        "exitCode": observation["exitCode"],
        "signal": observation["signal"],
        "stdout": text("stdout", observation["stdout"]),
        "stderr": text("stderr", observation["stderr"]),
        "requests": [text("requests", line) for line in observation["requests"]],
        "commands": [
            {
                "name": command["name"],
                "argv": [text("commands", arg) for arg in command["argv"]],
                "stdin": text("commands", command["stdin"]),
            }
            for command in observation["commands"]
        ],
        "files": {path: text("files", content) for path, content in observation["files"].items()},
    }

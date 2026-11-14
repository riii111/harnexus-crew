"""What a case must do, as recorded from the TypeScript build this CLI replaced (see test/README.md).

A state key made from a path in the sandbox differs on every run, so the recording names the text a key was made from and a token stands where the key was.
`{{key:N}}` becomes the SHA-256 of keys[N].text, cut to keys[N].length, with <ROOT> read as this run's sandbox root.
"""

import hashlib
import json
import re
from pathlib import Path

from . import jsonvalue
from .cases import REPO
from .normalize import ROOT_MARK

EXPECTED = REPO / "test" / "expected"
_TOKEN = re.compile(r"\{\{key:(\d+)\}\}")


def key_digest(key, root):
    text = key["text"].replace(ROOT_MARK, root)
    return hashlib.sha256(jsonvalue.lossy_bytes(text)).hexdigest()[: key["length"]]


def expand_keys(value, keys, root):
    """Replaces the tokens in every string of `value`, member names included."""
    digests = [key_digest(key, root) for key in keys]

    def text(node):
        return _TOKEN.sub(lambda match: digests[int(match.group(1))], node)

    def walk(node):
        if isinstance(node, str):
            return text(node)
        if isinstance(node, list):
            return [walk(item) for item in node]
        if isinstance(node, dict):
            return {text(name): walk(item) for name, item in node.items()}
        return node

    return walk(value)


def load(group, name):
    path: Path = EXPECTED / group / f"{name}.json"
    return json.loads(path.read_text(encoding="utf-8"))


def load_expanded(group, name, root):
    recorded = load(group, name)
    keys = recorded.pop("keys")
    return expand_keys(recorded, keys, root)

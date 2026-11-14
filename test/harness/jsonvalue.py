"""JSON helpers that follow JavaScript's reading of JSON, which the recorded expectations were taken under."""

import json
import re


def loads(text):
    return json.loads(text)


def try_loads(text):
    """The parsed value wrapped in a one-item tuple, or None when the text is not JSON."""
    try:
        return (json.loads(text),)
    except ValueError:
        return None


_LONE_SURROGATE = re.compile("[\ud800-\udfff]")


def dumps(value):
    """Compact JSON like JSON.stringify: non-ASCII text stays as written and a lone surrogate is escaped."""
    text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return _LONE_SURROGATE.sub(lambda match: "\\u%04x" % ord(match.group()), text)


def same(expected, actual):
    """Equality by meaning: object member order is ignored, and a boolean never equals a number."""
    if isinstance(expected, bool) or isinstance(actual, bool):
        return isinstance(expected, bool) and isinstance(actual, bool) and expected == actual
    if isinstance(expected, (int, float)) and isinstance(actual, (int, float)):
        return float(expected) == float(actual)
    if isinstance(expected, dict) and isinstance(actual, dict):
        return expected.keys() == actual.keys() and all(same(expected[key], actual[key]) for key in expected)
    if isinstance(expected, list) and isinstance(actual, list):
        return len(expected) == len(actual) and all(same(a, b) for a, b in zip(expected, actual))
    return type(expected) is type(actual) and expected == actual


def same_text(expected, actual):
    """JSON text compares by meaning; text that is not JSON on both sides compares as written."""
    left = try_loads(expected)
    right = try_loads(actual)
    if left is not None and right is not None:
        return same(left[0], right[0])
    return expected == actual


def lossy_bytes(text):
    """The UTF-8 bytes JavaScript writes for a string: a lone surrogate becomes U+FFFD."""
    return text.encode("utf-16", "surrogatepass").decode("utf-16", "replace").encode("utf-8")

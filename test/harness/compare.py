"""The differences between what was expected and what a run did."""

from . import jsonvalue

DEFAULT_MODES = {
    "command": {"stdout": "json", "stderr": "exact"},
    "session": {"stdout": "lines", "stderr": "exact"},
}


def compare(case, expected, actual):
    """Empty when the two observations agree."""
    defaults = DEFAULT_MODES[case.kind]
    differences = []
    if expected["exitCode"] != actual["exitCode"]:
        differences.append(_difference("exitCode", expected["exitCode"], actual["exitCode"]))
    if expected["signal"] != actual["signal"]:
        differences.append(_difference("signal", expected["signal"], actual["signal"]))
    differences += _text_differences(
        "stdout", case.compare.get("stdout", defaults["stdout"]), expected["stdout"], actual["stdout"]
    )
    differences += _text_differences(
        "stderr", case.compare.get("stderr", defaults["stderr"]), expected["stderr"], actual["stderr"]
    )
    differences += _list_differences("requests", expected["requests"], actual["requests"], jsonvalue.same_text)
    differences += _list_differences("commands", expected["commands"], actual["commands"], jsonvalue.same)
    differences += _file_differences(expected["files"], actual["files"])
    return differences


def _text_differences(field, mode, expected, actual):
    if mode == "exact":
        return [] if expected == actual else [_difference(field, expected, actual)]
    if mode == "json":
        return [] if jsonvalue.same_text(expected, actual) else [_difference(field, expected, actual)]
    # Lines keep their boundaries: two lines are never equal to one line holding both.
    left = expected.split("\n")
    right = actual.split("\n")
    differences = []
    if len(left) != len(right):
        differences.append(_difference(f"{field}.lines", len(left), len(right)))
    for at in range(min(len(left), len(right))):
        if not jsonvalue.same_text(left[at], right[at]):
            differences.append(_difference(f"{field}[{at}]", left[at], right[at]))
    return differences


def _list_differences(field, expected, actual, same):
    differences = []
    if len(expected) != len(actual):
        differences.append(_difference(f"{field}.count", len(expected), len(actual)))
    for at in range(min(len(expected), len(actual))):
        if not same(expected[at], actual[at]):
            differences.append(_difference(f"{field}[{at}]", expected[at], actual[at]))
    return differences


def _file_differences(expected, actual):
    differences = []
    for path in sorted(set(expected) | set(actual)):
        left = expected.get(path)
        right = actual.get(path)
        if left is None or right is None:
            same = False
        elif path.endswith(".json"):
            same = jsonvalue.same_text(left, right)
        else:
            same = left == right
        if not same:
            differences.append(_difference(f"files.{path}", left, right))
    return differences


def _difference(field, expected, actual):
    return {"field": field, "expected": expected, "actual": actual}

"""Assertions the scenario tests share."""

from . import jsonvalue


def matches(actual, subset):
    """True when `actual` holds everything in `subset`: objects by member, lists by position and length."""
    if isinstance(subset, dict):
        return isinstance(actual, dict) and all(
            key in actual and matches(actual[key], value) for key, value in subset.items()
        )
    if isinstance(subset, list):
        return (
            isinstance(actual, list)
            and len(actual) == len(subset)
            and all(matches(a, b) for a, b in zip(actual, subset))
        )
    return jsonvalue.same(subset, actual)


class ScenarioAsserts:
    """Mixed into a unittest.TestCase."""

    def assertSameJson(self, expected, actual):
        if not jsonvalue.same(expected, actual):
            self.assertEqual(expected, actual)

    def assertMatches(self, actual, subset):
        if not matches(actual, subset):
            self.assertEqual(subset, actual, "the value does not hold the expected members")

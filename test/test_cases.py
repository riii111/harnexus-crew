"""Every case in test/cases, run on the Native build and compared with the recorded expectation."""

import json
import unittest

from harness import expected
from harness.binaries import require_binary
from harness.cases import load_cases
from harness.compare import compare
from harness.execute import observe
from harness.normalize import normalize


class CasesOnNative(unittest.TestCase):
    pass


def _make_test(case):
    def run(self):
        observed, root = observe([require_binary("HARNEXUS_CREW_NATIVE")], case)
        differences = compare(
            case,
            expected.load_expanded("cases", case.name, root),
            normalize(observed, root),
        )

        self.assertEqual([], differences, json.dumps(differences, ensure_ascii=False, indent=1))

    return run


for _case in load_cases():
    setattr(CasesOnNative, "test_" + _case.name.replace("-", "_"), _make_test(_case))

if __name__ == "__main__":
    unittest.main()

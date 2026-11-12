"""The Native build's letter and number classes are those of the Bun the TypeScript build ran on.

The tables in native/text/unicode_tables.mbt were generated from that Bun's \\p{L} and \\p{N}.
test/native/unicode-classes.json holds a digest of what the generator produced, so an edit to a table shows here.
"""

import hashlib
import re
import unittest

from harness import jsonvalue
from harness.cases import REPO

TABLES = REPO / "native" / "text" / "unicode_tables.mbt"
CLASSES = jsonvalue.loads((REPO / "test" / "native" / "unicode-classes.json").read_text(encoding="utf-8"))


def table_of(source, name):
    body = re.search(rf"let {name} : FixedArray\[Int(?:32)?\] = \[([^\]]*)\]", source)
    return [int(item, 16) for item in re.findall(r"0x[0-9A-Fa-f]+", body.group(1))]


def summary(ranges):
    count = sum(ranges[at + 1] - ranges[at] + 1 for at in range(0, len(ranges), 2))
    return {
        "ranges": len(ranges) // 2,
        "codePoints": count,
        "sha256": hashlib.sha256(",".join(str(item) for item in ranges).encode("ascii")).hexdigest(),
    }


class UnicodeTables(unittest.TestCase):
    def test_the_tables_are_the_letter_and_number_classes_of_the_pinned_bun(self):
        source = TABLES.read_text(encoding="utf-8")
        self.assertEqual(CLASSES["letters"], summary(table_of(source, "letter_ranges")))
        self.assertEqual(CLASSES["numbers"], summary(table_of(source, "number_ranges")))


if __name__ == "__main__":
    unittest.main()

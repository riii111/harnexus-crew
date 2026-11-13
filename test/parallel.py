"""Runs the acceptance tests in several unittest processes at once and prints each process's report.

usage: python3 test/parallel.py [-j PROCESSES] [-k PATTERN]... [unittest options such as -v]
"""

import argparse
import os
import subprocess
import sys
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent


def test_ids(suite):
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            yield from test_ids(test)
        else:
            yield test.id()


def run_shard(ids, options):
    ran = subprocess.run(
        [sys.executable, "-m", "unittest", *options, *ids],
        cwd=HERE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return ran.returncode, ran.stdout.decode("utf-8", errors="replace")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-j", "--processes", type=int, default=3)
    parser.add_argument("-k", dest="patterns", action="append", default=[])
    args, options = parser.parse_known_args()
    os.chdir(HERE)
    loader = unittest.TestLoader()
    # The processes are handed test IDs, which unittest runs without applying -k, so the patterns are applied here, the way unittest reads them.
    if args.patterns:
        loader.testNamePatterns = [pattern if "*" in pattern else f"*{pattern}*" for pattern in args.patterns]
    ids = list(test_ids(loader.discover(".", top_level_dir=".")))
    if not ids:
        print("no tests matched")
        return 5
    # Tests of one module sit next to each other in discovery order, so dealing them out in turn spreads the slow modules over every process.
    shards = [ids[k :: args.processes] for k in range(args.processes) if ids[k :: args.processes]]
    with ThreadPoolExecutor(len(shards)) as pool:
        results = list(pool.map(lambda shard: run_shard(shard, options), shards))
    for number, (status, report) in enumerate(results, 1):
        print(f"--- process {number} of {len(results)} (exit {status})")
        print(report, end="" if report.endswith("\n") else "\n")
    failed = [number for number, (status, _) in enumerate(results, 1) if status != 0]
    print(f"{len(ids)} tests in {len(results)} processes: " + (f"process {', '.join(map(str, failed))} failed" if failed else "all passed"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

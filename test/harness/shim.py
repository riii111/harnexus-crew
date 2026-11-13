"""A stand-in for an external command: it records its name, arguments and stdin, then answers as the case planned.

usage: python3 -I shim.py BIN_DIR NAME [ARGUMENT...]

The stand-in reads stdin to its end, which every call path closes: the product closes it after writing or at once, and the harness closes the CLI's own stdin for a command that inherits it.
"""

import json
import os
import sys


def main():
    directory, name, *argv = sys.argv[1:]
    with open(os.path.join(directory, "plan.json"), encoding="utf-8") as plan_file:
        plan = json.load(plan_file).get(name, {})
    stdin = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    record = json.dumps({"name": name, "argv": argv, "stdin": stdin}, ensure_ascii=True)
    with open(os.path.join(directory, "..", "records.jsonl"), "a", encoding="utf-8") as records:
        records.write(record + "\n")
    sys.stdout.buffer.write(plan.get("stdout", "").encode("utf-8", errors="replace"))
    sys.stdout.flush()
    sys.stderr.buffer.write(plan.get("stderr", "").encode("utf-8", errors="replace"))
    sys.stderr.flush()
    sys.exit(plan.get("exit", 0))


main()

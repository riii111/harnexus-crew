"""A stand-in for an external command: it records its name, arguments and stdin, then answers as the case planned.

usage: python3 -I shim.py BIN_DIR NAME [ARGUMENT...]

A caller that never writes or closes the stand-in's stdin would hold it until the harness kills it, so stdin is taken once nothing has arrived for STDIN_IDLE_SECONDS.
"""

import json
import os
import select
import sys

STDIN_IDLE_SECONDS = 0.3


def read_stdin():
    chunks = []
    while True:
        ready, _, _ = select.select([0], [], [], STDIN_IDLE_SECONDS)
        if not ready:
            break
        chunk = os.read(0, 65536)
        if chunk == b"":
            break
        chunks.append(chunk)
    return b"".join(chunks).decode("utf-8", errors="replace")


def main():
    directory, name, *argv = sys.argv[1:]
    with open(os.path.join(directory, "plan.json"), encoding="utf-8") as plan_file:
        plan = json.load(plan_file).get(name, {})
    stdin = read_stdin()
    record = json.dumps({"name": name, "argv": argv, "stdin": stdin}, ensure_ascii=True)
    with open(os.path.join(directory, "..", "records.jsonl"), "a", encoding="utf-8") as records:
        records.write(record + "\n")
    sys.stdout.buffer.write(plan.get("stdout", "").encode("utf-8", errors="replace"))
    sys.stdout.flush()
    sys.stderr.buffer.write(plan.get("stderr", "").encode("utf-8", errors="replace"))
    sys.stderr.flush()
    sys.exit(plan.get("exit", 0))


main()

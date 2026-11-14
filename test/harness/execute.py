"""Runs the CLI on one case in a fresh sandbox and returns what it did, before any normalization."""

import os
import signal as signals
import subprocess
import threading
import time

from . import jsonvalue
from .bridge import Bridge
from .sandbox import create_sandbox, read_commands, snapshot_files

RUN_TIMEOUT_SECONDS = 30


class _Output:
    """Collects what a pipe carries on its own thread, so a full pipe never blocks the child."""

    def __init__(self, stream):
        self.chunks = []
        self.lines = 0
        self._lock = threading.Lock()
        self._thread = threading.Thread(target=self._pump, args=(stream,), daemon=True)
        self._thread.start()

    def _pump(self, stream):
        while True:
            chunk = stream.read1(65536)
            if chunk == b"":
                return
            with self._lock:
                self.chunks.append(chunk)
                self.lines += chunk.count(b"\n")

    def wait_lines(self, wanted, what):
        started = time.monotonic()
        while True:
            with self._lock:
                if self.lines >= wanted:
                    return
            if time.monotonic() - started > RUN_TIMEOUT_SECONDS:
                raise TimeoutError(f"timed out waiting for {what}")
            time.sleep(0.005)

    def finish(self):
        self._thread.join(RUN_TIMEOUT_SECONDS)
        return b"".join(self.chunks).decode("utf-8", errors="replace")


class Running:
    """A started CLI: its output is collected until it ends."""

    def __init__(self, argv, sandbox, timeout=RUN_TIMEOUT_SECONDS):
        self.process = subprocess.Popen(
            argv,
            cwd=sandbox.cwd,
            env=sandbox.env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        self.stdout = _Output(self.process.stdout)
        self.stderr = _Output(self.process.stderr)
        self.killed = False
        self._timer = threading.Timer(timeout, self.kill)
        self._timer.daemon = True
        self._timer.start()

    def write(self, text):
        try:
            self.process.stdin.write(jsonvalue.lossy_bytes(text))
            self.process.stdin.flush()
        except (BrokenPipeError, OSError):
            pass

    def close_stdin(self):
        try:
            self.process.stdin.close()
        except (BrokenPipeError, OSError):
            pass

    def kill(self):
        self.killed = True
        try:
            os.killpg(self.process.pid, signals.SIGKILL)
        except OSError:
            pass

    def end(self):
        """Waits for the CLI and for its output to reach the end, and returns (code, signal, stdout, stderr)."""
        self.process.wait()
        out = self.stdout.finish()
        err = self.stderr.finish()
        self._timer.cancel()
        for stream in (self.process.stdout, self.process.stderr, self.process.stdin):
            stream.close()
        returned = self.process.returncode
        if returned < 0:
            return None, signals.Signals(-returned).name, out, err
        return returned, None, out, err


def start_bridge(case, sandbox):
    if case.bridge is None:
        return None
    steps = jsonvalue.loads(sandbox.expand(jsonvalue.dumps(case.bridge)))
    return Bridge(sandbox.bridge_socket, steps)


def observe(argv, case):
    """Returns (observation, root) for the CLI started as `argv` plus the case's arguments."""
    sandbox = create_sandbox(case)
    bridge = start_bridge(case, sandbox)
    try:
        running = Running([*argv, *case.argv], sandbox)
        if case.kind == "session":
            for step in case.steps:
                if "send" in step:
                    running.write(sandbox.expand(step["send"]) + "\n")
                else:
                    running.stdout.wait_lines(step["wait"], f"{step['wait']} lines")
        else:
            running.write(case.stdin)
        running.close_stdin()
        code, signal, stdout, stderr = running.end()
        observation = {
            "exitCode": code,
            "signal": signal,
            "stdout": stdout,
            "stderr": stderr,
            "requests": bridge.collect_finished_requests() if bridge else [],
            "commands": read_commands(sandbox.root),
            "files": snapshot_files(sandbox.root, case.snapshot),
        }
        return observation, sandbox.root
    finally:
        if bridge:
            bridge.stop()
        sandbox.cleanup()

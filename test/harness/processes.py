"""Helpers for the processes the tests start."""

import subprocess


def make_dead_pid():
    """A process that has ended, whose ID no run is using."""
    finished = subprocess.Popen(["true"])
    finished.wait()
    return finished.pid

"""An interrupt that reaches only the CLI leaves no process of the command it was waiting for."""

import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from harness.binaries import require_binary
from harness.rig import wait_for


class InterruptTest(unittest.TestCase):
    def test_sigint_to_the_cli_alone_leaves_no_process_of_the_command_it_was_waiting_for(self):
        with tempfile.TemporaryDirectory() as root:
            pr_wake = os.path.join(root, "pr-wake")
            Path(pr_wake).write_text(PR_WAKE)
            os.chmod(pr_wake, 0o755)
            env = {
                "PATH": "/usr/bin:/bin",
                "HOME": root,
                "XDG_CONFIG_HOME": os.path.join(root, "config"),
                "XDG_STATE_HOME": os.path.join(root, "state"),
                "TMPDIR": root,
                "HARNEXUS_CREW_PR_WAKE": pr_wake,
                "PIDS": root,
            }

            cli = subprocess.Popen(
                [require_binary("HARNEXUS_CREW_NATIVE"), "watch", "--status"],
                cwd=root,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            leader = grandchild = None

            try:
                wait_for(
                    lambda: read_pid(os.path.join(root, "leader")) and read_pid(os.path.join(root, "grandchild")),
                    "the command to start its descendant",
                )

                leader = read_pid(os.path.join(root, "leader"))
                grandchild = read_pid(os.path.join(root, "grandchild"))
                self.assertEqual([True, True], [is_running(leader), is_running(grandchild)])

                os.kill(cli.pid, signal.SIGINT)
                cli.communicate(timeout=30)

                self.assertEqual(-signal.SIGINT, cli.returncode)
                survivors = [name for name, pid in (("command", leader), ("descendant", grandchild)) if not wait_until_gone(pid)]
                self.assertEqual([], survivors)
            finally:
                if cli.poll() is None:
                    cli.kill()

                cli.communicate()

                for pid in (leader, grandchild):
                    if pid:
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass


def read_pid(path):
    try:
        return int(Path(path).read_text().strip())
    except (FileNotFoundError, ValueError):
        return None


def wait_until_gone(pid):
    for _ in range(300):
        if not is_running(pid):
            return True

        time.sleep(0.01)

    return False


def is_running(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False

    return True


# A non-interactive shell makes a background job ignore SIGINT, so only the CLI's cleanup can end the sleeping grandchild.
PR_WAKE = """#!/bin/sh
echo $$ > "$PIDS/leader"
sleep 300 &
echo $! > "$PIDS/grandchild"
wait
"""


if __name__ == "__main__":
    unittest.main()

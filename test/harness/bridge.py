"""A stand-in for the harnexus bridge: it records every connection and answers from the plan, once per step."""

import json
import select
import socket
import threading
import time

from . import jsonvalue


class Bridge:
    def __init__(self, path, steps):
        self.path = path
        self.requests = []
        self._steps = steps
        self._used = set()
        self._held = []
        self._lock = threading.Lock()
        self._flush_lock = threading.Lock()
        self._flushed = threading.Event()
        self._handlers = []
        self._flush_handlers = []

        self._control_read, self._control_write = socket.socketpair()
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(path)
        self._server.listen(128)
        self._server.setblocking(False)

        self._thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._thread.start()

    def collect_finished_requests(self, timeout=30):
        """Collects all connections queued by finished clients before reading their requests."""

        with self._flush_lock:
            deadline = time.monotonic() + timeout
            self._flushed.clear()
            self._control_write.sendall(b"f")

            if not self._flushed.wait(max(0, deadline - time.monotonic())):
                raise TimeoutError("timed out waiting for the bridge to accept connections")

            for finished in self._flush_handlers:
                if not finished.wait(max(0, deadline - time.monotonic())):
                    raise TimeoutError("timed out waiting for the bridge to record a connection")

            with self._lock:
                return list(self.requests)

    def stop(self):
        self._control_write.sendall(b"s")
        self._thread.join()
        self._server.close()
        self._control_read.close()
        self._control_write.close()

        with self._lock:
            held, self._held = self._held, []

        for connection in held:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

            connection.close()

    def _accept_loop(self):
        while True:
            try:
                ready, _, _ = select.select([self._server, self._control_read], [], [])
                if self._server in ready:
                    self._accept_pending()

                if self._control_read in ready:
                    command = self._control_read.recv(1)
                    if command != b"f":
                        return

                    # The clients have finished before a flush is requested, so accept the connections already queued, including probes that sent no data.
                    self._accept_pending()
                    self._flush_handlers = list(self._handlers)
                    self._flushed.set()
            except OSError:
                return

    def _accept_pending(self):
        while True:
            try:
                connection, _ = self._server.accept()
            except BlockingIOError:
                return

            connection.setblocking(True)
            finished = threading.Event()
            self._handlers.append(finished)
            threading.Thread(target=self._serve, args=(connection, finished), daemon=True).start()

    def _serve(self, connection, finished):
        data = b""
        line = None

        try:
            while True:
                chunk = connection.recv(65536)
                if chunk == b"":
                    break

                data += chunk
                end = data.find(b"\n")
                if line is not None or end < 0:
                    continue

                line = data[:end].decode("utf-8", errors="replace")

                with self._lock:
                    self.requests.append(line)

                self._answer(connection, line)
        except OSError:
            pass
        finally:
            if line is None:
                with self._lock:
                    self.requests.append(data.decode("utf-8", errors="replace"))

            with self._lock:
                held = connection in self._held

            if not held:
                connection.close()

            finished.set()

    def _answer(self, connection, line):
        parsed = jsonvalue.try_loads(line)
        request = parsed[0] if parsed is not None else None

        with self._lock:
            chosen = None

            for at, step in enumerate(self._steps):
                if at not in self._used and ("match" not in step or _contains(request, step["match"])):
                    chosen = at
                    break

            if chosen is not None:
                self._used.add(chosen)

        if chosen is None:
            # An unplanned request is still recorded, and answered so that it shows as a difference rather than hanging.
            self._reply(connection, {"outcome": "invalid", "message": "unplanned request"})
            return

        answer = self._steps[chosen]["answer"]
        if answer == "drop":
            connection.close()
        elif answer == "silent":
            with self._lock:
                self._held.append(connection)
        else:
            self._reply(connection, answer)

    @staticmethod
    def _reply(connection, value):
        try:
            connection.sendall((jsonvalue.dumps(value) + "\n").encode("utf-8"))
        except OSError:
            pass

        connection.close()


def _contains(request, match):
    return isinstance(request, dict) and all(
        key in request and jsonvalue.same(request[key], value) for key, value in match.items()
    )

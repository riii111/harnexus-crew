"""A stand-in for the harnexus bridge: it records every connection and answers from the plan, once per step."""

import json
import socket
import threading

from . import jsonvalue


def _contains(request, match):
    return isinstance(request, dict) and all(
        key in request and jsonvalue.same(request[key], value) for key, value in match.items()
    )


class Bridge:
    def __init__(self, path, steps):
        self.path = path
        self.requests = []
        self._steps = steps
        self._used = set()
        self._held = []
        self._lock = threading.Lock()
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(path)
        self._server.listen(128)
        self._stopped = False
        self._thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._thread.start()

    def _accept_loop(self):
        while True:
            try:
                connection, _ = self._server.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(connection,), daemon=True).start()

    def _serve(self, connection):
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

    def stop(self):
        self._server.close()
        with self._lock:
            held, self._held = self._held, []
        for connection in held:
            connection.close()

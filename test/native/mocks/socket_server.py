# Mock bridge for deadline cases: backlog listens without accepting and fills its queue, noread accepts and never reads, drip answers in chunks slower in total than the deadline.
import os, socket, sys, time

path, mode = sys.argv[1], sys.argv[2]
chunks = int(sys.argv[3]) if len(sys.argv) > 3 else 5
gap = float(sys.argv[4]) if len(sys.argv) > 4 else 0.4
if os.path.exists(path):
    os.unlink(path)
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)

if mode == "backlog":
    server.listen(1)
    held = []
    first_error = None
    for _ in range(4096):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.setblocking(False)
        try:
            client.connect(path)
            held.append(client)
        except OSError as error:
            first_error = f"{error.errno} {os.strerror(error.errno)}"
            client.close()
            break
    print(f"listening {path} backlog queued={len(held)} next_connect={first_error}", flush=True)
    while True:
        time.sleep(3600)

server.listen(16)
if mode == "noread":
    # Accepts and never reads, so a large request fills the socket buffer and the client's write has to wait.
    print(f"listening {path} noread", flush=True)
    accepted = []
    while True:
        conn, _ = server.accept()
        accepted.append(conn)
        print(f"accepted {len(accepted)}", flush=True)

print(f"listening {path} {mode} chunks={chunks} gap={gap}", flush=True)
while True:
    conn, _ = server.accept()
    conn.recv(65536)
    started = time.monotonic()
    try:
        for index in range(chunks):
            time.sleep(gap)
            conn.sendall(f"part{index};".encode())
        conn.sendall(b"\n")
        print(f"drip finished {time.monotonic() - started:.3f}s", flush=True)
    except OSError as error:
        print(f"peer closed after {time.monotonic() - started:.3f}s: {error.errno}", flush=True)
    conn.close()

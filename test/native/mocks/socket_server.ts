// Mock bridge for the socket boundary: answer replies to the first line and closes, silent reads and never answers.
const [path, mode = "answer"] = Bun.argv.slice(2);
if (path === undefined) {
  process.stderr.write(
    "usage: bun socket_server.ts SOCKET_PATH [answer|silent]\n",
  );
  process.exit(2);
}

Bun.listen({
  unix: path,
  socket: {
    data(socket, data) {
      const line = data.toString().split("\n")[0] ?? "";
      if (mode === "silent") return;
      socket.end(
        `${JSON.stringify({ version: 1, outcome: "done", echoed: line, text: "あい🌙" })}\n`,
      );
    },
  },
});
process.stdout.write(`listening ${path} ${mode}\n`);

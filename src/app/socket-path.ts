import { dirname, isAbsolute, join } from "node:path";

import { Result } from "better-result";

const CALL_SOCKET_ENV = "HARNEXUS_CALL_SOCKET";
const STATE_PATH_ENV = "HARNEXUS_STATE_PATH";
const DEFAULT_STATE_PATH = ".local/state/harnexus/threads.json";

type Env = Record<string, string | undefined>;

type SocketSettingFailed = { message: string };

// Read as the harnexus bridge reads it, so a value the bridge refuses is refused here too.
const callSocketSetting = (
  env: Env,
): Result<
  { kind: "off" } | { kind: "default" } | { kind: "path"; path: string },
  SocketSettingFailed
> => {
  const value = env[CALL_SOCKET_ENV];
  if (value === undefined || value === "" || value === "on")
    return Result.ok({ kind: "default" });
  if (value === "off") return Result.ok({ kind: "off" });
  if (!isAbsolute(value))
    return Result.err({
      message: `${CALL_SOCKET_ENV} must be on, off or an absolute path`,
    });
  return Result.ok({ kind: "path", path: value });
};

export const harnexusStatePath = (
  env: Env,
  home: string,
): Result<string, SocketSettingFailed> => {
  const path = env[STATE_PATH_ENV];
  if (path === undefined || path === "")
    return Result.ok(join(home, DEFAULT_STATE_PATH));
  return isAbsolute(path)
    ? Result.ok(path)
    : Result.err({ message: `${STATE_PATH_ENV} must be an absolute path` });
};

// Where the bridge's call socket is, even when the setting turns it off, for a probe that only asks whether a bridge runs.
export const callSocketPath = (env: Env, home: string) =>
  Result.gen(function* () {
    const setting = yield* callSocketSetting(env);
    if (setting.kind === "path") return Result.ok(setting.path);
    const state = yield* harnexusStatePath(env, home);
    return Result.ok(join(dirname(state), "call.sock"));
  });

// Where a caller sends, or null when the socket is turned off, so a caller can say so instead of failing to connect.
export const callerSocket = (env: Env, home: string) =>
  callSocketSetting(env).andThen((setting) =>
    setting.kind === "off"
      ? Result.ok<string | null>(null)
      : callSocketPath(env, home),
  );

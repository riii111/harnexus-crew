import { parseJson } from "../lib/json.boundary.ts";
import { type Fields, isObject } from "../lib/object.ts";
import { requestLine } from "../lib/socket.boundary.ts";
import { callerSocket } from "./socket-path.ts";

// What harnexus call protocol 1 answers, plus unsupported: a bridge that does not offer the protocol or the tool, to which nothing was sent.
export type CallOutcome =
  | "done"
  // Never answered by protocol 1, which names what is known of a failed call; kept for a bridge that still does.
  | "tool_error"
  | "not_sent"
  | "rejected"
  | "invalid"
  | "unknown"
  | "model_mismatch"
  | "first_turn_refused"
  | "chat_not_opened"
  | "unsupported";

export const PROTOCOL_VERSION = 1;

// Longer than the longest wait_threads the bridge allows, so the bridge always answers first.
const ANSWER_TIMEOUT_MS = 15 * 60_000;
const QUERY_TIMEOUT_MS = 10_000;

export type CallDeps = {
  env: Record<string, string | undefined>;
  home: string;
  timeoutMs?: number;
};

const SOCKET_HINT =
  "open the app with HARNEXUS_CALL_SOCKET=on (for example `HARNEXUS_CALL_SOCKET=on bun run open-app` in the harnexus checkout) and run outside the sandbox";

const socketHint = (code: string | null) => {
  switch (code) {
    case "ENOENT":
      return `no bridge has opened the socket; ${SOCKET_HINT}`;
    case "ECONNREFUSED":
      return "a bridge that has exited left the socket; the running bridge takes it over within seconds, so run again, and reopen the app if it persists";
    case "EPERM":
    case "EACCES":
      return "the sandbox blocked the connection; run outside the sandbox";
    default:
      return SOCKET_HINT;
  }
};

// Asks the bridge for protocol 1 and sends the call only once the bridge offers the tool, so an older bridge never receives a write.
// An older bridge answers the query as invalid, which is taken as unsupported; the first protocol is never tried instead.
export const callApp = async (
  deps: CallDeps,
  caller: string,
  tool: string,
  args: Fields,
): Promise<Fields> => {
  const socket = callerSocket(deps.env, deps.home);
  if (socket.isErr())
    return { outcome: "not_sent", error: socket.error.message };
  if (socket.value === null)
    return {
      outcome: "not_sent",
      error: "the call socket is off (HARNEXUS_CALL_SOCKET=off)",
    };
  const path = socket.value;
  const query = await requestLine(
    path,
    JSON.stringify({ version: PROTOCOL_VERSION, query: "capabilities" }),
    QUERY_TIMEOUT_MS,
  );
  // The query changes nothing, so any failure of it leaves the call unsent.
  if (query.isErr())
    return {
      outcome: "not_sent",
      error: `${path}: ${query.error.code ?? query.error.message}; ${socketHint(query.error.code)}`,
    };
  const offered = parseJson(query.value).unwrapOr(null);
  if (
    !isObject(offered) ||
    offered.outcome !== "done" ||
    offered.version !== PROTOCOL_VERSION ||
    !Array.isArray(offered.operations)
  )
    return {
      outcome: "unsupported",
      error: `the bridge does not offer call protocol ${PROTOCOL_VERSION}; update harnexus and restart the app`,
    };
  if (!offered.operations.includes(tool))
    return {
      outcome: "unsupported",
      error: `the bridge does not offer ${tool}`,
    };

  const answer = await requestLine(
    path,
    JSON.stringify({
      version: PROTOCOL_VERSION,
      threadId: caller,
      tool,
      arguments: args,
    }),
    deps.timeoutMs ?? ANSWER_TIMEOUT_MS,
  );
  if (answer.isErr()) {
    const reason = answer.error.code ?? answer.error.message;
    // A socket that could not be connected to never received the call; any other failure came after it was written.
    return answer.error.connected
      ? { outcome: "unknown", error: `no answer: ${reason}` }
      : {
          outcome: "not_sent",
          error: `${path}: ${reason}; ${socketHint(answer.error.code)}`,
        };
  }

  const parsed = parseJson(answer.value).unwrapOr(null);
  if (!isObject(parsed) || typeof parsed.outcome !== "string")
    return { outcome: "unknown", error: "no answer: answer without outcome" };
  // The version only frames the line, so the records keep the answer as the first protocol gave it.
  const { version: _, ...rest } = parsed;
  return rest;
};

// Outcomes after which the bridge surely did not act, so the call may be sent again.
export const UNSENT: ReadonlySet<unknown> = new Set<CallOutcome>([
  "not_sent",
  "rejected",
  "invalid",
  "unsupported",
]);

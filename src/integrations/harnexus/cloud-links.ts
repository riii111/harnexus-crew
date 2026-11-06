import { join } from "node:path";

import { Result } from "better-result";

import { listDirectoryIfExists } from "../../lib/fs.boundary.ts";
import { isObject } from "../../lib/object.ts";
import { fail } from "../../task/format.ts";
import { load, type SaveJson, stateRoot } from "../../task/records.ts";
import { type Env, io } from "../../task/request.ts";

// One Cloud session's chat as harnexus state export-cloud-links and import-cloud-links carry it: a null threadId is a chat whose opening never reported back, so it is never opened again.
export type CloudLink = {
  sessionId: string;
  threadId: string | null;
  reservedAt: string;
};

export type CloudLinks = { version: 1; links: CloudLink[] };

const SESSION_ID = /^[A-Za-z0-9_-]{1,128}$/;

const LINK_KEYS = new Set(["sessionId", "threadId", "reservedAt"]);

const SHAPE =
  'expected {"version":1,"links":[{"sessionId","threadId","reservedAt"}]} with each session once';

// harnexus-task cloud kept one file per session, which only taskctl reads.
const chatsDirectory = (env: Env) => join(stateRoot(env), "cloud-chats");

// A file harnexus-task cloud wrote: startedAt while the chat was being opened, openedAt once it was; a file naming neither time is dated now, since the reservation stands either way.
const linkOf = (sessionId: string, kept: unknown): CloudLink | null => {
  if (!isObject(kept) || !("threadId" in kept)) return null;
  const { threadId } = kept;
  if (threadId !== null && (typeof threadId !== "string" || threadId === ""))
    return null;
  const reservedAt =
    typeof kept.openedAt === "string"
      ? kept.openedAt
      : typeof kept.startedAt === "string"
        ? kept.startedAt
        : new Date().toISOString();
  return { sessionId, threadId, reservedAt };
};

// Every session harnexus-task cloud opened or began to open, refusing a file it cannot read rather than leaving it out.
export const exportLinks = (env: Env) =>
  Result.gen(async function* () {
    const dir = chatsDirectory(env);
    const names = (yield* Result.await(io(listDirectoryIfExists(dir)))) ?? [];
    const links: CloudLink[] = [];
    for (const name of names.sort()) {
      if (!name.endsWith(".json")) continue;
      const sessionId = name.slice(0, -".json".length);
      if (!SESSION_ID.test(sessionId)) continue;
      const link = linkOf(
        sessionId,
        yield* Result.await(load(join(dir, name))),
      );
      if (link === null)
        return fail(`${join(dir, name)} is not a Cloud chat record`);
      links.push(link);
    }

    return Result.ok<CloudLinks>({ version: 1, links });
  });

const linksIn = (value: unknown) => {
  if (!isObject(value) || value.version !== 1 || !Array.isArray(value.links))
    return null;
  const links: CloudLink[] = [];
  const sessions = new Set<string>();
  for (const item of value.links) {
    if (
      !isObject(item) ||
      Object.keys(item).some((key) => !LINK_KEYS.has(key)) ||
      typeof item.sessionId !== "string" ||
      !SESSION_ID.test(item.sessionId) ||
      sessions.has(item.sessionId) ||
      typeof item.reservedAt !== "string" ||
      item.reservedAt === ""
    )
      return null;
    const link = linkOf(item.sessionId, {
      threadId: item.threadId,
      startedAt: item.reservedAt,
    });
    if (link === null) return null;
    sessions.add(item.sessionId);
    links.push(link);
  }

  return links;
};

// Writes links back as harnexus-task cloud kept them, for a return to it; a chat already recorded is never lost or replaced by another, and a reservation is kept until a chat is named for it.
export const importLinks = (env: Env, value: unknown, save: SaveJson) =>
  Result.gen(async function* () {
    const links = linksIn(value);
    if (links === null) return fail(SHAPE);
    const dir = chatsDirectory(env);
    const conflicts: string[] = [];
    let written = 0;
    let kept = 0;
    for (const link of links) {
      const path = join(dir, `${link.sessionId}.json`);
      const before = yield* Result.await(load(path));
      const existing = before === null ? null : linkOf(link.sessionId, before);
      if (before !== null && existing === null) {
        conflicts.push(link.sessionId);
        continue;
      }

      if (
        existing !== null &&
        (existing.threadId === link.threadId || link.threadId === null)
      ) {
        kept += 1;
        continue;
      }

      if (existing !== null && existing.threadId !== null) {
        conflicts.push(link.sessionId);
        continue;
      }

      yield* Result.await(
        save(
          path,
          link.threadId === null
            ? { threadId: null, startedAt: link.reservedAt }
            : { threadId: link.threadId, openedAt: link.reservedAt },
          { exclusive: false },
        ),
      );
      written += 1;
    }

    return conflicts.length > 0
      ? fail(
          `kept the chats already recorded for ${conflicts.join(", ")}, which the links name differently; wrote ${written}`,
        )
      : Result.ok({ written, kept });
  });

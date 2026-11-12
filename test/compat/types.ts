import { z } from "zod";

const SCOPES = [
  "stdout",
  "stderr",
  "requests",
  "commands",
  "files",
  "lines",
] as const;

const Scope = z.enum(SCOPES);

// A regular expression replaced only in the named scopes and never in file paths, so a changed state key is still seen.
const Replace = z.strictObject({
  pattern: z.string().min(1),
  with: z.string(),
  scopes: z.array(Scope).min(1),
});

const Step = z.union([
  z.strictObject({ send: z.string() }),
  // Waits until this many stdout lines have arrived in total.
  z.strictObject({ wait: z.number().int().positive() }),
]);

const BridgeStep = z.strictObject({
  // Members the request must contain, compared as JSON; absent matches any request.
  match: z.record(z.string(), z.unknown()).optional(),
  // "drop" closes the connection unanswered; "silent" holds it open.
  answer: z.union([
    z.record(z.string(), z.unknown()),
    z.enum(["drop", "silent"]),
  ]),
});

const Shim = z.strictObject({
  stdout: z.string().optional(),
  stderr: z.string().optional(),
  exit: z.number().int().optional(),
});

const Mode = z.enum(["json", "lines", "exact"]);

export const CaseSchema = z.strictObject({
  name: z.string().min(1),
  // The task that makes the Native binary pass this case.
  owner: z.string().regex(/^MB\d\d$/),
  // Pending cases run against the baseline only, until their owner turns them active.
  status: z.enum(["pending", "active"]),
  // command: answers once; help: usage text; session: a long-running exchange by lines; inherit: a child that shares the standard streams.
  kind: z.enum(["command", "help", "session", "inherit"]),
  argv: z.array(z.string()),
  env: z.record(z.string(), z.string()).default({}),
  stdin: z.string().default(""),
  steps: z.array(Step).default([]),
  // Text files written under the sandbox root before the run.
  files: z.record(z.string(), z.string()).default({}),
  // Directories copied from the repository under the sandbox root before the run, as target: source.
  seed: z.record(z.string(), z.string()).default({}),
  // git commands run in the sandbox root before the run, such as to make a repository with fixed commits; the placeholders of files apply.
  git: z.array(z.array(z.string())).default([]),
  bridge: z.array(BridgeStep).optional(),
  commands: z.record(z.string(), Shim).default({}),
  snapshot: z
    .array(z.string())
    .default(["config", "state", "work", "home/.local", "home/.config"]),
  normalize: z.array(Replace).default([]),
  compare: z
    .strictObject({ stdout: Mode.optional(), stderr: Mode.optional() })
    .default({}),
});

export type Case = z.infer<typeof CaseSchema>;
export type Scope = z.infer<typeof Scope>;
export type ReplaceRule = z.infer<typeof Replace>;
export type CompareMode = z.infer<typeof Mode>;

export type Observation = {
  exitCode: number | null;
  signal: string | null;
  stdout: string;
  stderr: string;
  // One entry per connection to the bridge: the line it sent, or "" when it sent none.
  requests: string[];
  commands: { name: string; argv: string[]; stdin: string }[];
  // Regular files under the snapshot directories, by path relative to the sandbox root.
  files: Record<string, string>;
};

export type Difference = {
  field: string;
  expected: unknown;
  actual: unknown;
};

export type Implementation = { name: string; argv: string[] };

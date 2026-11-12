import type { Case, Observation, Scope } from "./types.ts";

// The sandbox root differs per run, so it is the one thing always replaced.
export const ROOT_MARK = "<ROOT>";

const replaceIn = (spec: Case, scope: Scope, text: string) =>
  spec.normalize
    .filter((rule) => rule.scopes.includes(scope))
    .reduce(
      (current, rule) =>
        current.replace(new RegExp(rule.pattern, "gu"), rule.with),
      text,
    );

// Replaces text inside values only: nothing is dropped, merged or reordered, so a repeated request or a lost result still shows as a difference, and file paths keep their state keys.
export const normalize = (
  observation: Observation,
  spec: Case,
  root: string,
): Observation => {
  const text = (scope: Scope, value: string) =>
    replaceIn(spec, scope, value.replaceAll(root, ROOT_MARK));
  return {
    exitCode: observation.exitCode,
    signal: observation.signal,
    stdout: text("stdout", observation.stdout),
    stderr: text("stderr", observation.stderr),
    requests: observation.requests.map((line) => text("requests", line)),
    commands: observation.commands.map((command) => ({
      name: command.name,
      argv: command.argv.map((arg) => text("commands", arg)),
      stdin: text("commands", command.stdin),
    })),
    files: Object.fromEntries(
      Object.entries(observation.files).map(([path, content]) => [
        path,
        text("files", content),
      ]),
    ),
  };
};

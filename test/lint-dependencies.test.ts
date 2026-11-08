import { test, expect } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";

import stylistic from "@stylistic/eslint-plugin";
import { ESLint } from "eslint";

// Keep the minimatch security override compatible with both ESLint's directory
// traversal and @eslint/config-array's matching, including ignored files.
test("the lint dependencies discover files and apply stylistic rules with patched minimatch", async () => {
  const root = await mkdtemp(join(tmpdir(), "taskctl-lint-deps-"));
  try {
    await mkdir(join(root, "nested"));
    await mkdir(join(root, "ignored"));
    await Promise.all([
      writeFile(join(root, "root.js"), "debugger;\n"),
      writeFile(
        join(root, "nested", "rule.cjs"),
        "if (true) {\n  foo();\n}\nbar();\n",
      ),
      writeFile(join(root, "nested", "clean.js"), "const value = 1;\n"),
      writeFile(join(root, "ignored", "skip.js"), "debugger;\n"),
      writeFile(join(root, ".hidden.js"), "debugger;\n"),
      writeFile(join(root, "other.txt"), "debugger;\n"),
    ]);
    const eslint = new ESLint({
      cwd: root,
      overrideConfigFile: true,
      overrideConfig: [
        { ignores: ["ignored/**", ".hidden.js"] },
        {
          files: ["**/*.{js,cjs}"],
          plugins: { "@stylistic": stylistic },
          rules: {
            "no-debugger": "error",
            "@stylistic/padding-line-between-statements": [
              "error",
              { blankLine: "always", prev: "multiline-block-like", next: "*" },
            ],
          },
        },
      ],
    });
    const results = await eslint.lintFiles(["**/*.{js,cjs}"]);
    expect(
      results
        .map(({ filePath, messages }) => ({
          file: relative(root, filePath).replaceAll("\\", "/"),
          rules: messages.map(({ ruleId }) => ruleId),
        }))
        .sort((a, b) => a.file.localeCompare(b.file)),
    ).toEqual([
      { file: "nested/clean.js", rules: [] },
      {
        file: "nested/rule.cjs",
        rules: ["@stylistic/padding-line-between-statements"],
      },
      { file: "root.js", rules: ["no-debugger"] },
    ]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

// Why the running Bun may not build harnexus-crew, or null when it is the pinned one.
export const unpinnedBun = (pinned: string | null, running: string) =>
  pinned === running
    ? null
    : pinned === null
      ? `Bun ${running} runs this build, while package.json pins no Bun version`
      : `Bun ${running} runs this build, while harnexus-crew pins ${pinned}; install Bun ${pinned} and run scripts/install.sh again`;

// The Bun that package.json names as its package manager, as bun@1.2.3.
export const pinnedBunOf = (manifest: unknown) => {
  const manager =
    typeof manifest === "object" && manifest !== null
      ? (manifest as { packageManager?: unknown }).packageManager
      : undefined;
  return typeof manager === "string" && /^bun@\d+\.\d+\.\d+$/.test(manager)
    ? manager.slice("bun@".length)
    : null;
};

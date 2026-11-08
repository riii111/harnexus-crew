#!/usr/bin/env bash
# Builds harnexus-crew from a chosen commit and places it under a directory of your choice, on macOS or Linux.
# The new binary is built and checked in a temporary directory first; if that fails, the installed one is left as it was.
# It changes nothing else: no PATH, shell profile or environment setting, and harnexus-task only when asked.
set -euo pipefail

prefix=${HARNEXUS_CREW_PREFIX:-${TASKCTL_PREFIX:-$HOME/.local/bin}}
repo=${HARNEXUS_CREW_REPO:-${TASKCTL_REPO:-}}
rev=${HARNEXUS_CREW_REV:-${TASKCTL_REV:-}}
bun_bin=bun
compat=no

usage() {
  cat >&2 <<'MSG'
usage: scripts/install.sh [--prefix ABSOLUTE_DIR] [--repo URL_OR_PATH --rev COMMIT] [--bun ABSOLUTE_PATH_TO_BUN] [--compat | --replace-harnexus-task]
  --prefix                 where harnexus-crew goes (default: $HARNEXUS_CREW_PREFIX or ~/.local/bin)
  --repo, --rev            build that commit of that repository (default: $HARNEXUS_CREW_REPO, $HARNEXUS_CREW_REV; this checkout as it is committed when neither is set)
  --compat                 also add harnexus-task as a link to harnexus-crew, unless a harnexus-task that is not that link is there
  --replace-harnexus-task  as --compat, moving an existing harnexus-task aside to harnexus-task.pre-harnexus-crew first
MSG
  exit 2
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --prefix) [[ $# -ge 2 ]] || usage; prefix=$2; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || usage; repo=$2; shift 2 ;;
    --rev) [[ $# -ge 2 ]] || usage; rev=$2; shift 2 ;;
    --bun) [[ $# -ge 2 ]] || usage; bun_bin=$2; shift 2 ;;
    --compat) compat=link; shift ;;
    --replace-harnexus-task) compat=replace; shift ;;
    *) usage ;;
  esac
done

fail() { echo "install: $1" >&2; exit "${2:-1}"; }

[[ $prefix == /* ]] || fail "--prefix must be an absolute path" 2
if [[ $bun_bin != bun && $bun_bin != /* ]]; then
  fail "--bun must be an absolute path" 2
fi
if [[ -n $repo && -z $rev ]]; then
  fail "--repo needs --rev, so the installed commit is the one asked for" 2
fi
legacy="$prefix/harnexus-task"
ours_legacy() { [[ -L $legacy && $(readlink "$legacy") == harnexus-crew ]]; }
# Checked before anything is built or replaced, so a refusal leaves the prefix untouched.
if [[ $compat != no ]] && ! ours_legacy && [[ -e $legacy || -L $legacy ]]; then
  [[ $compat == replace ]] || fail "$legacy is not harnexus-crew; leave it, or rerun with --replace-harnexus-task to move it aside"
  [[ ! -e $legacy.pre-harnexus-crew && ! -L $legacy.pre-harnexus-crew ]] || fail "$legacy.pre-harnexus-crew exists; move it away first so no earlier harnexus-task is lost"
fi

command -v "$bun_bin" >/dev/null 2>&1 || fail "Bun is not available; install the Bun that package.json pins, or name it with --bun"
command -v git >/dev/null 2>&1 || fail "git is not available"

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/harnexus-crew-install.XXXXXX")
cleanup() {
  rm -rf "$work"
  [[ -z ${staged:-} ]] || rm -f "$staged"
  [[ -z ${link:-} ]] || rm -f "$link"
  [[ -z ${previous:-} ]] || rm -f "$previous"
}
trap cleanup EXIT

# The source is a clean checkout of one commit, so uncommitted edits never reach the installed binary.
source_repo=${repo:-$here}
git clone --quiet --no-checkout "$source_repo" "$work/src"
if [[ -n $rev ]]; then
  git -C "$work/src" fetch --quiet origin "$rev" 2>/dev/null || true
  wanted=$(git -C "$work/src" rev-parse --verify --quiet "$rev^{commit}") || fail "commit $rev is not in $source_repo"
else
  wanted=$(git -C "$here" rev-parse HEAD)
fi
git -C "$work/src" checkout --quiet --detach "$wanted"

bun_dir=$(dirname "$(command -v "$bun_bin")")
(
  cd "$work/src"
  # The build starts bun by name, so the chosen one comes first on PATH.
  export PATH="$bun_dir:$PATH"
  "$bun_bin" install --frozen-lockfile >/dev/null
  "$bun_bin" --no-env-file --config=/dev/null src/cli/check-bun.ts
  "$bun_bin" build --compile --no-compile-autoload-dotenv --no-compile-autoload-bunfig src/cli/task.ts --outfile "$work/harnexus-crew" >/dev/null
)

# A binary that cannot start, or cannot fill the worker and reviewer templates task.json names, is never installed, so the set in use stays whole.
"$work/harnexus-crew" --help | head -n 1 | grep -qx 'usage:' || fail "the built harnexus-crew did not start; nothing was replaced"
checked=$("$work/harnexus-crew" check 2>&1) || fail "the built harnexus-crew cannot use the configured templates; nothing was replaced: $checked"

# Everything is staged beside its target first, so each switch is one rename, and a failed switch puts back what was there.
mkdir -p "$prefix"
staged=$(mktemp "$prefix/.harnexus-crew.XXXXXX")
install -m 0755 "$work/harnexus-crew" "$staged"
link=
if [[ $compat != no ]] && ! ours_legacy; then
  link=$(mktemp -u "$prefix/.harnexus-task.XXXXXX")
  ln -s harnexus-crew "$link"
fi
previous=
if [[ -e $prefix/harnexus-crew ]]; then
  previous=$(mktemp -u "$prefix/.harnexus-crew.previous.XXXXXX")
  ln "$prefix/harnexus-crew" "$previous"
fi
moved_aside=no

# For tests only: fails the named step, to show what a failed switch leaves.
fault() { [[ ${TASKCTL_INSTALL_FAULT:-} == "$1" ]] && return 1; return 0; }

rollback() {
  if [[ $moved_aside == yes ]]; then mv -f "$legacy.pre-harnexus-crew" "$legacy"; fi
  if [[ -n $previous ]]; then mv -f "$previous" "$prefix/harnexus-crew"; else rm -f "$prefix/harnexus-crew"; fi
  previous=
  fail "$1; the earlier harnexus-crew and harnexus-task were put back"
}

mv -f "$staged" "$prefix/harnexus-crew" || rollback "cannot place harnexus-crew"
staged=
if [[ -n $link ]]; then
  if [[ -e $legacy || -L $legacy ]]; then
    { fault aside && mv "$legacy" "$legacy.pre-harnexus-crew"; } || rollback "cannot move $legacy aside"
    moved_aside=yes
  fi
  { fault link && mv -f "$link" "$legacy"; } || rollback "cannot link $legacy"
  link=
fi
[[ -z $previous ]] || rm -f "$previous"
previous=
echo "installed $prefix/harnexus-crew from $wanted"
if [[ $compat != no ]]; then
  [[ $moved_aside == no ]] || echo "moved the earlier harnexus-task to $legacy.pre-harnexus-crew"
  echo "$legacy runs harnexus-crew"
fi
echo "nothing was added to PATH"

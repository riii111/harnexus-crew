#!/usr/bin/env bash
# Builds harnexus-crew from a chosen commit and places it under a directory of your choice, on macOS or Linux.
# The new binary is built and checked in a temporary directory first; if that fails, the installed one is left as it was.
# It changes no PATH, shell profile or environment setting.
set -euo pipefail

prefix=${HARNEXUS_CREW_PREFIX:-$HOME/.local/bin}
repo=${HARNEXUS_CREW_REPO:-}
rev=${HARNEXUS_CREW_REV:-}
moon_bin=

usage() {
  cat >&2 <<'MSG'
usage: scripts/install.sh [--prefix ABSOLUTE_DIR] [--repo URL_OR_PATH --rev COMMIT] [--moon ABSOLUTE_PATH_TO_MOON]
  --prefix                 where harnexus-crew goes (default: $HARNEXUS_CREW_PREFIX or ~/.local/bin)
  --repo, --rev            build that commit of that repository (default: $HARNEXUS_CREW_REPO, $HARNEXUS_CREW_REV; this checkout as it is committed when neither is set)
  --moon                   the MoonBit toolchain to build with (default: moon on PATH, else the one flake.nix pins, through nix)
MSG
  exit 2
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --prefix) [[ $# -ge 2 ]] || usage; prefix=$2; shift 2 ;;
    --repo) [[ $# -ge 2 ]] || usage; repo=$2; shift 2 ;;
    --rev) [[ $# -ge 2 ]] || usage; rev=$2; shift 2 ;;
    --moon) [[ $# -ge 2 ]] || usage; moon_bin=$2; shift 2 ;;
    *) usage ;;
  esac
done

fail() { echo "install: $1" >&2; exit "${2:-1}"; }

[[ $prefix == /* ]] || fail "--prefix must be an absolute path" 2
if [[ -n $moon_bin && $moon_bin != /* ]]; then
  fail "--moon must be an absolute path" 2
fi
if [[ -n $repo && -z $rev ]]; then
  fail "--repo needs --rev, so the installed commit is the one asked for" 2
fi
command -v git >/dev/null 2>&1 || fail "git is not available"

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/harnexus-crew-install.XXXXXX")
cleanup() {
  rm -rf "$work"
  [[ -z ${staged:-} ]] || rm -f "$staged"
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

# flake.nix pins the toolchain, so a build without a moon of its own goes through nix rather than through whatever moon is installed.
if [[ -n $moon_bin ]]; then
  [[ -x $moon_bin ]] || fail "$moon_bin is not an executable"
  build=("$moon_bin")
elif command -v moon >/dev/null 2>&1; then
  build=(moon)
elif command -v nix >/dev/null 2>&1; then
  build=(nix develop --no-write-lock-file "$work/src" --command moon)
else
  fail "MoonBit is not available; install the toolchain flake.nix pins, run this inside 'nix develop', or name moon with --moon"
fi

(
  cd "$work/src"
  "${build[@]}" build --target native --release >"$work/build.log" 2>&1
) || fail "the build failed; nothing was replaced: $(tail -n 20 "$work/build.log")"
built="$work/src/_build/native/release/build/cmd/main/main.exe"
[[ -x $built ]] || fail "the build made no harnexus-crew; nothing was replaced"

# A binary that cannot start, or cannot fill the worker and reviewer templates task.json names, is never installed, so the set in use stays whole.
usage_text=$("$built" --help 2>&1) || fail "the built harnexus-crew did not start; nothing was replaced"
[[ ${usage_text%%$'\n'*} == "usage:" ]] || fail "the built harnexus-crew did not start; nothing was replaced"
checked=$("$built" check 2>&1) || fail "the built harnexus-crew cannot use the configured templates; nothing was replaced: $checked"

# Everything is staged beside its target first, so each switch is one rename, and a failed switch puts back what was there.
mkdir -p "$prefix"
staged=$(mktemp "$prefix/.harnexus-crew.XXXXXX")
install -m 0755 "$built" "$staged"
previous=
if [[ -e $prefix/harnexus-crew ]]; then
  previous=$(mktemp -u "$prefix/.harnexus-crew.previous.XXXXXX")
  ln "$prefix/harnexus-crew" "$previous"
fi

rollback() {
  if [[ -n $previous ]]; then mv -f "$previous" "$prefix/harnexus-crew"; else rm -f "$prefix/harnexus-crew"; fi
  previous=
  fail "$1; the earlier harnexus-crew was put back"
}

mv -f "$staged" "$prefix/harnexus-crew" || rollback "cannot place harnexus-crew"
staged=
[[ -z $previous ]] || rm -f "$previous"
previous=
echo "installed $prefix/harnexus-crew from $wanted"
echo "nothing was added to PATH"

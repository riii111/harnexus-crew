#!/usr/bin/env bash
# Checks the formatting, warnings and static analysis of the hand-written C under native/.
# Run it inside `nix develop` so clang-format and clang-tidy are the versions flake.nix pins.
set -euo pipefail

cd "$(dirname "$0")/.."
# md4c is vendored and kept as upstream ships it.
mapfile -t files < <(git ls-files 'native/*.c' ':!native/markdown/md4c.c')

clang-format --dry-run --Werror "${files[@]}"

include="$(dirname "$(dirname "$(command -v moonc)")")/include"
# The flags after the include are the ones moon passes to its C compiler, so the analysis sees the same code.
# Unused parameters are allowed because md4c callbacks have fixed signatures.
clang-tidy --quiet "${files[@]}" -- \
  -I"$include" -fwrapv -fno-strict-aliasing -ffp-contract=off \
  -Wall -Wextra -Wconversion -Wno-unused-parameter

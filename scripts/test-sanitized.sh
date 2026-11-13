#!/usr/bin/env bash
# Runs the MoonBit tests with the native code built under AddressSanitizer and UndefinedBehaviorSanitizer.
# Checked on Linux; on macOS the run did not finish in reasonable time, so CI runs it on Linux only.
set -euo pipefail

cd "$(dirname "$0")/.."
real_cc=$(command -v cc)
wrapper_dir=$(mktemp -d)
trap 'rm -rf "$wrapper_dir"' EXIT

# moon takes MOON_CC as a single executable, so the sanitizer flags go in a wrapper that it uses to compile and link.
cat >"$wrapper_dir/cc" <<SH
#!/bin/sh
exec "$real_cc" -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=undefined "\$@"
SH
chmod +x "$wrapper_dir/cc"

# The MoonBit runtime leaves its objects allocated at exit, so leak detection would fail every test.
# The separate target directory keeps sanitized objects out of the regular build cache.
MOON_CC="$wrapper_dir/cc" MOON_AR=$(command -v ar) ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=print_stacktrace=1 \
  moon test --target native --target-dir _build/sanitize "$@"

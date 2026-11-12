#!/usr/bin/env bash
# Stand-in for the t3 CLI: records each run's arguments, directory and stdin in $FAKE_DIR, then replays the planned output.
# Run n reads out.n, exit.n, stderr.n and sleep.n from $FAKE_DIR.
dir="$FAKE_DIR"
n=$(( $(cat "$dir/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$dir/count"
printf '%s\n' "$@" > "$dir/args.$n"
pwd > "$dir/cwd.$n"
cat > "$dir/stdin.$n"
if [ -f "$dir/sleep.$n" ]; then sleep "$(cat "$dir/sleep.$n")"; fi
if [ -f "$dir/stderr.$n" ]; then cat "$dir/stderr.$n" >&2; fi
cat "$dir/out.$n" 2>/dev/null
exit "$(cat "$dir/exit.$n" 2>/dev/null || echo 0)"

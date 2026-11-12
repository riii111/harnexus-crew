#!/usr/bin/env bash
# Stand-in for pr-wake and its engine: records each run's arguments and environment in $FAKE_DIR, then replays the planned output.
# Copied under the name it stands in for, so run n of that name reads $name.out.n, $name.exit.n, $name.stderr.n and $name.sleep.n.
# Stdin is not read, as a run that is given none would wait for it.
dir="$FAKE_DIR"
name=$(basename "$0")
n=$(( $(cat "$dir/$name.count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$dir/$name.count"
printf '%s\n' "$@" > "$dir/$name.args.$n"
env | sort > "$dir/$name.env.$n"
if [ -f "$dir/$name.sleep.$n" ]; then exec sleep "$(cat "$dir/$name.sleep.$n")"; fi
if [ -f "$dir/$name.stderr.$n" ]; then cat "$dir/$name.stderr.$n" >&2; fi
cat "$dir/$name.out.$n" 2>/dev/null
exit "$(cat "$dir/$name.exit.$n" 2>/dev/null || echo 0)"

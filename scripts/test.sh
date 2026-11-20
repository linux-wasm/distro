#!/bin/sh
# Boot the built system headless under node, twice with the same disk for
# changes, type the commands of tests/*-input.txt at the first prompt and
# check the console log against tests/*-expect.txt.
#
#   scripts/test.sh [extra node-run.mjs options]
set -eu
. "$(dirname "$0")/common.sh"

log="$(mktemp)"
data="$(mktemp)"
trap 'rm -f "$log" "$data"' EXIT
# The test writes to its own copy of the (empty) layer for changes.
cp "$WORK/data.img" "$data"

# run_case NAME [node-run.mjs options]: boot, type tests/NAME-input.txt at
# the first prompt and check the console log against tests/NAME-expect.txt.
run_case() {
	name="$1"
	shift
	# Build node-run.mjs's --input/--input-after pairs from the input
	# file: each line is typed followed by Enter, which is a carriage
	# return as on a real terminal (node-run.mjs turns \xHH into that
	# byte);
	# "@wait TEXT" holds back what follows until TEXT has been printed.
	chunk=
	after='# '
	while IFS= read -r line; do
		case "$line" in
		'@wait '*)
			set -- "$@" --input "$chunk" --input-after "$after"
			chunk=
			after="${line#@wait }"
			;;
		*)
			chunk="$chunk$line\\x0d"
			;;
		esac
	done < "$DISTRO/tests/$name-input.txt"
	set -- "$@" --input "$chunk" --input-after "$after"

	status=0
	node "$KERNEL_TOOLS/host/node-run.mjs" --kernel "$KERNEL_OUT/vmlinux.wasm" \
		--disk "$WORK/base.erofs" --disk "$data" \
		--timeout "${BOOT_TIMEOUT:-60}" "$@" > "$log" 2>&1 || status=$?

	fail=0
	line=0
	while IFS= read -r expect; do
		case "$expect" in ''|'#'*) continue ;; esac
		next="$(tail -n "+$((line + 1))" "$log" | grep -n -F -m1 -- "$expect" | cut -d: -f1)"
		if [ -z "$next" ]; then
			echo "FAIL: $name: missing (or out of order): $expect"
			fail=1
		else
			line=$((line + next))
		fi
	done < "$DISTRO/tests/$name-expect.txt"

	if [ "$fail" -ne 0 ]; then
		echo "--- console log (node-run exit status $status) ---"
		cat "$log"
		exit 1
	fi
	echo "PASS: $name test ($(grep -c . "$log") log lines, node-run exit status $status)"
}

run_case boot "$@"
# A second boot with the same disk: what the first one changed is there.
run_case persist "$@"

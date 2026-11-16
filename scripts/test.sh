#!/bin/sh
# Boot the built system headless under node, type the commands of
# tests/boot-input.txt at the first prompt, and check the console log
# against tests/boot-expect.txt.
set -eu
. "$(dirname "$0")/common.sh"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# node-run.mjs turns the two characters \n into a newline.
input="$(awk '{ printf "%s\\n", $0 }' "$DISTRO/tests/boot-input.txt")"

status=0
node "$KERNEL_TOOLS/host/node-run.mjs" --kernel "$KERNEL_OUT/vmlinux.wasm" \
	--timeout "${BOOT_TIMEOUT:-30}" --input "$input" --input-after '# ' \
	"$@" > "$log" 2>&1 || status=$?

fail=0
line=0
while IFS= read -r expect; do
	case "$expect" in ''|'#'*) continue ;; esac
	next="$(tail -n "+$((line + 1))" "$log" | grep -n -F -m1 -- "$expect" | cut -d: -f1)"
	if [ -z "$next" ]; then
		echo "FAIL: missing (or out of order): $expect"
		fail=1
	else
		line=$((line + next))
	fi
done < "$DISTRO/tests/boot-expect.txt"

if [ "$fail" -ne 0 ]; then
	echo "--- console log (node-run exit status $status) ---"
	cat "$log"
	exit 1
fi
echo "PASS: boot test ($(grep -c . "$log") log lines, node-run exit status $status)"

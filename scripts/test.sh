#!/bin/sh
# Boot the built system headless under node: twice with the same disk for
# changes, then once with a network card. Each time the commands of
# tests/*-input.txt are typed at the first prompt and the console log is
# checked against tests/*-expect.txt.
#
#   scripts/test.sh [extra node-run.mjs options]
set -eu
. "$(dirname "$0")/common.sh"

log="$(mktemp)"
data="$(mktemp)"
tmp="$(mktemp -d)"
servers=
trap 'rm -rf "$log" "$data" "$tmp"; [ -z "$servers" ] || kill "$servers"' EXIT
# The test writes to its own copy of the (empty) layer for changes.
cp "$WORK/data.img" "$data"

# run_case NAME [node-run.mjs options]: boot, type tests/NAME-input.txt at
# the first prompt and check the console log against tests/NAME-expect.txt.
run_case() {
	name="$1"
	shift
	# The network test has made its own copies, with port numbers in.
	input="$tmp/$name-input.txt"
	expect="$tmp/$name-expect.txt"
	[ -f "$input" ] || input="$DISTRO/tests/$name-input.txt"
	[ -f "$expect" ] || expect="$DISTRO/tests/$name-expect.txt"
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
	done < "$input"
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
	done < "$expect"

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

# A third boot, with a network card. Its proxy (linux-wasm/netproxy), an
# HTTP server and a name server run here, on ports of their own choosing.
"$DISTRO/scripts/fetch.sh" netproxy
[ -d "$NETPROXY_DIR/node_modules" ] || (cd "$NETPROXY_DIR" && npm ci --omit=dev --silent)
node "$DISTRO/scripts/net-test-servers.mjs" "$NETPROXY_DIR" > "$tmp/ports" &
servers=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
	[ -s "$tmp/ports" ] && break
	sleep 0.5
done
[ -s "$tmp/ports" ] || { echo "FAIL: net: the test servers did not start"; exit 1; }
eval "$(cat "$tmp/ports")"
sed "s/@HTTP@/$HTTP/g; s/@HTTPS@/$HTTPS/g" "$DISTRO/tests/net-input.txt" > "$tmp/net-input.txt"
# cksum of "0123456789" x 30000, what the HTTP server sends for /large.
sed "s/@CKSUM@/1993361615/" "$DISTRO/tests/net-expect.txt" > "$tmp/net-expect.txt"
run_case net --net "ws://127.0.0.1:$PROXY/" --dns "127.0.0.1:$DNS" "$@"

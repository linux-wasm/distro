#!/bin/sh
# Serve the built site (work/site/) on http://127.0.0.1:8080/.
#
#   scripts/serve.sh             # server sends COOP/COEP itself
#   scripts/serve.sh --plain     # plain static server, like GitHub Pages:
#                                # isolation then comes from site/sw.js
set -eu
. "$(dirname "$0")/common.sh"

[ -d "$SITE_OUT" ] || "$DISTRO/scripts/build.sh" site

if [ "${1:-}" = --plain ]; then
	shift
	exec python3 -m http.server --bind 127.0.0.1 --directory "$SITE_OUT" "${1:-8080}"
fi
exec "$KERNEL_TOOLS/scripts/serve.py" --dir "$SITE_OUT" \
	--kernel "$SITE_OUT/vmlinux.wasm" "$@"

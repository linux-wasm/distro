#!/bin/sh
# Serve the built system on http://127.0.0.1:8080/ with the COOP/COEP
# headers that SharedArrayBuffer needs. Uses the kernel's reference host
# page until the distro has its own.
set -eu
. "$(dirname "$0")/common.sh"

exec "$KERNEL_TOOLS/scripts/serve.py" "$@"

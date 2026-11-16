#!/bin/sh
# Boot the built system headless under node and check the kernel log.
# Today this is the kernel's own boot test (expected end: "No working init
# found"); it will check for a shell prompt once there is a user space.
set -eu
. "$(dirname "$0")/common.sh"

exec "$KERNEL_TOOLS/scripts/test-boot.sh" "$@"

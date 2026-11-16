#!/bin/sh
# Boot the built system headless under node and check the kernel log.
# Today this is the kernel's own boot test (the kernel's test init prints a
# few lines and powers off); it will check for a shell prompt once the
# distro has a user space of its own.
set -eu
. "$(dirname "$0")/common.sh"

exec "$KERNEL_TOOLS/scripts/test-boot.sh" "$@"

#!/bin/sh
# Use authenticated process ownership and restoration-aware lifecycle control.
set -eu
HYPRWM_HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$HYPRWM_HOOK_DIR/lifecycle.py" stop "$@"

#!/bin/sh
# Install/start the user-owned LaunchAgent; never kill processes by name.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
exec python3 "$root/scripts/install_keyboard.py" install "$@"

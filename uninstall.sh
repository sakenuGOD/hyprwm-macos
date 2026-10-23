#!/bin/sh
# Restore windows before removing the receipt-owned installation.
set -eu
HYPRWM_PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "${1:-}" in
    '') [ "$#" -eq 0 ] || exit 2 ;;
    --offline) [ "$#" -eq 1 ] || exit 2 ;;
    -h|--help) printf '%s\n' 'Usage: ./uninstall.sh [--offline]' 'Restores windows, stops the installed daemon, and removes the installed app and CLI.' 'Keeps configuration and backups. --offline refuses a responding daemon and is for isolated installs.'; exit 0 ;;
    *) printf '%s\n' 'Usage: ./uninstall.sh [--offline]' >&2; exit 2 ;;
esac
exec python3 "$HYPRWM_PROJECT/scripts/install_app.py" uninstall ${1:+"$1"}

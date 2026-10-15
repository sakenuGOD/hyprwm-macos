#!/bin/sh
# Build and install the public-API Lite app. Never changes system configuration.
set -eu
HYPRWM_PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "${1:-}" in
    ''|--no-launch) [ "$#" -le 1 ] || exit 2 ;;
    -h|--help) printf '%s\n' 'Usage: ./install.sh [--no-launch]' 'Builds HyprWM into ~/Applications and adds ~/.local/bin/hyprwm and hyprwmctl.' 'Existing configuration is preserved. The app is not launched.'; exit 0 ;;
    *) printf '%s\n' 'Usage: ./install.sh [--no-launch]' >&2; exit 2 ;;
esac
[ "$(uname -s)" = Darwin ] || { printf '%s\n' 'HyprWM requires macOS 14 or later.' >&2; exit 1; }
command -v swift >/dev/null 2>&1 || { printf '%s\n' 'Install Xcode Command Line Tools: xcode-select --install' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf '%s\n' 'Python 3 from Xcode Command Line Tools is required: xcode-select --install' >&2; exit 1; }
swift build -c release --package-path "$HYPRWM_PROJECT/hook/swift"
exec python3 "$HYPRWM_PROJECT/scripts/install_app.py" install --root "$HYPRWM_PROJECT"

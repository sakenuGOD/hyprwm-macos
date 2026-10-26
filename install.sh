#!/bin/sh
# Build and install the user-local app. Never changes system configuration.
set -eu
HYPRWM_PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HYPRWM_INSTALL_ENGINE_STATE=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-launch) shift ;;
        --engine-state)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { printf '%s\n' '--engine-state requires a file' >&2; exit 2; }
            HYPRWM_INSTALL_ENGINE_STATE=$2; shift 2 ;;
        -h|--help)
            printf '%s\n' 'Usage: ./install.sh [--no-launch] [--engine-state FILE]' 'Builds HyprWM into ~/Applications and adds ~/.local/bin/hyprwm and hyprwmctl.' 'Existing configuration is preserved. The app is not launched.' 'FILE selects an existing qualified native Engine receipt outside the app bundle.'; exit 0 ;;
        *) printf '%s\n' 'Usage: ./install.sh [--no-launch] [--engine-state FILE]' >&2; exit 2 ;;
    esac
done
[ "$(uname -s)" = Darwin ] || { printf '%s\n' 'HyprWM requires macOS 14 or later.' >&2; exit 1; }
command -v swift >/dev/null 2>&1 || { printf '%s\n' 'Install Xcode Command Line Tools: xcode-select --install' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf '%s\n' 'Python 3 from Xcode Command Line Tools is required: xcode-select --install' >&2; exit 1; }
swift build -c release --package-path "$HYPRWM_PROJECT/hook/swift"
set -- install --root "$HYPRWM_PROJECT"
if [ -n "$HYPRWM_INSTALL_ENGINE_STATE" ]; then set -- "$@" --engine-state "$HYPRWM_INSTALL_ENGINE_STATE"; fi
exec python3 "$HYPRWM_PROJECT/scripts/install_app.py" "$@"

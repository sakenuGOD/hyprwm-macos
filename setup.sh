#!/bin/sh
# Dependency-free entry point. Native admission always uses the real host.
set -eu
HYPRWM_SETUP_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
HYPRWM_SETUP_DRY=0
for HYPRWM_SETUP_ARG in "$@"; do
    case "$HYPRWM_SETUP_ARG" in
        --dry-run) HYPRWM_SETUP_DRY=1 ;;
        --yes|--no-open|--no-autostart) ;;
        -h|--help)
            printf '%s\n' 'Usage: ./setup.sh [--yes] [--no-open] [--dry-run] [--no-autostart]' 'Installs the qualified native engine, app, keyboard watcher and login services.' '--dry-run only observes preflight, paths, existing artifact hashes and the plan.' '--yes accepts graceful shutdown of conflicting window managers; sudo and macOS permission UI remain interactive.' '--no-open suppresses explicit app/Settings opening; Accessibility must already be granted.' '--no-autostart skips the root LaunchDaemon and user LaunchAgent.'; exit 0 ;;
        *) printf 'Unknown setup option: %s\n' "$HYPRWM_SETUP_ARG" >&2; exit 2 ;;
    esac
done
export PYTHONDONTWRITEBYTECODE=1
hyprwm_setup_python() {
    for HYPRWM_SETUP_CANDIDATE in /Library/Developer/CommandLineTools/usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        if [ -x "$HYPRWM_SETUP_CANDIDATE" ] && "$HYPRWM_SETUP_CANDIDATE" -c 'import sys;sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
            printf '%s\n' "$HYPRWM_SETUP_CANDIDATE"; return 0
        fi
    done
    HYPRWM_SETUP_PATH_PYTHON=$(command -v python3 || true)
    if [ -n "$HYPRWM_SETUP_PATH_PYTHON" ]; then
        # /usr/bin/python3 is an installer stub without CLT; dry-run must not invoke it.
        if [ "$HYPRWM_SETUP_PATH_PYTHON" != /usr/bin/python3 ] || [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ]; then
            if "$HYPRWM_SETUP_PATH_PYTHON" -c 'import sys;sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then printf '%s\n' "$HYPRWM_SETUP_PATH_PYTHON"; return 0; fi
        fi
    fi
    return 1
}
# A dry run must never launch xcode-select, install packages or create files.
if [ "$HYPRWM_SETUP_DRY" = 1 ]; then
    if HYPRWM_SETUP_PYTHON=$(hyprwm_setup_python); then
        exec "$HYPRWM_SETUP_PYTHON" -B "$HYPRWM_SETUP_ROOT/scripts/setup_hyprwm.py" "$@"
    fi
    printf '%s\n' '[1/7] Read-only preflight (Python is unavailable).' "Host: $(uname -s) $(uname -m)" "macOS build: $(/usr/bin/sw_vers -buildVersion 2>/dev/null || printf unknown)" "SIP: $(/usr/bin/csrutil status 2>/dev/null || printf unverified)" 'Plan: install Command Line Tools if missing; install Python/Git using existing Homebrew if needed; build app/native/workspaces; prepare and activate through sudo; install keyboard before opening app; verify Accessibility; install default autostart.' 'No changes made. Artifact hashes require Python 3.9 or newer.'
    for HYPRWM_SETUP_FILE in "$HOME/Applications/HyprWM.app/Contents/Resources/InstallReceipt.json" "$HOME/Applications/HyprWM.app/Contents/MacOS/hyprwm-swift" "$HOME/Library/Application Support/HyprWM/setup/receipt.json" "$HOME/Library/Application Support/HyprWM/setup/images/"*/*; do
        if [ -f "$HYPRWM_SETUP_FILE" ] && [ ! -L "$HYPRWM_SETUP_FILE" ]; then /usr/bin/shasum -a 256 "$HYPRWM_SETUP_FILE"; fi
    done
    exit 0
fi
printf '%s\n' '[1/7] Checking the real host and build tools.'
[ "$(id -u)" -ne 0 ] || { printf '%s\n' 'Run setup as the desktop user, without sudo; setup names each privileged action.' >&2; exit 1; }
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || { printf '%s\n' 'HyprWM native setup requires an Apple Silicon Mac running natively as arm64.' >&2; exit 1; }
[ "$(/usr/bin/sw_vers -buildVersion)" = 25G241 ] || { printf '%s\n' 'Native setup requires the exact qualified macOS build 25G241.' >&2; exit 1; }
HYPRWM_SETUP_SIP=$(/usr/bin/csrutil status 2>&1) || { printf '%s\n' 'SIP status could not be verified; setup stopped.' >&2; exit 1; }
[ "$HYPRWM_SETUP_SIP" = 'System Integrity Protection status: disabled.' ] || { printf '%s\n' 'Fully disabled SIP is required. Enabled, custom/partial and unverified configurations are refused; setup does not change SIP.' >&2; exit 1; }
hyprwm_setup_clt_ready() {
    /usr/bin/xcode-select -p >/dev/null 2>&1 && /usr/bin/xcrun --find clang >/dev/null 2>&1 && /usr/bin/xcrun --find swift >/dev/null 2>&1 && /usr/bin/xcrun --find lldb >/dev/null 2>&1 && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ]
}
if ! hyprwm_setup_clt_ready; then
    printf '%s\n' 'Requesting Xcode Command Line Tools. Complete the macOS installer; setup waits for the tools to be usable.'
    /usr/bin/xcode-select --install || true
    HYPRWM_SETUP_WAIT=0
    until hyprwm_setup_clt_ready; do
        [ "$HYPRWM_SETUP_WAIT" -lt 3600 ] || { printf '%s\n' 'Command Line Tools are still unavailable after one hour; complete installation and rerun setup.' >&2; exit 1; }
        sleep 5
        HYPRWM_SETUP_WAIT=$((HYPRWM_SETUP_WAIT + 5))
        if [ $((HYPRWM_SETUP_WAIT % 30)) -eq 0 ]; then printf '%s\n' 'Waiting for the actual Command Line Tools installation to finish…'; fi
    done
fi
HYPRWM_SETUP_MISSING=
command -v git >/dev/null 2>&1 && git --version >/dev/null 2>&1 || HYPRWM_SETUP_MISSING=git
if ! HYPRWM_SETUP_PYTHON=$(hyprwm_setup_python); then HYPRWM_SETUP_MISSING="$HYPRWM_SETUP_MISSING python"; fi
if [ -n "$HYPRWM_SETUP_MISSING" ]; then
    HYPRWM_SETUP_BREW=$(command -v brew || true)
    [ -n "$HYPRWM_SETUP_BREW" ] || { printf '%s\n' "Homebrew is absent; install it from https://brew.sh, then rerun setup to install:$HYPRWM_SETUP_MISSING" >&2; exit 1; }
    # This is a fixed list selected above, never shell code from configuration.
    for HYPRWM_SETUP_PACKAGE in $HYPRWM_SETUP_MISSING; do "$HYPRWM_SETUP_BREW" install "$HYPRWM_SETUP_PACKAGE"; done
    HYPRWM_SETUP_PYTHON=$(hyprwm_setup_python) || { printf '%s\n' 'Python 3.9+ is still unavailable.' >&2; exit 1; }
fi
exec "$HYPRWM_SETUP_PYTHON" -B "$HYPRWM_SETUP_ROOT/scripts/setup_hyprwm.py" "$@"

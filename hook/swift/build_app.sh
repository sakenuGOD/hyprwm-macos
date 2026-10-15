#!/bin/zsh
# Reversible local menu-app package. Does not install, launch, or replace a WM.
set -euo pipefail
HYPRWM_PACKAGE_ROOT=${0:A:h}
HYPRWM_PROJECT_ROOT=${HYPRWM_PACKAGE_ROOT:h:h}
HYPRWM_OUTPUT=${1:-"$HYPRWM_PROJECT_ROOT/dist/HyprWM.app"}
if [[ "$HYPRWM_OUTPUT" != /* ]]; then HYPRWM_OUTPUT="$PWD/$HYPRWM_OUTPUT"; fi
if [[ -e "$HYPRWM_OUTPUT" || -e "$HYPRWM_OUTPUT.manifest.json" ]]; then
  print -u2 "Bundle already exists: $HYPRWM_OUTPUT. Choose a new output path to preserve it."
  exit 1
fi
HYPRWM_VERSION=${HYPRWM_APP_VERSION:-0.1.0}
HYPRWM_BUILD=${HYPRWM_APP_BUILD:-$(date +%Y.%m.%d)}
HYPRWM_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/hyprwm-app.XXXXXX")
trap 'rm -rf "$HYPRWM_STAGE"' EXIT
python3 "$HYPRWM_PACKAGE_ROOT/tools/package_app.py" --snapshot "$HYPRWM_PROJECT_ROOT" "$HYPRWM_STAGE/sources-before.json"
swift build --package-path "$HYPRWM_PACKAGE_ROOT" --configuration release
HYPRWM_BINARY="$HYPRWM_PACKAGE_ROOT/.build/release/hyprwm-swift"
HYPRWM_BUNDLE="$HYPRWM_STAGE/HyprWM.app"
mkdir -p "$HYPRWM_BUNDLE/Contents/MacOS" "$HYPRWM_BUNDLE/Contents/Resources"
cp "$HYPRWM_BINARY" "$HYPRWM_BUNDLE/Contents/MacOS/hyprwm-swift"
swift "$HYPRWM_PACKAGE_ROOT/tools/AppIcon.swift" "$HYPRWM_STAGE/AppIcon.iconset"
iconutil --convert icns "$HYPRWM_STAGE/AppIcon.iconset" --output "$HYPRWM_BUNDLE/Contents/Resources/AppIcon.icns"
python3 "$HYPRWM_PACKAGE_ROOT/tools/package_app.py" "$HYPRWM_PROJECT_ROOT" "$HYPRWM_BUNDLE" "$HYPRWM_VERSION" "$HYPRWM_BUILD" "$HYPRWM_STAGE/sources-before.json"
codesign --force --sign - --identifier dev.hyprwm.HyprWM "$HYPRWM_BUNDLE"
codesign --verify --strict "$HYPRWM_BUNDLE"
python3 "$HYPRWM_PACKAGE_ROOT/tools/package_app.py" --seal "$HYPRWM_BUNDLE" "$HYPRWM_STAGE/app.manifest.json"
mkdir -p "${HYPRWM_OUTPUT:h}"
mv "$HYPRWM_BUNDLE" "$HYPRWM_OUTPUT"
mv "$HYPRWM_STAGE/app.manifest.json" "$HYPRWM_OUTPUT.manifest.json"
print "Built $HYPRWM_OUTPUT (menu companion; daemon unchanged)"

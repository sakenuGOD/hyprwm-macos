# Contributing

Choose one concrete problem and check the [open issues](https://github.com/sakenuGOD/hyprwm-macos/issues).
Use small English commits and describe the behavior, reason and checks in your pull request.

## Build and test

Use macOS 14+, Xcode Command Line Tools with Swift 5.9+, Python 3 and Git:

```sh
./scripts/build-hyprwm
./scripts/test-hyprwm
git diff --check
```

The suite currently has [three known failures](https://github.com/sakenuGOD/hyprwm-macos/issues/21). Preserve their coverage while resolving the code/reference mismatches.

The test wrapper generates ignored layout scenarios from the Python reference.
Keep `hook/swift/REFERENCE_*.py`; they are test inputs, not runtime prototypes.
Run relevant checks once per affected change. Documentation needs valid commands and links.

## Source map and style

- `hook/swift/Sources/HyprCore`: layout, configuration, commands and focus/recovery policy.
- `hook/swift/Sources/hyprwm-swift`: system adapters, startup, menu and SwiftUI Settings.
- `hook/swift/Sources/CAX`, `CChan`, `CSnap`: Accessibility, shared channel and snapshots.
- `hook/src`, `hook/tools`: native WindowServer engine and its setup tools.
- `hook/swift/Tests`: layout, configuration, protocol and policy tests.

Follow the surrounding style. Keep changes small; avoid unrelated refactoring.
Use English UI text, help and comments. Preserve error handling and window-identity checks.

## Native changes

The engine is pinned to **macOS 26.7.1 (25G241), Apple silicon**, including framework
addresses and UUIDs. Do not change native code or its guards without that hardware,
an exact image build and real desktop checks. CI and Swift tests cannot verify it.
Keep generated OS code, native state files, dumps and private captures out of Git.
Never restart WindowServer, Dock or user apps, or change SIP, as a debugging shortcut.
Restore managed windows before stopping or replacing their owner.

## How to test animations

Use throwaway windows and observe opening, closing, moving, resizing and rapid bursts
of those actions. Check the first frame, mid-motion and landing for flashes, detached
borders, late content resizing and lost input. Retarget during motion and restore hidden
windows. Record the macOS build and affected app; remove private window content before sharing.
A green build verifies compilation; a clip and actual keyboard input verify desktop behavior.

## How the app bundle is built

`./install.sh` builds the runtime app and installs it without launching. Its engine
state stays outside the signed bundle; `--engine-state /absolute/path` selects it.
`python3 scripts/install_app.py package --root . --output dist/HyprWM-runtime.app --engine-state /absolute/path/to/engine.state`
packages without installing. Destinations must be new. `--diagnose` reads metadata without enabling tiling.

`zsh hook/swift/build_app.sh` builds a separate menu companion in `dist/HyprWM.app`;
pass a new output path to build another. It connects to an existing daemon.
Both packages use `dev.hyprwm.HyprWM` and an ad-hoc signature. The companion records
its checkout in `HyprWMSourceRoot`; keep that folder. `BuildManifest.json` records
version, SDK, source and executable hashes. `HYPRWM_APP_VERSION` and `HYPRWM_APP_BUILD`
override numeric version/build values. Developer ID signing and notarization are separate work.

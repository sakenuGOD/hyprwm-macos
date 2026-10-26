# Local HyprWM app packaging

The default runtime uses the native engine. `./install.sh` packages a daemon app and CLI without launching them; it does not supply a complete native Engine installation. Running it needs the already verified matching external `hook` resources, engine attachment and system prerequisites in the [README](../../README.md). Experimental Lite adapters are included in this source tree.

Build an ad-hoc signed macOS menu companion with a native menu, settings, icon and bundle identifier `dev.hyprwm.HyprWM`:

```sh
zsh hook/swift/build_app.sh
```

The default output is `dist/HyprWM.app`. The script refuses to overwrite an existing bundle or its sibling manifest. Choose a new path for another build:

```sh
zsh hook/swift/build_app.sh dist/HyprWM-next.app
```

Building does not launch a daemon, install a native engine or alter the running window manager. The bundle's default role is `--menu-only`: opening it connects to an existing daemon over the local control socket. The executable retains its explicit CLI modes.

```sh
dist/HyprWM.app/Contents/MacOS/hyprwm-swift --menu-only
```

Quit an older companion normally before opening another, to avoid duplicate menu icons. Do not run multiple daemons to test packaging. The companion’s **Quit HyprWM** action depends on the matching checkout’s `hook/lifecycle.py` and its process-ownership records. If those are missing or shutdown is not confirmed, it refuses to quit rather than assume restoration succeeded. The helper is included in this checkout; ownership records are created by its launch workflow. The installed daemon app uses its own restoration-aware shutdown coordinator.

## Distribution limits

`build_app.sh` packages the interface with the build checkout path recorded in its metadata. Moving/deleting that checkout can break config/runtime discovery. Rebuild after moving it, or provide `HYPRWM_HOOK` for an explicit CLI launch. This packaging command alone does **not** produce a standalone window manager installer, configure Engine prerequisites, notarize the app or publish a release. The separate source `./install.sh` flow builds a runtime app with bundled config resources and installed local CLI launchers; it does not use this menu-companion package as a standalone distribution. Its matching `./uninstall.sh` restores windows before removal. See the [README](../../README.md).

The deployment target comes from `Package.swift`, currently macOS 14. This is a build minimum, not proof that private native integrations work on every supported macOS version. The current menu uses AppKit; the settings window uses SwiftUI.

## Build receipts

`Contents/Resources/BuildManifest.json` records the version, SDK, UUID and SHA-256 hashes of the source binary and inputs. The sibling `dist/HyprWM.app.manifest.json` also records the hash of the final signed executable, because signing changes its bytes. The icon is drawn by `tools/AppIcon.swift` with AppKit vector paths. The script verifies its ad-hoc signature before moving the result to the selected output path.

`HYPRWM_APP_VERSION` and `HYPRWM_APP_BUILD` override the app's numeric Apple version/build fields. The default version is `0.1.0`; the default build is the build date. Developer ID signing and notarization require a separate release process.

## Runtime bundle with an external Engine receipt

`python3 scripts/install_app.py package --root . --output dist/HyprWM-runtime.app
--engine-state /absolute/path/to/anim4.state` creates the runtime bundle without
installing, initializing configuration or launching it. Run this as one command.
The recorded file remains outside the signed app; updates through `./install.sh`
preserve a previously selected receipt. `HYPRWM_ENGINE_STATE` can override its
location. Native validation and the startup canary remain mandatory on actual
daemon startup. `--diagnose` reports read-only metadata and does not run that canary.

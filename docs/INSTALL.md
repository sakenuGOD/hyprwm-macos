# Install HyprWM

## Before you start

HyprWM is experimental. Tiling requires a native engine inside WindowServer,
**macOS 26.7.1 (25G241), Apple silicon, fully disabled SIP,
and admin rights**. A failure can disrupt the desktop. Save your work first.
Building the Swift app only needs macOS 14+, Xcode Command Line Tools, Swift 5.9+,
Python 3 and Git. Before building, check `sw_vers -productVersion`,
`sw_vers -buildVersion` and `uname -m`: they must print `26.7.1`, `25G241` and `arm64`.
Keep the cloned folder; the installed app still uses it. Never share generated
native images or state files, reuse them on another Mac, or commit them to Git.

## Disable SIP in Recovery

The native engine needs debugger access to WindowServer, which SIP protects.
The supported setup is **SIP fully disabled**. Disabling only debugging
restrictions has not been verified for this engine. HyprWM's tools never change
SIP for you. To follow Apple's full-disable procedure, shut down your Apple
silicon Mac, hold its power button until startup options appear, choose
**Options → Continue**, then open **Utilities → Terminal** in Recovery.
Run `csrutil disable`, restart, then run `csrutil status` in a normal Terminal.
It must report `System Integrity Protection status: disabled.` before native setup.
This reduces system protection; re-enable it with `csrutil enable` in Recovery
and restart when you stop experimenting. See [Apple's SIP instructions](https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection),
[protected task access](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.debugger)
and [Apple silicon Recovery steps](https://support.apple.com/102518).

## Build and install the app

```sh
git clone https://github.com/sakenuGOD/hyprwm-macos.git
cd hyprwm-macos
./install.sh
```

This builds an ad-hoc signed app in `~/Applications/HyprWM.app` and CLI wrappers in
`~/.local/bin`. It preserves configuration and leaves the app stopped.

## Native engine

On a first install there is nothing to stop. If HyprWM is already running, quit
it normally through its menu, and quit any separate HyprWM menu companion before
preparation or activation. Do not run another manager during these steps.
Build as your normal user:

```sh
HYPRWM_NATIVE_WORK=$(mktemp -d "${TMPDIR:-/tmp}/hyprwm-native.XXXXXX")
python3 hook/tools/build_native.py --output-dir "$HYPRWM_NATIVE_WORK/image"
```

This builds the engine and checks its image. Prepare a disabled engine in the current WindowServer:

```sh
sudo /usr/bin/python3 hook/tools/prepare_native.py --image-dir "$HYPRWM_NATIVE_WORK/image" --owner-uid "$(id -u)"
```

Set the first variable below to the **printed** `prepared.json` path. Activate it and select its state for the app:

```sh
HYPRWM_NATIVE_PREPARED=/private/tmp/hyprwm-native-prepared-REPLACE/prepared.json
HYPRWM_NATIVE_STATE="$HOME/.local/share/hyprwm/native/engine.state"
sudo /usr/bin/python3 hook/tools/activate_native.py activate --prepared "$HYPRWM_NATIVE_PREPARED" --engine-state "$HYPRWM_NATIVE_STATE" --owner-uid "$(id -u)" --control-socket /tmp/hyprwm.ctl
./install.sh --engine-state "$HYPRWM_NATIVE_STATE"
```

Keep the printed **state file from activation** and its rollback command.
Set up the keyboard helper below, then open `~/Applications/HyprWM.app`, grant
Accessibility, and check `~/.local/bin/hyprwmctl status`.
Startup checks the build, framework identities, channel and placement before enabling tiling.
An unsupported build or refused task access leaves tiling off. Do not bypass a refusal.
For a custom `HYPRWM_CTL`, pass the same absolute path as `--control-socket`.
Updates preserve the selected engine state; `HYPRWM_ENGINE_STATE` can override it explicitly.

## Global keyboard shortcuts

`install.sh` does not build or start the keyboard helper. For global focus and
move shortcuts, run this from the cloned folder as your normal user:

```sh
clang -fobjc-arc -framework Carbon -framework AppKit -o hook/keys/hyprkeys hook/keys/hyprkeys.m
test -e hook/config/hypr_cfg.json || cp hook/config/portable-defaults.json hook/config/hypr_cfg.json
python3 hook/keys/binds.py
./hook/keys/hyprkeys
```

The second command supplies defaults only when no configuration is present.
Existing configuration is preserved; newer custom Lua files require `lua` when
generating shortcuts. The helper reads `/tmp/hyprkeys.json` and connects to
`/tmp/hyprwm.ctl`; it currently uses only that default socket.

Keep this Terminal open, and open HyprWM.app from Finder or another Terminal.
Use **Control–Option–arrows** to focus and **Control–Option–Shift–arrows** to move
windows. Stop the helper with **Control–C** in its Terminal before starting another
copy. Regenerate bindings and restart it after a reboot.

The helper uses macOS's public hotkey API and needs neither Accessibility nor
Input Monitoring permission. The app needs **System Settings → Privacy & Security
→ Accessibility → HyprWM** enabled. Shortcuts reserved by macOS or another app may
be unavailable; inspect the helper's Terminal output and **Settings → Keyboard
Shortcuts**.

## After a reboot

Repeat preparation and activation for the new WindowServer, using fresh runtime state.
You can reuse the built image on the same supported build. Repeat `./install.sh --engine-state …`
if the selected state path changes. Never replay old addresses or edit a state file to force acceptance.

## Autostart (optional)

Autostart requires reviewed engine and workspace images, the release executable,
and the keyboard helper. It installs a root LaunchDaemon and user LaunchAgent:

```sh
python3 hook/tools/build_workspaces.py --output-dir /absolute/private/workspace-build
python3 scripts/install_autostart.py inspect --root /absolute/reviewed/checkout
sudo /usr/bin/python3 -S scripts/install_autostart.py install \
  --uid "$(id -u)" --root /absolute/reviewed/checkout --hook /absolute/existing/hook \
  --manager-executable /absolute/canonical/release/hyprwm-swift --manager-sha256 REVIEWED_MANAGER_SHA256 \
  --toolgraph-sha256 REVIEWED_TOOLGRAPH_SHA256 \
  --native-image /absolute/private/native-image/probe-eh.dylib --native-sha256 REVIEWED_NATIVE_IMAGE_SHA256 \
  --workspace-image-dir /absolute/private/workspace-build
python3 scripts/install_autostart.py status --uid "$(id -u)"
```

Replace paths and hashes with reviewed values; `inspect` supplies `toolgraph_sha256`.
Use a resolved executable path, not Swift's `.build/release` symlink. Inputs must be
owned by root or your user, with no symlinks or shared write access. The workspace
builder includes the process-identity helper. For older builds, supply both
`--identity-helper /absolute/helper.dylib` and `--identity-sha256 REVIEWED_HELPER_SHA256`.
To adopt an existing session, add `--adopt-activation /private/tmp/.../activation.json`
and, if its workspace bridge is active, `--adopt-workspaces /private/tmp/hyprwm-workspace-bootstrap-STATE`.
Without adoption, stop every manager before setup. Keep a separately installed toolbar service.
An interrupted native attempt stops automatic retries; retain its state for recovery.
Check actual tiling and shortcuts after your next reboot; installation alone cannot verify them.

### Native workspace switching

With one verified daemon running, publish the separately built workspace bridge:

```sh
sudo /usr/bin/python3 -I -S hook/tools/bootstrap_workspaces.py --image-dir /absolute/private/workspace-build --owner-uid "$(id -u)" --manager-executable /absolute/path/to/running/hyprwm-swift --manager-sha256 APPROVED_EXECUTABLE_SHA256 --replace-stale
```

Use the actual executable hash and canonical path. Add `--control-socket /absolute/socket`
for a custom socket. Keep the printed state directory. To resume an interrupted setup,
replace `--image-dir …` with `--resume /private/tmp/hyprwm-workspace-bootstrap-STATE`
and keep the approved manager arguments. A changed Dock or WindowServer is refused.
`--replace-stale` preserves a current Dock session. The raw socket command `workspace N`
selects an existing ordinary desktop; check `workspace_public.acknowledged` and `space`
in status before treating a queued reply as complete. The shell CLI wrapper does not expose it.

## Updating

Save your configuration, current executable and its SHA-256 before updating.
For a simple update, restore windows, quit through the menu, update the checkout,
run `./install.sh`, and reopen the app. Keep the same engine-state selection.
For an update that preserves hidden windows, request `./scripts/hyprwmctl handover`.
Continue only after `handover ready: state preserved; terminate this exact process with SIGHUP`.
Verify that daemon's PID, start time and executable, send SIGHUP only to it, and wait for exit.
Replace the executable atomically and restart in the same user/Accessibility context,
with the same hook, state and socket paths and `HYPRWM_ADOPT_ENGINE=1`.
Do not run two native-channel writers. Recheck status, hidden windows and actual input.
If startup refuses, keep the saved state and restore the old executable and environment.

## Rollback and uninstall

```sh
~/.local/bin/hyprwmctl restore-all
./uninstall.sh
sudo /usr/bin/python3 -S scripts/install_autostart.py remove --uid "$(id -u)"
```

Only run the autostart removal command if you installed it. Pending restoration
preserves the app and state; let it finish before deleting anything. Native removal
also needs a completed manager handover and the state file from activation:

```sh
sudo /usr/bin/python3 hook/tools/activate_native.py retire --receipt /private/tmp/REPLACE/activation.json
```

Use the exact rollback command printed by activation. Retained engine mappings stay
in the running WindowServer. Do not restart WindowServer, Dock or applications to recover.
Autostart removal retains its protected code and recovery files. Re-enable SIP in Recovery when done.

## Optional: toolbar and application menus

The native toolbar is unfinished and off by default. See [its source notes](../hook/toolbar/README.md).
Build with `python3 hook/toolbar/build.py --output /absolute/new/toolbar-build`.
Stage disabled with `python3 hook/toolbar/manage.py prepare --source /absolute/new/toolbar-build --settings-source /absolute/reviewed/toolbar-paths.json`;
that file must name canonical `forest_path` and `wm_executable` values.
Existing installs need their own migration; session `configure` and `enable` require reviewed local settings and checks.
Use `python3 hook/toolbar/manage.py status` or `python3 hook/toolbar/manage.py disable` for an existing session.

The optional application-menu helper changes menus and lets eligible AppKit windows
request a tile before display. An application's first window can still appear too early.
Keep menu-bar autohide disabled. Build and install, or remove, with:

```sh
zsh hook/active/build.sh
sudo /Library/Developer/CommandLineTools/usr/bin/python3 -I -S hook/active/install-menu-policy.py install --uid "$(id -u)"
sudo /Library/Developer/CommandLineTools/usr/bin/python3 -I -S hook/active/install-menu-policy.py uninstall --uid "$(id -u)"
```

Removal restores menus without restarting apps; recovery files stay under
`/Library/Application Support/HyprWM/menu-policy-<uid>`. The separate [appearance adapter](../hook/toolbar/appearance/README.md) is inactive.

# Install HyprWM

## Before you start

HyprWM is experimental. Tiling runs a native engine inside WindowServer and needs
**macOS 26.7.1 (25G241), Apple silicon, fully disabled SIP and admin rights**.
A failure can disrupt the desktop. Save your work first.

Check the Mac before building:

```sh
sw_vers -productVersion
sw_vers -buildVersion
uname -m
csrutil status
```

The first three must print `26.7.1`, `25G241` and `arm64`. Other builds, Rosetta and
enabled or partially disabled SIP are refused. Building only the Swift app needs
macOS 14+, Xcode Command Line Tools, Swift 5.9+, Python 3 and Git.

Never share generated native images or state files, reuse them on another Mac,
or commit them to Git. Keep the checkout for setup, updates and manual recovery.

## Disable SIP in Recovery

The native engine needs debugger access to WindowServer, which SIP protects.
The supported setup is **SIP fully disabled**. Disabling only debugging
restrictions has not been verified for this engine. HyprWM never changes SIP.

Shut down the Apple silicon Mac, hold its power button until startup options
appear, choose **Options → Continue**, then open **Utilities → Terminal** in
Recovery. Run `csrutil disable`, restart, and run `csrutil status` in a normal
Terminal. It must report `System Integrity Protection status: disabled.`

This reduces system protection. Re-enable it with `csrutil enable` in Recovery and
restart when you stop using the native engine. See [Apple's SIP instructions](https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection),
[protected task access](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.debugger)
and [Apple silicon Recovery steps](https://support.apple.com/102518).

## Recommended setup

Run as your desktop user, without putting `sudo` before setup:

```sh
git clone https://github.com/sakenuGOD/hyprwm-macos.git
cd hyprwm-macos
./setup.sh
```

If Git opens the Command Line Tools installer during cloning, finish installation
and repeat the clone. Setup requests missing Command Line Tools and waits until
clang, Swift, LLDB and the SDK work. If Git or Python 3.9+ is still unavailable,
it installs the missing package through an existing Homebrew. If Homebrew is also
absent, setup stops with instructions. Default shortcuts do not need Lua.

Setup checks the host and conflicting window managers; builds and installs the app;
builds or validates the local native and workspace images; prepares and activates
the native engine, or keeps a verified active session; installs the keyboard
helper; waits for Accessibility; and installs automatic startup services.
It supplies paths and SHA-256 values itself. Each privileged action explains its
purpose before requesting `sudo`.

A first install has no HyprWM session to stop. Setup preserves a verified running
HyprWM session and its configuration. Conflicting window managers receive a normal
quit or service-stop request only after confirmation; none is forcibly killed.
An unrecognized installation or incomplete native attempt is retained for recovery.

| Option | Effect |
| --- | --- |
| `./setup.sh --dry-run` | Inspect the host, existing files and planned actions without installing, requesting permissions or starting services. |
| `./setup.sh --yes` | Accept normal shutdown of conflicting window managers. `sudo` and macOS permission dialogs remain interactive. |
| `./setup.sh --no-open` | Suppress explicit app and Settings opening. Accessibility must already be granted; requested automatic startup services still start their backend. |
| `./setup.sh --no-autostart` | Skip the native-session LaunchDaemon and backend LaunchAgent. The keyboard LaunchAgent is still installed. Use the manual fallback to start future sessions. |

## Permissions and keyboard shortcuts

Enable **HyprWM** in **System Settings → Privacy & Security → Accessibility**.
Setup opens the pane and waits for the actual permission state. If access is still
missing after ten minutes, grant it and rerun setup.

Global shortcuts use Carbon's `RegisterEventHotKey`. The keyboard helper needs
neither Accessibility nor Input Monitoring. The app needs Accessibility to manage
windows. The optional shortcut recorder in Settings may need keyboard access under
Input Monitoring; that permission is separate from running existing shortcuts.

Defaults include **Control–Option–arrows** for focus,
**Control–Option–Shift–arrows** for move, **Control–Option–F** for floating and
**Option–F** for fullscreen layout. **Control–Option–P** pauses or resumes tiling
independently of the helper. See **HyprWM Settings → Keyboard Shortcuts** for
registration status and active bindings. A macOS shortcut or another app can
reserve a chord.

Successful setup checks the running manager, keyboard registrations and default
services, then prints `Tiling:ON, hotkeys:ON, autostart:ON`. Check actual window
focus and movement as well; a responding socket alone cannot show that input works.

## Automatic startup and manual fallback

Default setup installs these services:

| Service | Purpose |
| --- | --- |
| `dev.hyprwm.native-session.<uid>` root LaunchDaemon | Prepare the engine for the current WindowServer and coordinate the native workspace bridge. |
| `dev.hyprwm.backend.<uid>` user LaunchAgent | Start or adopt the user's HyprWM backend when the native session is ready. |
| `org.hyprwm.keyboard` user LaunchAgent | Generate missing default bindings and run the Carbon keyboard helper. |

They are designed to start tiling and shortcuts at login after reboot. Setup verifies
the current session; it does not reboot to verify the next login. There is normally
no manual native preparation after reboot. If automatic startup fails, inspect:

```sh
python3 scripts/install_autostart.py status --uid "$(id -u)"
python3 scripts/install_keyboard.py status
~/.local/bin/hyprwmctl status
```

Use `./scripts/hyprwm-up` only as a manual fallback. It checks the real host and saved
images, keeps a verified active session, or requests startup through the existing
services. It refuses an unconfirmed native attempt rather than repeating it.
If you chose `--no-autostart`, the same fallback starts the next session manually.
Read the first refusal and retain all state if recovery is required.

The installer verifies cached sources, output files and the local macOS build
before reuse. An unsupported update leaves tiling off. Do not edit state files or
reuse addresses to bypass a refusal.

## Files and logs

| Path | Contents |
| --- | --- |
| `~/Applications/HyprWM.app` | Installed app and bundled resources. |
| `~/.local/bin/hyprwm`, `~/.local/bin/hyprwmctl` | Command wrappers. |
| `~/.config/hyprwm/hyprwm.conf` | Your text settings; preserved by setup and removal. |
| `~/Library/Application Support/HyprWM/setup` | Local setup state and reusable build images. |
| `/Library/Application Support/HyprWM/native-session-<uid>` | Protected automatic-startup code, state and recovery files. |
| `~/Library/Application Support/HyprWM/keyboard` | Keyboard helper and registration status. |
| `~/Library/Application Support/HyprWM/lifecycle.json` | User-service process state. |
| `~/Library/Application Support/HyprWM/runtime` | Installed app's persistent window state. |
| `/tmp/hyprwm.log` | Daemon startup and runtime log. |
| `~/Library/Logs/HyprWM/keyboard.log` | Keyboard helper log. |

Read the native service log with:

```sh
sudo tail -n 80 "/Library/Application Support/HyprWM/native-session-$(id -u)/runtime/native-service.log"
```

Use `tail -n 80 /tmp/hyprwm.log` for the daemon and
`tail -n 80 "$HOME/Library/Logs/HyprWM/keyboard.log"` for shortcuts. Remove private
paths, window titles and other personal data before sharing logs.

## Manual setup without automatic startup

For a complete setup that you start manually after reboot, use:

```sh
./setup.sh --no-autostart
```

`install.sh` remains an app-only installer. It builds an ad-hoc signed app and CLI
wrappers, preserves configuration and does not launch the app or install the global
keyboard helper. The following low-level steps are for a **fresh native session**.
If HyprWM is already running, quit it and any separate menu companion normally
before using these steps. Do not run them against an existing native engine;
use setup to keep that session instead.

```sh
HYPRWM_NATIVE_WORK=$(mktemp -d "${TMPDIR:-/tmp}/hyprwm-native.XXXXXX")
python3 hook/tools/build_native.py --output-dir "$HYPRWM_NATIVE_WORK/image"
HYPRWM_NATIVE_PREPARATION=$(sudo -H /Library/Developer/CommandLineTools/usr/bin/python3 -E -S scripts/setup_hyprwm.py --prepare-native-json --image-dir "$HYPRWM_NATIVE_WORK/image" --uid "$(id -u)")
HYPRWM_NATIVE_PREPARED=$(printf '%s\n' "$HYPRWM_NATIVE_PREPARATION" | python3 -c 'import json,sys; print(json.load(sys.stdin)["prepared"])')
HYPRWM_NATIVE_STATE="$HOME/.local/share/hyprwm/native/engine.state"
sudo -H /Library/Developer/CommandLineTools/usr/bin/python3 -E -S hook/tools/activate_native.py activate --prepared "$HYPRWM_NATIVE_PREPARED" --engine-state "$HYPRWM_NATIVE_STATE" --owner-uid "$(id -u)" --control-socket /tmp/hyprwm.ctl
./install.sh --engine-state "$HYPRWM_NATIVE_STATE"
python3 scripts/install_keyboard.py install
open "$HOME/Applications/HyprWM.app"
```

The preparation wrapper returns the actual `prepared.json` path as JSON; no path
needs editing. Preparation needs `sudo` to attach to WindowServer and activation
needs it to publish that exact engine. Keep the state file and rollback command
printed by activation. Grant app Accessibility and check `~/.local/bin/hyprwmctl status`.
This block does not install the native workspace bridge or native login services;
`./setup.sh` supplies those automatically.

To run only the keyboard helper in a Terminal instead of its LaunchAgent, stop
your existing helper normally first, then build and run:

```sh
clang -fobjc-arc -framework Carbon -framework AppKit -o hook/keys/hyprkeys hook/keys/hyprkeys.m
python3 hook/keys/binds.py --source hook/config/portable-defaults.json --missing-only
./hook/keys/hyprkeys
```

Leave the Terminal open and press **Control–C** there to stop the helper. Do not run
a second copy alongside the installed keyboard service. Default generation needs
no Lua; explicitly using `HYPR_HOME` for a custom Lua configuration requires `lua`.

## Updating

A live session is preserved by setup; rebuilding does not replace its running app.
If only the startup scripts changed, setup can replace the two owned supervisors
while keeping the current engine, app and keyboard helper running. It verifies the
same manager, Python, native images and workspace session, and retains a protected
backup. A changed executable or image, or an unfinished native attempt, is refused.
Save your work and configuration before replacing an existing installation.
Restore windows and remove its owned services and app, then update and set up again:

```sh
~/.local/bin/hyprwmctl restore-all
./uninstall.sh
git pull --ff-only
./setup.sh
```

Continue only after restoration and removal succeed. Configuration, state and app
backups are preserved. An unfinished restoration must finish before an update.

Advanced updates that preserve hidden windows use `./scripts/hyprwmctl handover`.
Continue only after `handover ready: state preserved; terminate this exact process with SIGHUP`.
Verify that daemon's PID, start time and executable, send SIGHUP only to it, and wait
for exit. Replace the executable atomically and restart with the same hook, state,
socket and Accessibility context, with `HYPRWM_ADOPT_ENGINE=1`. Do not run two
writers to the native channel. If startup refuses, restore the saved executable
and environment and keep the state.

## Rollback and uninstall

```sh
~/.local/bin/hyprwmctl restore-all
./uninstall.sh
```

Removal stops the owned native and user login services before removing the app,
CLI wrappers and keyboard service. It explains the privileged service-removal
action before `sudo`. Configuration, app backups and recovery files are retained.
Pending restoration keeps the installation in place; let it finish before deleting
anything. A separate toolbar service keeps its own lifecycle.

For a manual native setup, use the exact rollback command printed by activation.
It needs a completed manager handover and the state file from activation. Engine
mappings remain in the running WindowServer. Do not restart WindowServer, Dock or
applications to recover. Re-enable SIP in Recovery and restart when finished.

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

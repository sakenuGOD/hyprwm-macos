# Deploying and rolling back HyprWM

The Swift app and the WindowServer engine have separate lifecycles. Build and
install the app without replacing a running native engine. A source checkout
does not include a complete, qualified native engine installer.

## Before deployment

Build with `./scripts/build-hyprwm`. Run the existing checks affected by the
change once, then preserve the installed executable and its SHA-256. Keep the
current configuration, window-state ledger and lifecycle record. Check live
status: the supported macOS fingerprint must be verified, engine errors must
be zero, and native/configure workers must be idle.

`./install.sh` installs the user-local app and CLI wrappers without launching
them or replacing the native engine. It preserves existing configuration. On
a machine that already has a qualified native installation, start the daemon
with `./scripts/hyprwm` and inspect `./scripts/hyprwmctl status`. Accessibility
permission is required. An unsupported platform stays unverified with tiling
disabled.

## Updating a running daemon

Use the daemon's authenticated local command socket to request `handover`.
Continue only after the exact reply `handover ready: state preserved; terminate
this exact process with SIGHUP`. A pending reply means workers are still active;
leave the current process running. This operation preserves hidden windows and
arms a one-use state transfer. It is different from `restore-all`.

Recheck the old daemon's PID, kernel birth and executable immediately before
sending SIGHUP to that process. Reap it if you launched it as your own child,
and wait for the kernel process to disappear. A zombie still prevents handover
adoption. Replace the
executable atomically, then launch the new daemon in the same authenticated
user session with the same hook, state and socket paths. The launch context must
have Accessibility access; a headless helper may have a different permission
identity even under the same UID. For an existing engine,
retain `HYPRWM_ADOPT_ENGINE=1`; preserve the previous menu configuration and
shortcut helper. Do not start a second writer on the native channel.

After startup, inspect the new daemon identity, compatibility status, engine
errors and the exact hidden-window set. Exercise the changed user scenario on
the real desktop. A successful build or channel acknowledgement alone is not
desktop acceptance. A daemon replacement invalidates identity-bound workspace
permissions; qualify them for the new process through the existing workspace
backend rather than editing an old permission file.

## Rollback

If the new daemon is healthy enough to answer, request its own handover and
stop only its verified identity. Restore the saved executable atomically and
launch it with the original environment. Let the saved handover ledger drive
adoption; do not overwrite it with an older copy of hidden-window state. Verify
the restored daemon and the current window set again.

If startup qualification refuses before the WM begins, preserve its refusal
and the unconsumed handover record, then restore the previous executable. Never
recover an app update by restarting WindowServer, Dock, loginwindow or an
application that owns user documents.

## After a reboot or WindowServer replacement

A new WindowServer invalidates the old native addresses, channel ownership and
identity-bound workspace permissions. Keep the previous presentation module
disabled until a fresh, qualified bootstrap has established a new channel and
verified the new process. Reuse the accepted code image only with new runtime
state; do not replay an old rollout receipt or copy its window IDs.

If configured shortcut overrides use the legacy native watcher, generate its
binding document before starting the daemon. The temporary document may be absent
after a reboot, and the daemon applies overrides during startup. Starting the watcher
first through the existing lifecycle helper supplies that baseline. The public
source installer still does not provide the complete Engine bootstrap workflow.

## Cropped content navigation

The native viewport extension provides `pan left|right|up|down|reset` and the
**Pan Cropped Content** menu. It moves live content at its original scale inside
the existing tile. The tile allocation and neighboring windows stay in place.
It requires a qualified native image advertising the viewport capability;
older engines refuse the command. The source installer does not bootstrap that
native image. Reset/drop live viewports before stopping or replacing the engine.

## Native presentation updates

Every new native image needs whole-image qualification and fresh process birth,
executable, framework UUID, image and channel checks before attachment. Preserve
the previous mapped code and a working native-window fallback. Do not use the
legacy `build_anim4.sh` recipe as an installer for the current C++/assembly
presentation path. Its complete effects package and qualification workflow are
not distributed by the source installer.

The movement contract is in [MOTION.md](docs/MOTION.md); current implementation
coverage is in [ANIMATION_AUDIT.md](docs/ANIMATION_AUDIT.md).

## Application menus

The optional application-menu policy hides the native application name and
its menus on the left. The Apple menu, workspace panel and status items remain
visible. It preserves application shortcuts and window title bars. Keep macOS
menu-bar autohide disabled; this policy does not use autohide.

On the qualified Apple Silicon installation, build and install it with the
Command Line Tools installed:

```sh
zsh hook/active/build.sh
sudo /Library/Developer/CommandLineTools/usr/bin/python3 -I -S \
  hook/active/install-menu-policy.py install --uid "$(id -u)"
```

The root-owned helper follows the authenticated HyprWM daemon and discovers
regular applications, including later launches. It loads a reversible menu-only
module into each eligible user application. Existing debugger and client code
loading permissions are required; a refused application keeps its native menus.
Failed loads are bounded and are not repeatedly attached to. The helper restores
menus when HyprWM is paused, stops responding, or the policy is uninstalled:

```sh
sudo /Library/Developer/CommandLineTools/usr/bin/python3 -I -S \
  hook/active/install-menu-policy.py uninstall --uid "$(id -u)"
```

Uninstall disables the service and restores menu entries without restarting
applications or unloading code from their processes. The installed recovery
files remain in `/Library/Application Support/HyprWM/menu-policy-<uid>`.

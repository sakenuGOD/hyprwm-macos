# Deploying and rolling back HyprWM

The Swift app and the WindowServer engine have separate lifecycles. Build and
install the app without replacing a running native engine. The checkout includes the native build, preparation, publication and inverse tools. Native setup is explicit and session-bound; installing the app preserves an existing engine.

## Native Engine first setup

This developer setup is qualified for macOS build `25G241` on Apple silicon.
It requires Xcode Command Line Tools, Python 3 and existing authorization to
access the WindowServer task. An unsupported build or framework identity is
refused. The tools do not change SIP, NVRAM or boot policy. If macOS denies
attachment, stop at that refusal and keep native window management.

Use this first-setup path with no HyprWM daemon, menu companion or native installation already
running. Follow the update procedure below for an existing installation.
Build as your normal user; keep the generated image outside the checkout:

```sh
HYPRWM_NATIVE_WORK=$(mktemp -d "${TMPDIR:-/tmp}/hyprwm-native.XXXXXX")
python3 hook/tools/build_native.py --output-dir "$HYPRWM_NATIVE_WORK/image"
sudo /usr/bin/python3 hook/tools/prepare_native.py \
  --image-dir "$HYPRWM_NATIVE_WORK/image" --owner-uid "$(id -u)"
```

Preparation prints a root-private `prepared.json` path. It allocates a fresh,
disabled context, registers and checks every unwind entry, and verifies the
framework and process identities. Set `HYPRWM_NATIVE_PREPARED` to that printed
path, then publish it:

```sh
HYPRWM_NATIVE_PREPARED=/private/tmp/hyprwm-native-prepared-REPLACE/prepared.json
HYPRWM_NATIVE_STATE="$HOME/.local/share/hyprwm/native/engine.state"
sudo /usr/bin/python3 hook/tools/activate_native.py activate \
  --prepared "$HYPRWM_NATIVE_PREPARED" \
  --engine-state "$HYPRWM_NATIVE_STATE" --owner-uid "$(id -u)" \
  --control-socket /tmp/hyprwm.ctl
./install.sh --engine-state "$HYPRWM_NATIVE_STATE"
```

The publisher creates missing user-owned state directories with mode `0700`
and the shared root-owned channel directory with mode `1777`. Existing unsafe
paths are refused and existing directory permissions are preserved. Keep the
printed activation receipt: its `retire --receipt` command is the guarded
inverse. It requires a completed manager handover and never restarts an owner
application or the desktop session. Retained mappings and unwind registrations
are not freed from a running WindowServer.

For a custom `HYPRWM_CTL`, pass its absolute path with `--control-socket`;
retirement reads that path from the activation receipt. Publication refuses
any running `hyprwm-swift` process across all users, including menu companions,
even if its socket is absent. Keep that executable name. These are preflight
checks; do not launch a manager concurrently with native publication.

Start the installed HyprWM app and grant Accessibility access. Startup checks
the native identity, channel and an owned placement canary before enabling
tiling. A native installation belongs to one WindowServer generation. A reboot
or WindowServer replacement invalidates it; preserve the refusal and prepare a
new qualified session. Never replay old addresses, copy a receipt to another
Mac, or put generated OS code, receipts and private captures in Git.

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

## Selecting an existing Engine installation

An installed app keeps immutable configuration inside its signed bundle. Its
mutable native Engine receipt stays outside that bundle. Select the receipt
from an existing qualified installation when installing:

```sh
./install.sh --engine-state /path/to/native/hook/anim4.state
```

Updates preserve this selection when the option is omitted. An explicit
`HYPRWM_ENGINE_STATE` overrides it at runtime. Source launches retain the
`HYPRWM_HOOK/anim4.state` fallback. An invalid explicit selection is refused;
startup still checks the native identity, platform, channel and owned canary.
For a clean machine, complete the native first-setup procedure above.

To create a signed runtime bundle without installing it, changing configuration
or launching another daemon:

```sh
./scripts/build-hyprwm
python3 scripts/install_app.py package --root . --output dist/HyprWM-runtime.app \
  --engine-state /path/to/native/hook/anim4.state
dist/HyprWM-runtime.app/Contents/MacOS/hyprwm-swift --diagnose
```

Packaging refuses an existing destination. `--diagnose` reads the selected
receipt and native metadata; it does not map the Engine for writing or perform
the startup canary. It cannot establish full startup qualification.

## Updating a running daemon

Request `./scripts/hyprwmctl handover` through the daemon's local command socket.
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

An existing native toolbar with relocated application menus keeps ownership of
their presentation. Its title button opens the original menu tree below the
bar. The helper preserves those original menu items and delegates hiding to
the toolbar's representation service; hiding the items themselves breaks that
dropdown. The toolbar service retains its own pause and removal lifecycle.

On the qualified Apple Silicon installation, build and install it with the
Command Line Tools installed:

```sh
zsh hook/active/build.sh
sudo /Library/Developer/CommandLineTools/usr/bin/python3 -I -S \
  hook/active/install-menu-policy.py install --uid "$(id -u)"
```

The root-owned helper follows the authenticated HyprWM daemon and discovers
regular applications, including later launches. It loads a reversible menu
module and enables the first-map client in each eligible user application. The
first-map client requests the tile before a new ordinary AppKit window is
ordered on screen, then hands its temporary native visibility lease to HyprWM.
Panels, sheets, modal windows and uncertain tab groups retain native handling.
Already visible windows are preserved. A new application's first window can
precede helper attachment; this does not guarantee every first frame or restore.
Existing debugger and client code
loading permissions are required; a refused application keeps its native menus.
Failed loads are bounded and are not repeatedly attached to. The helper restores
menus and releases first-map admission when HyprWM is paused, stops responding,
or the policy is uninstalled:

```sh
sudo /Library/Developer/CommandLineTools/usr/bin/python3 -I -S \
  hook/active/install-menu-policy.py uninstall --uid "$(id -u)"
```

Uninstall disables the service and restores menu entries without restarting
applications or unloading code from their processes. The installed recovery
files remain in `/Library/Application Support/HyprWM/menu-policy-<uid>`.

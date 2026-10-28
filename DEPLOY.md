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

## Qualified native-session autostart

`scripts/install_autostart.py` installs one root native-session LaunchDaemon and
one desktop-user backend LaunchAgent. It is an explicit native deployment for
the qualified build above. Keep the separately installed toolbar LaunchAgent;
this installer starts the existing lifecycle with `menu=True` to include its
Swift settings and Quit controls alongside the workspace toolbar. Build the Swift release executable,
the existing hotkey helper and the approved workspace images before installing.
It does not build code or alter SIP, boot policy or task-attachment permissions.

Review the service sources and record their identity before running root code:

```sh
python3 scripts/install_autostart.py inspect --root /absolute/reviewed/checkout
```

The result includes `toolgraph_sha256`. Pass that reviewed value explicitly,
along with the approved native linked-image SHA-256 and the exact canonical
manager executable SHA-256. The native image is the `probe-eh.dylib` produced
by the qualified native build; workspace images come from `build_workspaces.py`.
That normal-user builder also produces `ProcessIdentity.dylib` from the
unchanged, independently pinned public `managed_process_identity.c` source and
adds its hash to `workspace-images.json`. This arm64, ad-hoc-signed helper has
no constructors and depends only on libSystem. For an older workspace build,
pass a separately reviewed helper with both `--identity-helper /absolute/helper.dylib`
and `--identity-sha256 REVIEWED_HELPER_SHA256`. Installation freezes it under
`graph/identity/ProcessIdentity.dylib` and verifies its hash, Mach-O loading
behavior and signature; installation never compiles it as root.
All input paths must be canonical, owned by root or the desktop user, without
symlinks or shared write access. Use the resolved release executable path
instead of Swift's `.build/release` directory symlink.

```sh
sudo /usr/bin/python3 -S scripts/install_autostart.py install \
  --uid "$(id -u)" --root /absolute/reviewed/checkout \
  --hook /absolute/existing/hook \
  --manager-executable /absolute/canonical/release/hyprwm-swift \
  --manager-sha256 REVIEWED_MANAGER_SHA256 \
  --toolgraph-sha256 REVIEWED_TOOLGRAPH_SHA256 \
  --native-image /absolute/private/native-image/probe-eh.dylib \
  --native-sha256 REVIEWED_NATIVE_IMAGE_SHA256 \
  --workspace-image-dir /absolute/private/workspace-build
```

A running qualified session must be adopted explicitly instead of being
prepared again. Add `--adopt-activation /private/tmp/.../activation.json` and,
when the workspace bridge is already published,
`--adopt-workspaces /private/tmp/hyprwm-workspace-bootstrap-RECEIPT`.
Adoption checks the root receipts, exact current process births, approved native
image, state and channel publications, advancing timer, and completed workspace
lease. It performs no native attachment. Without adoption, no manager may be
running when the service prepares the first session.

The installer freezes the reviewed tools and images under the root-protected
`/Library/Application Support/HyprWM/native-session-UID/graph`. The configured
user hook and its configuration stay in place. At login the root service waits
for that console owner, an active display and a running canonical WindowServer.
Each new WindowServer birth gets a new private `engine.state` path. The user
service waits for root readiness for that exact birth, passes
`HYPRWM_ENGINE_STATE` explicitly and uses the existing lifecycle to start the
daemon only after two public C sysctl birth readings and two canonical
`proc_pidpath` readings match the ready WindowServer's exact PID, UID 88,
birth timestamp and executable. This retains the birth/executable fence when
macOS refuses cross-UID `proc_pidinfo` to the desktop user. The root native
supervisor keeps its existing process identity and running-state checks; the
helper is loaded only by the desktop user. The lifecycle starts the
approved daemon, hotkeys and Swift controls companion. The user supervisor
watches both daemon and controls process exits. An independent controls crash
restarts the missing companion through the existing lifecycle while preserving
the running daemon. On daemon departure it waits up to 30 seconds for the
lifecycle lock, then restarts only if the exact old ownership record remains.
The existing Quit action removes that record, so intentional Quit stays quit.
Unconfirmed departure ownership stops automatic restart and retains evidence.
The root service then waits for the verified
approved daemon and Dock before running the existing workspace bootstrap with
`--replace-stale`. A current Dock lease is preserved; an already completed
bootstrap must be adopted rather than installed twice.

Both jobs use `RunAtLoad` and `KeepAlive` after an unsuccessful exit, with a
30-second launchd throttle. Prerequisites have bounded startup waits. Once
ready, the supervisors block on kernel process-exit events instead of polling.
A durable marker precedes each native attempt. An interrupted or ambiguous
attempt is quarantined for that WindowServer birth and requires explicit
receipt-based recovery; launchd never retries an uncertain attachment. Old
native addresses are never replayed in a new WindowServer. Only an exact owned
old channel publication may be cleared after its original server has departed.

Inspect readiness and remove the owned services with:

```sh
python3 scripts/install_autostart.py status --uid "$(id -u)"
sudo /usr/bin/python3 -S scripts/install_autostart.py remove --uid "$(id -u)"
```

Removal first disables the two jobs, then uses the existing user lifecycle to
restore and drain the daemon and stop only its recorded helpers. With the same
WindowServer still alive, it runs the guarded native activation inverse. A
pending restore or uncertain native result preserves all runtime files and
receipts for recovery. Successful removal deletes only its verified launchd
plists; the protected code graph, audit receipts, retained native mappings and
workspace evidence remain available. The separate toolbar service keeps its
own restoration and removal procedure. Status and install acceptance alone do
not establish reboot behavior: verify readiness and actual tiling, shortcuts,
toolbar and workspace behavior after a user-authorized reboot/login.

## Restoring native workspace switching

The workspace bridge is separate from the WindowServer presentation engine.
After a Dock or desktop-session replacement, an old workspace lease is refused.
With one verified HyprWM daemon already running, build the constructor-free
bridge as the desktop user into a new directory outside this checkout:

```sh
python3 hook/tools/build_workspaces.py --output-dir /absolute/private/workspace-build
sudo /usr/bin/python3 -I -S hook/tools/bootstrap_workspaces.py \
  --image-dir /absolute/private/workspace-build --owner-uid "$(id -u)" \
  --manager-executable /absolute/path/to/running/hyprwm-swift \
  --manager-sha256 APPROVED_EXECUTABLE_SHA256 --replace-stale
```

Use the expected SHA-256 of the intended installed executable and its full
canonical path. The bootstrap checks the running socket peer, kernel code
identity and approved file bytes. `--replace-stale` only permits replacing a
lease whose exact previous Dock process has departed. It preserves a current
Dock lease; a successor daemon uses the existing consumer rebind instead.
For a custom command socket, also pass `--control-socket /absolute/socket`.

This operation is qualified only for build `25G241`, its reviewed Dock UUID,
and the image/helper digests pinned in the launcher. A different compiler or
SDK may produce an unapproved image: preserve that refusal; editing the build
manifest cannot authorize it. Task attachment must already be authorized.
The tool never restarts Dock, changes system security policy, creates a Space,
or switches desktops. It publishes only after native status and a verified
detach, retaining the previous lease under a private backup name.

Keep the printed root bootstrap receipt and retained image directory. For an
interrupted operation, use the same approved manager arguments with
`--resume /private/tmp/hyprwm-workspace-bootstrap-RECEIPT` instead of
`--image-dir`. Resume uses the original request and authenticated status;
it does not repeat a confirmed installation. A departed original manager may
be followed by its exact approved successor, with normal consumer rebind
required before switching. A changed Dock or WindowServer generation is
refused. Never edit PIDs, nonce values or receipts to bypass that refusal.

After publication, exercise an existing ordinary desktop through
`./scripts/hyprwmctl workspace N`, where N is its one-based catalog ordinal.
The queued reply is not completion: require `workspace_public.acknowledged`
and the expected current `space` in status, then return to the original
workspace. The configured keyboard bindings use this same command backend.

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
first through the existing lifecycle helper supplies that baseline. The app
installer does not run native setup; use the explicit **Native Engine first
setup** procedure above for the new session.

## Cropped content navigation

The native viewport extension provides `pan left|right|up|down|reset` and the
**Pan Cropped Content** menu. It moves live content at its original scale inside
the existing tile. The tile allocation and neighboring windows stay in place.
It requires a qualified native image advertising the viewport capability;
older engines refuse the command. Build and qualify that native image using
the tools above; installing the app alone preserves the existing engine.
Reset/drop live viewports before stopping or replacing the engine.

## Optional native toolbar

The checkout includes the workspace toolbar, original-menu representation,
crop controls and an optional owned session supervisor. Build the component
without launching or installing it:

```sh
python3 hook/toolbar/build.py --output /absolute/new/toolbar-build
```

The build produces source hashes, signed app/module outputs and unqualified
profiles. Menu relocation and workspace actions remain disabled. A build
receipt does not authorize enabling them or replacing an existing installation.
For a fresh runtime, `hook/toolbar/manage.py prepare --source
/absolute/new/toolbar-build --settings-source /absolute/reviewed/toolbar-paths.json`
stages a disabled installation. The owned settings source must name canonical
`forest_path` and `wm_executable` paths; optional IPC paths must match the
intended daemon. Existing toolbar, menu and ownership graphs are preserved and
require an explicit migration rather than fresh preparation.

Session `configure` requires an explicit owned configuration; `enable` requires
matching actual local evidence for original menu access, panel placement and
disable/restore. Menu enable also requires the qualified signed menu graph and
its separate external-v3 first-map owner. Installing the service does not
replace those gates. Inspect or disable an already configured session with:

```sh
python3 hook/toolbar/manage.py status
python3 hook/toolbar/manage.py disable
```

App updates and removal preserve a configured toolbar until its owned restore
and migration checks complete. Full clean-install enable, migration, active
cropped-content input, fullscreen switching and next-login behavior are not
established by this source publication. See the [component notes](hook/toolbar/README.md).

The [Telegram main-only appearance sources](hook/toolbar/appearance/README.md)
are a separate, inactive source export. They omit private controller templates,
authorization state and binaries; the public session does not load them.

## Experimental configure-stream source

`hook/configure-stream/` and its Swift/C readers are the C1 source candidate.
The path remains off by default, with no automatic loader or grant renewal.
No installer or autostart command above enables it. A receiver build or passing
policy checks does not qualify changed-frame behavior. Loading requires a
separately reviewed retained loader, exact current process/window bindings,
protected root grant and disposable native qualification. Keep existing native
fallbacks and do not treat source publication as permission to create grants or
activate C1. The [interface contract](hook/configure-stream/ConfigureStream.h)
records its identity and refusal requirements.

## Native presentation updates

Every new native image needs whole-image qualification and fresh process birth,
executable, framework UUID, image and channel checks before attachment. Preserve
the previous mapped code and a working native-window fallback. Do not use the
legacy `build_anim4.sh` recipe as an installer for the current C++/assembly
presentation path. The current C/C++/assembly sources and qualification tools
are included in the checkout under `hook/src`, `hook/effects` and `hook/tools`.
Generated OS code and session receipts stay outside the checkout and are not
included in the app bundle. Native replacement still requires a completed
manager handover, the exact inverse receipt and a freshly prepared context;
the app installer does not perform that transition.

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

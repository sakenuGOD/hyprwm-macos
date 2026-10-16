# HyprWM Swift package

This package contains the Swift window-manager daemon and native macOS menu.
Layout policy, configuration, commands, configure queues and event handling run
in Swift. Shared C/Objective-C bridges provide macOS and WindowServer access;
Python remains in development, build and diagnostic tools. The Swift executable
does not start a Python daemon.

The launch branch is Engine-only. Running it requires an already verified native
installation; building the package or installing the app does not supply that
installation. The separate `lite/2026-10-16` branch contains experimental Lite
adapters and has not passed its complete live acceptance gate. See the
[project README](../../README.md), [configuration reference](../../docs/CONFIG.md),
[API](../../docs/API.md) and [troubleshooting](../../docs/TROUBLESHOOTING.md).
Transparency remains unfinished, and full native blur is not implemented.
Technical protocols below describe source behavior and capability requirements,
not proof that every path has passed live verification.

## Build and check

Requirements: macOS 14 or later, Xcode Command Line Tools and Swift 5.9 or later.
Rebuilding a legacy Lua configuration cache also requires Lua.

```sh
cd hook/swift
swift build -c release
swift test
.build/release/hyprwm-swift --print-config
```

The executable reads `../config/hypr_cfg.json` as its base and applies the shared
text document, normally `~/.config/hyprwm/hyprwm.conf`. `HYPRWM_CONFIG` selects
another text file. Legacy `runtime.json` and `swift-runtime.json` can be migrated
when that document is absent; they are not the normal live editing surface.
An external development hook can use personal Lua dotfiles or
`../config/defaults/`; `HYPR_HOME` selects the Lua base. The installed app reads
its bundled base without rebuilding it. `--print-config` and `--layout` read
prepared configuration without a Lua rebuild.

## Native menu companion

These commands open a menu/interface in the desktop session:

```sh
.build/release/hyprwm-swift --menu-only
.build/release/hyprwm-swift --menu-only --show-settings
```

The menu provides pause/resume, restoration, retile/balance, settings, configuration
file/folder access, copied diagnostics and restoration-aware shutdown. Companion
commands go to the existing daemon through the control socket on a background
queue with timeouts; settings remain accessible while the daemon is unavailable.
The icon entrance respects Reduce Motion. Companion shutdown depends on the
matching development lifecycle helper and ownership records; it fails closed
when those are unavailable. The installed daemon has its own shutdown coordinator.
See [packaging](PACKAGING.md) for this distinction.

## Read-only diagnosis

```sh
.build/release/hyprwm-swift --diagnose
```

JSON includes the actual `AXIsProcessTrusted` result, snapshot stability,
Space ID/type, window count, usable area, channel ABI compatibility and available
daemon counters. This mode does not prompt for permissions, map the engine
channel, publish settings/geometry or inject code. It reads the channel header
through a file handle and uses socket `status` only as a connection/state check.
Its output omits window titles and content. The broader `doctor` command and
its permission/configuration report are documented in the [API](../../docs/API.md).

## Implemented policy and adapter contracts

- Dwindle trees, saved layout, Lua-base float rules, focus, hide/restore, close
  and the primary dispatchers run in Swift.
- One main-queue owner holds WM state. Per-application configure queues coalesce
  requests, cancel work on pause and reject stale replies.
- The ordinary movement path avoids stretching live content: it requests the
  final client size near the start, using `ax_size` for shrinking and final
  size/position together for growth to avoid AppKit's old-edge clamp. It avoids a
  second late AppKit resize. With `CH_CAP_TERMINAL_MOVE`, the C7 protocol moves
  the native position with the final transform reset (`F_MOVE_END`); the C6
  compatibility path uses one terminal native warp instead of a late AX move.
  Configured opening pop-in may still stretch. Actual first-map, close, content
  and landing defects remain separate live gates; this protocol is not a claim
  that every recorded trajectory is smooth.
- Shared horizontal/vertical dividers include multiple opposite-side neighbors.
  Accepted native sizes take priority over stale learned minima; `manual_ratio`
  persists in the tree. An outer-edge adjustment compensates the inner divider
  so the opposite neighbor stays put. The passive resize reader checks epoch,
  seqlock, phase and kernel birth. Its 20-field channel separates the immutable
  initial frame from accepted AppKit coordinates; DidResize/DidMove update them
  without AX IPC or a new frame write. The final frame survives release, and a
  new epoch invalidates the old session. A new addon still needs operator-led
  installation and live verification.
- A short throw swaps with the neighbor in the dominant direction. Threshold
  and axis ratio come from the shared text document's `drag` settings.
- Exact AX key-window transfer checks kernel birth, submits `ch_space`, waits
  for destination membership and then removes the source leaf. It does not
  launch an application to fill the old Space.
- The passive native tab reader consumes already published connection
  properties: connection owner, kernel birth, schema, settled revision, groups,
  selected WID and replay fences. During order-on overlap, the selected tab
  inherits its old slot without shrinking its neighbor. The reader does not
  install a publisher. Without a publisher, matching replacement windows have
  a bounded 80 ms missing-window grace period.
- System processes, dialogs, menus, session lock and native fullscreen Spaces
  constrain automatic tiling/transfer. A fullscreen source tree is retained,
  with configure/transform ownership suspended until return. Closing asks the
  application first; a Save sheet must not count as a completed close.
- Hiding parks the client after fade completion. Cross-Space restoration retains
  its hidden record until fresh destination acknowledgement. Active, inactive
  and fullscreen opacity share per-window property handling, but user-facing
  transparency remains unfinished.
- The Source10 bridge runs off the main queue and verifies a private Root
  binding, Dock birth, socket peer, image UUID, request sequence and snapshot
  freshness. Its authenticated overview state blocks mutations. Return requires
  exact hidden intent, native setup/end, an inverse-park receipt and completed
  ACK. The bridge does not install/load the native service. Without verified
  detection, its source presence does not prove ordinary Mission Control is
  detected or that visible-window cards are correct.
- A passive launcher event tap records the originating Space for Spotlight,
  Command-Tab and Dock before macOS switches. Its callback performs no AX or
  WindowServer work; Control-arrow/Escape cancels intent. The native Swift
  `VerifiedPublicWorkspace` provider requires asynchronous preflight, an
  existing attested public AX helper, three independent fresh observer
  processes and three increasing main-loop snapshots over at least 150 ms.
  Old Python-manager authorization does not authorize the Swift manager:
  exact birth/path, `manager_image_sha` and `swift_sources` proof are required.
  Missing proof refuses this provider; helper ACK alone does not prove transfer.
- Nonblocking IPC bounds clients, commands, bytes and client lifetime. A partial
  command must not block other clients or animation ticks.

## Configuration and rendering limits

The shared parser supports curves and inherited animations, `duration_ms`,
`time_scale`, the animation master switch, gaps, ratios/layout, focus, throws,
appearance and window rules. Candidates are validated before publication. A
curve-table replacement waits for active animation to finish; `reload` applies
an accepted candidate. [CONFIG.md](../../docs/CONFIG.md) lists actual consumers
and settings that are accepted without an effective renderer.

The former shell-only `../config/swift-runtime.json` used this shape:

```json
{
  "menu_bar": true,
  "startup_animation": true
}
```

Those values now belong to `runtime.menu_bar` and `runtime.startup_animation` in
the shared text document. The old file remains a migration input.

`appearance` publishes radius, OkLab border gradients, colors and legacy shadow.
Native rounding/glow and exact shadow require the advertised channel capability.
Native close-clone parameters derive from `windowsOut`/`fadeOut`. Rules support
app/title regular expressions, role/subrole matching, float, ignore, opacity
with override, `no_anim` and `no_follow_mouse`. `setprop` binds overrides to kernel
birth. Ignore relinquishes managed ownership rather than classifying the window
as floating; see the current mode's recovery limits. Float-rule classification
is latched for an observed lifetime. Native hotkey overrides require the separate
watcher/baseline; JSON argv preserves command argument spaces. `$schema` is metadata.

### Experimental native frame and snapshot protocols

`HYPRWM_NATIVE_FRAMES=1` enables the debug per-frame configure path only for
already admitted Root client targets with matching path/birth and client
capability 6. It defaults off. Per-frame configure can reflow ordinary application
content; it is not a complete solution for smooth unchanged content. Swift does
not add applications to an allowlist or install client instrumentation.

`HYPRWM_SNAPSHOT_FRAMES=1` additionally requires both `CH_CAP_SNAPSHOT` and
`CH_CAP_SNAPSHOT_COVER`, plus the same app path/birth/CAP6 fences. An underlay alone
cannot conceal immediate changes to the source window. The full-cover protocol
remains experimental and defaults off. It reserves two ring entries before
publication: `GEOM(F_SNAPSHOT|F_MOVE)` captures the old buffer, followed by `OP_CFG`
for one final native frame in the same publication. Ordinary movement does not
set `F_NATIVE`/`F_STRETCH`; missing capability falls back to the existing path.

C5 receipts match fresh engine time, epoch, exact PID/birth/WID and current target.
`SNAP_CONFIGURED=5` requests AX readback only, never another configure. If EVT5 is
missing/rejected, exact EVT3/mode3 plus a fresh ordinary WindowServer snapshot can
start that readback. Incorrect PID/birth/Space/target is rejected. Acquisition,
deferred acquisition, reveal and cancellation have separate handling. A native
snapshot cover can retain source identity in the tree during CG `on=0` until an
exact terminal receipt. Leases appear at `status.snapshots.covered_sources` and
do not invent hidden records. Command-packet tests are not a native consumer or
device gate.

The companion app does not save experimental flags through `LSEnvironment`;
its build manifest records `runtime_defaults.snapshot_frames=false`. The
current development lifecycle helper explicitly supplies
`HYPRWM_SNAPSHOT_FRAMES=0`, even if inherited environment had `1`. An explicit
isolated override remains experimental. Changing shell/menu settings does not
enable snapshot animation.

Remaining integration gates include complete client-compositor admission,
native visibility receipts, miniaturize/deminiaturize and old-buffer leases;
provider-specific Swift-manager device proof and launcher return coverage;
Source10 service/device verification; real tab publishers; and motion, TCC,
Space/modal and drag/resize combinations. The companion cannot supply a daemon
or native receiver capability that is missing.

## Standalone daemon and recovery

The executable attaches to an already installed compatible ABI6 engine. It does
not automatically install/stop WindowServer code or call obsolete `install4.py`.
Missing, incompatible or busy channels cause a startup error. An answering main
control socket prevents another daemon. A different socket does not authorize a
second writer to the same native ring.

The tracked `hook/start.sh` wrapper delegates to development `hook/lifecycle.py`,
which is not tracked in the public checkout. In a complete verified development
installation that helper selects the shared state and Engine adoption. It is
not a clean-clone launch path. For direct startup, quit the current instance
normally first, select matching native resources and follow the [README](../../README.md).
The binary's default state directory is `/tmp/hyprwm-swift`; the development
helper selects `hook/`. Preserve tree, manual ratios, learned minima and
WID/PID/kernel-birth ownership when migrating state.

`HYPRWM_ADOPT_ENGINE=1` checks existing curve compatibility and requires idle
animation, zero holding and an empty command queue. It avoids curve setup and
reads a prepared Lua cache. Current verified attachment still initializes mask
policy (`use_mask=1`, `mask_only=0`, `mask_flip=1`); adoption is not a promise that
no header field is written. `HYPRWM_MENU_BAR=0` permits an existing companion to
remain the sole menu shell.

A prepared `handover` freezes new actions and waits for queues while preserving
the intended hidden ledger/layout. After `handover ready`, the lifecycle owner
signals that exact process with SIGHUP. Current Engine recovery validates and
consumes a one-use handover marker; unmarked startup attempts restoration before
the normal paused guard. Ordinary pause preserves hidden windows; it is not
`restore-all`. Explicit restoration leaves tiling paused for inspection. Normal
quit uses restoration-aware shutdown. See [recovery](../../docs/TROUBLESHOOTING.md)
for pending results, client/daemon time budgets and the limits of scoped proof.

| Variable | Default / source | Purpose |
| --- | --- | --- |
| `HYPRWM_HOOK` | Explicit environment, bundled resources, development metadata or executable search | Select the matching `hook/` resources. |
| `HYPRWM_CTL` | `/tmp/hyprwm.ctl` | Daemon/companion control socket. |
| `HYPRWM_EVENTS` | Control socket path plus `.events` | Event subscription socket. |
| `HYPRWM_STATE_DIR` | `/tmp/hyprwm-swift` | Direct-launch saved state. |
| `HYPRWM_ADOPT_ENGINE` | `0` | Adopt compatible existing curves/channel instead of curve setup; prepared cache only. |
| `HYPRWM_MENU_BAR` | `runtime.menu_bar`, normally `true` | `0`/`1` controls the daemon's own menu. |
| `HYPR_HOME` | Personal Lua base if present, otherwise development defaults | Select base Lua configuration. |
| `HYPRWM_CONFIG` | `~/.config/hyprwm/hyprwm.conf` | Select the shared text document. |
| `HYPRWM_TIME_SCALE` | Shared text `time_scale`, normally `1` | Override global time scaling. |
| `HYPRWM_NO_DECO` | Disabled | `1` suppresses the legacy decoration helper. |
| `HYPRWM_NATIVE_FRAMES` | `0` | Experimental per-app native configure; content may reflow. |
| `HYPRWM_SNAPSHOT_FRAMES` | `0` | Experimental cover protocol; development helper forces it off. |

## Moving a window between native Spaces

`sendws <SID> [wid]` sends an exact visible window to an existing ordinary Space
while retaining the current Space. SID is a native diagnostic ID, not an ordinal
workspace number. It uses the sole engine writer and checks a fresh catalog,
PID/birth/UID/owner and window state. The source tree changes after two fresh
native membership confirmations. `status.space_move.last` reports `queued`,
`acknowledged` or `cancelled` and the confirmation count. No application is
launched to fill the source Space.

Launcher intent records the origin before Spotlight/Dock/Command-Tab/Option-Tab.
A separate transfer verifies native membership, requests activation of the exact
window and waits for actual Space/key acknowledgement. Close-focus fallback does
not restore hidden windows. This is not authorization for arbitrary Space
switching: the public workspace provider requires its own device proof. A
successful manual desktop-selection probe does not grant that provider's proof.

## Automated checks and evidence

The differential fixtures compare 9,600 steps with the frozen October 9 Python
reference. They preserve legacy policy and do not certify all current production
behavior. Relevant suites include:

| Suite / fixture | Coverage |
| --- | --- |
| `ProductionPolicyTests` | Both throw directions, shared horizontal/vertical resize and reversal, accepted-size priority, Space confirmation, PID reuse, dialogs, tabs, pause/resume and runtime validation. |
| `TabIdentityTests` | Settled membership, both order-on overlaps, incomplete/revoked publication, replay, connection/launch changes and kernel birth. |
| `ProductionSocketTests` | Slow clients and preserving an ordinary file at the socket path. |
| `MigrationParityTests`, `MigrationProtocolTests` | Save preservation, fullscreen pins, fade-before-park, ACK-gated restore, appearance, opacity/ignore, inner-divider compensation, launcher origin, MC10 handover and client admission. |
| `FocusRecoveryTests` | Explicit NO_KEY32 and menu/modal/child/unknown barriers. |
| `NativePointerHitTests` | Field92 receiver, phantom CG bounds and resize-notification barriers. |
| `EngineRecoveryTests` | Recovery ownership, acknowledgements, handover, paused landing and manual-authority boundaries. |
| `Tests/NativeLauncherFixture.c` | Locally constructed CGEvents exercising the passive callback without installing a tap or posting events; build command is in the file. |

Public schema2 retains the ALL census, counts ordinary applications including
hidden/order-out windows and checks complete kernel birth/path descriptors.
`status.workspace_manager` includes those fields and a fresh main-loop sequence;
`--workspace-observe` runs a separate read-only Swift observer. Tests use isolated
fixtures; they do not establish live window behavior. Current-build status,
native key/input/visibility and inspected screenshots or actual video frames
remain separate evidence. Build/test success does not prove physical smoothness.

## Menu panel and settings

The native SwiftUI panel provides tiling, borders, animations, pointer focus,
shadows/glow controls, window actions and help/diagnostic pages. Controls can
exist before a renderer or live gate is complete; consult the configuration
consumer table. The status dot distinguishes running, paused and unavailable
access. macOS 26 uses Liquid Glass where available; macOS 14/15 use system
material. Settings use `NavigationSplitView`, grouped forms, search, exact values,
system color pickers, shortcut recording and a curve editor. Preview animation
is finite and respects Reduce Motion.

Saves pass schema/shared runtime validation and an atomic text-file writer.
Invalid or concurrently changed input is preserved instead of overwritten.
[SettingsInventory.json](SettingsInventory.json) currently lists 98 control
entries and their consumers; it is an inventory, not proof that every effect is
implemented. The older [runtime reference](../config/RUNTIME.md) describes JSON
hotkey/rule conventions; use [CONFIG.md](../../docs/CONFIG.md) for current text
syntax, effective settings and ignore behavior.

For isolated UI screenshots/QA, build the debug executable with `swift build`
first. These preview commands open HyprWM's own UI but do not start the WM/channel,
execute management commands or save settings/onboarding completion:

```sh
.build/debug/hyprwm-swift --ui-preview --section menu
.build/debug/hyprwm-swift --ui-preview --section animations
.build/debug/hyprwm-swift --ui-preview --onboarding-step 0
.build/debug/hyprwm-swift --settings-check /path/to/runtime.json
```

`--settings-check` validates a JSON file without opening that UI. Sections are
`general`, `layout`, `animations`, `appearance`, `focus`, `hotkeys`, `rules`,
`advanced`, `about` and `menu`; onboarding steps are `0…3`. Normal first launch can
show the intro, live Accessibility check, shortcuts and readiness screen; the
menu can reopen onboarding.

## App packaging

From the repository root, `zsh hook/swift/build_app.sh` builds the local
`dist/HyprWM.app` menu companion. Opening it connects to an existing WM instead
of starting another daemon. The separate `./install.sh` flow installs a daemon
app and local CLI without launching them; it does not install Engine prerequisites.
See [PACKAGING.md](PACKAGING.md) for receipts, signing, dependencies and limits.

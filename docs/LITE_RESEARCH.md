# Lite mode: API evidence and implementation boundaries

Research date: 2026-10-15. The development Mac has SIP disabled. Source evidence
below establishes API availability and prior art; it is **not** a local SIP-on
test. Live acceptance remains a separate gate.

## Findings and chosen design

| Direction | Primary evidence | Decision |
|---|---|---|
| Public per-window images | Apple's [ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) selects `SCContentFilter(desktopIndependentWindow:)`; [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/captureimage(contentfilter:configuration:completionhandler:)) returns a CGImage. | Capture only the selected managed window, keep pixels in memory, and animate an owned AppKit proxy. Screen Recording permission is required. |
| Captured proxy motion | [yabai's window manager source](https://github.com/koekeishiya/yabai/blob/master/src/window_manager.c) captures proxies, retargets existing proxies, and updates real AX frames, but calls `scripting_addition_swap_window_proxy_in`. | The useful architectural idea is a visual proxy plus a real client. Its scripting addition is not a SIP-on dependency we can adopt. Lite instead parks the real client through AX until the proxy lands. No yabai code is copied. |
| Borders without injection | [JankyBorders](https://github.com/FelixKratz/JankyBorders) demonstrates independent border windows. Its [border source](https://github.com/FelixKratz/JankyBorders/blob/main/src/border.c) uses private SkyLight window/group operations. | Use owned, nonactivating, click-through AppKit windows and public CG/AX observation. Do not adopt SkyLight notification or grouping calls merely because they work on this SIP-off host. |
| Virtual workspaces | The [AeroSpace guide](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces) describes parking inactive windows at a display corner and restoring them on activation/quit. It also documents the unavoidable narrow visible edge and monitor-arrangement limitations. | Logical workspaces 1–10; no Mission Control Space creation, movement, or switching. Park against the bottom/right edge of the complete display arrangement. Persist original geometry before moving a client. |
| Independent AX workers | [AeroSpace's README](https://github.com/nikitabobko/AeroSpace#project-status) records its per-application worker approach. Apple documents [AXUIElementSetMessagingTimeout](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout). | One serial AX queue per PID, with an 80 ms timeout on each app/window AX object. A slow client does not serialize another application's AX work. |
| Resize ordering | [yabai's AX frame setter](https://github.com/koekeishiya/yabai/blob/master/src/window_manager.c) explains size → position → size for edge-clamping behavior and the Enhanced UI workaround. | Set the logical size and parking position on the client's AX queue, restore Enhanced UI to its previous state, then place the final real client under the landed proxy. |
| Public relative ordering | Apple documents [NSWindow.order(_:relativeTo:)](https://developer.apple.com/documentation/appkit/nswindow/order(_:relativeto:)) for positioning an owned window relative to a window number. | Keep proxy/border windows at normal window level and order relative to their client. Never use an always-on-top level that would cover dialogs or menus. Cross-application ordering still requires live verification on each supported macOS release. |

## Private-call register

| Optional operation | SIP-on classification | Capability probe | Public fallback |
|---|---|---|---|
| `_AXUIElementGetWindow` | **Documented to work with SIP on (source):** [AeroSpace's README](https://github.com/nikitabobko/AeroSpace#project-values) identifies this as its sole private API while explicitly retaining SIP. HyprWM's use remains unverified locally under SIP. | `dlsym` resolution; successful result must match the current public CG owner census. `HYPRWM_LITE_PUBLIC_AX=1` disables this optional bridge for fallback verification. | Uniquely match public AX position/size and title to the public CG census. Ambiguous matches are refused; array position is never window identity. |
| `AXEnhancedUserInterface` attribute | **Unverified under SIP.** This is an undocumented AX attribute reached through the public AX setter, not an injection API. | Read the attribute; change it only when its existing value is true; restore the original value afterward. Failure is harmless. | Ordinary public size/position/size setters. |

Lite calls no SkyLight capture, alpha, transform, notification, Space, or window
group functions. It never requests a system task port, starts an injection
helper, changes boot arguments, or requires root. The current executable still
links its existing Engine-mode frameworks; selecting Lite bypasses their native
runtime adapters.

## Implemented pipeline

1. Core layout, rules and focus policy produce the same target rectangles as in
   Engine mode. Lite has a separate state file. A nonempty or unreadable Engine
   hidden-window ledger blocks Lite startup until Engine recovery is completed;
   Lite never adopts or overwrites those native ownership records.
2. Before the first mutation, an owner-only recovery file records window ID,
   PID, process birth and original frame. No title or captured pixels are saved.
3. ScreenCaptureKit obtains the source image. If permission, capture or identity
   fails, apply the target directly through AX and report that capability
   downgrade. A failed capture never authorizes hiding the client.
4. Show an owned proxy; park and resize the real client. Before proxy motion,
   verify the accepted client frame intersects every full display frame by no
   more than two points on at least one axis. An unverified parking attempt
   falls back to direct placement. Drive image bounds,
   position, border bounds and border path with one Core Animation start time
   and the same frame samples from the configured curve.
5. Retarget from the current presentation layer, including measured velocity.
   Keep the exact target proxy until final AX placement returns, then reveal the
   real client. External closes use a bounded in-memory image cache.
6. Idle borders track the public census. Focus color changes do not issue AX
   geometry calls. Public Carbon hotkeys use the portable default chords and
   text overrides, without an injected keyboard helper.

## Selection, permissions and recovery

- `HYPRWM_MODE=lite` skips native channel attachment entirely.
- Unset mode or `HYPRWM_MODE=auto` selects Lite when verified Engine attachment
  fails. This produces one startup message, not repeated missing-engine logs.
- `HYPRWM_MODE=engine` requires a compatible, available native channel and
  reports the actual attachment failure.
- Accessibility is required for control. Screen Recording enables captured
  proxy animation; denial leaves tiling, workspaces, borders, rules, hotkeys,
  reload, IPC and import available through the AX fallback.
- `status` reports top-level `mode`, `daemon.mode`, `engine.mode`,
  `engine.available`, and `lite` capability counters. Menu and doctor consume
  the same running-mode metadata.
- Recovery is stored as `lite-recovery.json` inside `HYPRWM_STATE_DIR` (default
  `/tmp/hyprwm-swift`). The schema is an array of
  `{wid, pid, birth, frame: [x,y,width,height]}`.
- `restore-all` talks to the selected live socket. Without a listener it runs
  only the Lite AX recovery path, without starting a window manager or hotkeys.
  A record is removed only after restoration acknowledgement or confirmed
  lifetime departure. Failed recovery preserves the ledger and reports failure.
  A live restore request can return `Lite restoration pending:` while bounded
  asynchronous AX workers run; the CLI retries only this marker for four seconds.
- Normal quit attempts restoration for three seconds. Outstanding records remain
  recoverable if a client does not acknowledge placement. Startup uses the same
  bounded scheduler and stays paused if recovery is incomplete. Neither path
  trusts a reused PID alone. Invalid existing recovery files are preserved and
  prevent movement instead of being treated as an empty ledger.
- Native application hiding suppresses cached proxy imagery and borders. An AX
  window-list omission while its application is hidden is insufficient evidence
  that the recovery record's window has closed.

## Limits and live acceptance

Public AX cannot intercept an unrelated application's very first ordered frame.
A proxy can animate its allocated-slot entrance after discovery, but a universal
zero-flash first-map guarantee would require client cooperation or another
verified mechanism. Screen-protected windows and windows omitted from shareable
content fall back to direct AX placement. During a proxy transition the image is
a snapshot; video and rapidly changing content do not remain live.

Foreign-window opacity and native Space management are not public capabilities
of this implementation. Ordinary clients remain opaque; scratch/hidden and
inactive-workspace visibility is implemented with reversible AX parking.
Native Mission Control behavior and multiple-display parking need separate
desktop evidence. Public AX matching can refuse indistinguishable overlapping
windows when the optional ID bridge is disabled.

Automated release compilation establishes buildability only. The coordinator
must separately verify forced Lite with 2–4 disposable windows: tiling,
open/close/swap clips, border tracking, pointer focus, gap hot reload, virtual
workspace round trip, and quit/restart recovery. No SIP-on behavioral pass is
claimed from this SIP-off development session.

## Development-session observations

The first isolated forced-Lite session used fresh disposable windows and an
allow rule, with the existing native Engine daemon stopped. Lite reported
`engine_channel_used: false`. The host still contained an earlier WindowServer
injection and had SIP disabled; these observations cannot establish SIP-on
behavior.

Observed results included two- and three-window tiling, matching native and
reported hover focus, visible captured-proxy swap motion with its border,
atomic gap reload, and restoration to the recorded original client frames.
A captured TextEdit entrance also showed its default-position frame before AX
discovery. The zero-flash first-map acceptance gate therefore remains blocked.
Full close/retarget/landing frame inspection, virtual-workspace round trip,
mid-motion pause, native application hiding, and parked-client crash recovery
need a further live session on the final build. Source checks and extracted
motion/identity/recovery checks are supporting evidence, not live passes.

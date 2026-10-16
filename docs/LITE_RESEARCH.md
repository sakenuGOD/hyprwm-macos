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
   and the same frame samples from the configured curve. The visual endpoint
   uses the resized client's accepted dimensions; the logical request remains
   separate for configure receipts and minimum-size learning.
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
- A transition to an empty virtual workspace first makes a visible, owned
  “Workspace N” panel the keyboard receiver. This prevents typing into the
  previously focused parked client. It retains no typed characters. The panel
  stays until a current-workspace client has verified visible native focus, or
  the user chooses an unowned visible window/application. Status exposes
  `workspace_public.empty_receiver` with `visible`, `key`, `window` and
  `key_events` fields.
- Changing an owned, inactive window to an ignored rule restores its recorded
  original frame before releasing ownership. The same bounded recovery pump
  handles this subset; `lite.ignored_release_count` reports outstanding work.

## Limits and live acceptance

No documented public AX hook guarantees interception before an unrelated
application's first ordered frame. Apple's
[window-created notification](https://developer.apple.com/documentation/applicationservices/kaxwindowcreatednotification)
provides the new window element through an
[AX observer](https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate),
but specifies no ordering relative to presentation. A callback may reduce the
current 50 ms polling delay; this is a timing hypothesis awaiting measurement,
not a zero-flash guarantee. A proxy can animate its allocated-slot entrance after
discovery. Screen-protected windows and windows omitted from shareable
content fall back to direct AX placement. During a proxy transition the image is
a snapshot; video and rapidly changing content do not remain live.

Foreign-window opacity and native Space management are not public capabilities
of this implementation. Ordinary clients remain opaque; scratch/hidden and
inactive-workspace visibility is implemented with reversible AX parking.
Native Mission Control behavior and multiple-display parking need separate
desktop evidence. Public AX matching can refuse indistinguishable overlapping
windows when the optional ID bridge is disabled.

A later timing probe sampled public CG state immediately at a Terminal
window-created callback, before its blocking AX metadata query. The new CG row
was off-screen with a zero frame during that census; about 28 ms after callback
entry, AX metadata and a second CG census showed a standard window already
visible at its default frame. This supplies a concrete fast-admission timing
hypothesis. It does not establish presentation ordering or authorize movement
without ordinary-window classification, rules, exact identity and a durable
recovery record. The existing optional ID bridge can avoid a full-census match
when available; its SIP-on source classification above still applies.

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
Two further isolated sessions tested virtual-workspace round trips, silent sends,
same-workspace no-ops, inactive-window rule release, mid-motion pause and manual
move/resume. A daemon killed while its clients were physically parked recovered
them on a paused restart with responsive IPC. Normal quit also restored parked
clients. One Terminal recovery accepted a frame within six points of the recorded
frame because of its character-grid sizing; recovery does not guarantee exact
pixel dimensions for every client.

The visible empty-workspace panel received guarded numeric key events in both
same-application and cross-application workspace tests. Returning to a TextEdit
workspace dismissed it after native client focus, and guarded numeric input
appeared in the disposable document. A physical Command-H during a resize hid
that application's proxy and border; unhide returned its client to the layout.
Broad modal, multiple-display, retarget and burst coverage remain pending.

Actual captured close/expansion frames exposed a late content jump: a stretched
old half-height Terminal image changed to the resized live client at handoff.
Refreshing the parked client's resized backing and crossfading it during the
proxy motion removed the late stretched-title switch in a further capture.
That capture's earlier frames also showed a proxy disappearing and briefly
displaying its final rectangle before moving back into the trajectory. A further
capture with accepted-size endpoints and one model/animation transaction did not
show that reversal; its final five actual frames were stable and opaque. It still
showed doubled, stretched text during the content fade. The accepted client size
also differed from the logical target by two points in width and four in height.
Closing the full-height sibling in this take incorrectly promoted the survivors
to a top/bottom layout. These are separate remaining failures; the first-map and
complete clean-landing gates remain failed. Apple's public
[CATransition](https://developer.apple.com/documentation/quartzcore/catransition)
supports a [fade](https://developer.apple.com/documentation/quartzcore/catransitiontype/fade)
for layer content changes; capture timing and off-screen client backing updates
still need broader live evidence. The implementation separates accepted visual
size from logical layout requests and groups model changes with their explicit
animations. Apple's [Core Animation timing and transaction guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/AdvancedAnimationTricks/AdvancedAnimationTricks.html)
documents layer-local start times and nested transaction commits; this supports
the implementation hypothesis and does not establish its frame behavior.
Source checks and extracted motion/identity/recovery checks are supporting
evidence, not live passes.

### AX-created admission experiment

A public per-application `AXWindowCreated` observer now batches ordinary-window metadata on the existing AX worker, optionally maps its window ID through the documented AeroSpace bridge, and independently checks the current public CG owner. The public fallback requires a unique frame/title match. An exact, fresh, focused ordinary window can enter the existing Core admission and rule matcher; metadata alone cannot park it. Its original frame is persisted before an admitted opening may park ahead of ScreenCaptureKit capture. The queued write rechecks the PID lifetime, public owner, modal/menu state, exact AX key window, foreground app, hidden state, mouse buttons, and session lock. Expired or refused admission makes no AX write.

The first live take used the optional ID bridge but recorded zero fast admissions and zero early parks. The new document still appeared at its default position before tiling. The next instrumented take aborted its actor-prefix precondition before creating windows or starting a daemon. A later, separately scoped take delivered an ordinary, mapped, focused notification but still made no fast admission. Runtime counters then identified a foreground-app refusal before the census guard. A bounded foreground retry preserves the original 250 ms deadline and rechecks the exact AX element, process birth, current public owner, key window and modal state. Its queued completion is invalidated by pause, recovery, config reload, workspace changes and shutdown. In its live take, both created notifications were refused because the ordinary Core path already owned their windows. No early park ran. These experiments therefore leave the first-frame gate failed; relaxing the ownership guard would risk moving an already managed tile. No before-presentation guarantee or local SIP-on validation follows from them.

### Close census and proxy continuity

A public CG row can outlive AX window closure. The Lite adapter now asks for a fresh AX census after an eligible managed window becomes unmapped. Unknown results hold Core admission for at most 180 ms; positive AX closure filters the stale CG row. Process lifetime, app visibility, virtual concealment and in-flight proxy checks bound this path. A mirrored three-to-two close produced the expected side-by-side tree and native client placement in an isolated take. This verifies that specific trajectory only: a census that still positively contains the window can release the hold before a later closure, and other mirrored transfer/close variants still require separate evidence.

That take also exposed a surviving proxy disappearing before returning in its old position. The accepted-size callback constructed a second overlay and closed its staging overlay before ordering the replacement. Reusing the same staging overlay removes that source boundary; the canvas only expands and the same global start rectangle is retained. The next isolated take exercised both survivor reuse paths and ended with stable, opaque clients. Stretched and doubled text during the content fade and the closed-window cached replay remained visible. One survivor also briefly lost its title/body before the other expanded over that region; reusing an overlay has not established complete cover continuity. Its native Terminal size differed from the logical target by one point on each axis. These observations do not satisfy the complete close, clean-landing or Lite acceptance gates.


### Native-size content experiment

Earlier experiments refreshed a resized client backing during motion, then faded it over a screenshot whose layer bounds were changing. This improved a late handoff but left stretched and doubled text in intermediate actual frames. The body layer used `contentsGravity = .resize`; Apple's [contentsGravity documentation](https://developer.apple.com/documentation/quartzcore/calayer/contentsgravity) defines the positioning/scaling choice. The current isolated experiment retains a fixed-size backing sublayer inside a masked animated viewport. The viewport and border keep their existing geometry clock, and the backing's top anchor follows that same clock without resizing its bounds. The exact accepted-size capture is admitted before motion begins, under a bounded capture budget and deadline, so this path does not crossfade font grids during a resize. Transparent capture edges receive an opaque body extension; intentional opening/closing scale effects remain separate. Raster checks reproduce glyph scaling with the earlier layer and stable glyph dimensions with the fixed backing. The subsequent isolated take exercised both native-backing survivor motions without a direct fallback. Independent actual-frame review found normal title/font proportions and no earlier doubled font grid in the inspected motion interval; the last five frames were stable and opaque. Both survivors still disappeared briefly before returning in their old stacked pose, and the closed-window cached replay remained. This is a specific text-rendering improvement, not a complete close or motion pass.


### Final cover-readiness qualification and remaining work

A further isolated candidate flushes the staged overlay, waits two display intervals, and requires its exact public CG window ID, own PID, on-screen state and expected canvas bounds before parking the real client. This is bounded capability evidence, not a compositor-pixel receipt. Cancellation closes an unpublished cover; retarget refusal retains the prior frozen cover and recovery record. Native app hide consumes the existing identity-bound restore path for an already parked client, including workspace restoration without a prior proxy. The locked-session branch issues no placement.

Its final take reported zero readiness admissions, zero readiness refusals and zero native-backing motions; survivor placement used the earlier direct branch. The barrier was therefore unexercised. Neither a continuity improvement nor a failed barrier mechanism follows from that take. The direct branch also admits mouse-held, instant and disabled-motion cases; the captured counters did not identify which condition selected it. No unchanged rerun was used to promote this candidate.

Lite remains on its development branch and did not pass the launch gate. Remaining blockers include default-position first frames, cached closing-image replay, survivor-cover discontinuity, incomplete retarget/burst coverage, and client character-grid differences from logical targets. The next scoped continuity test must first positively qualify an animated, non-held transition and record the readiness counters, then inspect actual VFR onset/midpoint/final frames. The AX-created experiment separately needs a fresh exact notification-to-Core ownership path without relaxing lifetime, ordinary-window, modal, rule or existing-ownership guards. No Engine integration or local SIP-on validation is claimed.

# Motion choreography

HyprWM uses the window's current displayed rectangle as spatial truth. A layout
transaction has one monotonic start time. Every body, border, shadow and opacity
sample for that transaction uses that time; an independently scheduled border or
an extra content resize after landing is a defect. Focus appearance has its own
parallel timeline and never postpones geometry.

This is the acceptance specification, not a claim that every event below is
already verified. The night ledger records the current build's actual results.

## Reference curves and configuration

The reference is `notes/hyprland_spec_full.md` sections 1.4–1.5, 2.3–2.6 and 3–4.
Its measured defaults are:

| Name | Definition | Reference behavior |
|---|---|---|
| bounce | spring, mass 1, stiffness 260, damping 20 | Open geometry; about 739 ms to the normalized value/velocity stop criterion |
| drift | spring, mass 1, stiffness 210, damping 24 | Layout geometry; about 739 ms to the same stop criterion |
| smooth | cubic Bezier `(0.25,1),(0.5,1)` | Open fade 300 ms; close fade 240 ms; active opacity 400 ms |
| snappy | cubic Bezier `(0.2,0.9),(0.1,1)` | Close geometry 260 ms |
| overshot | cubic Bezier `(0.05,0.9),(0.1,1.06)` | Special workspace reference, 400 ms |

Bezier duration is speed multiplied by 100 ms. Spring speed is not a fixed
completion duration: completion requires both normalized displacement and
velocity at most 0.001. Use the analytic spring integration, including critical
and overdamped cases, and retain current velocity when retargeting. Evaluate
against elapsed time rather than counting rendered frames.

Read effective curves and animation settings from the validated configuration.
The reference border fade is `smooth`, 600 ms. The owner's explicit configuration
currently chooses `focusFade = (0.25,0.1),(0.25,1)`, 260 ms; that override remains
authoritative. The reference open scale is 86%, close scale 92%, and workspace
slide distance 12% of logical display width. Do not substitute unrelated timing
presets. Disabled animation uses the same ownership/landing logic with zero
motion time.

Geometry and decoration geometry use the same curve and sample. The configured
fade channel shares the event start time while retaining its configured fade
curve and duration, as the Hyprland reference does. No timer may independently
restart that fade or geometrical decoration. Focus color/active opacity begins
on the focus event and runs in parallel.

## Event contract

`A` is the real client frame. `B` is the presented body rectangle. A border's
outer contour is derived from B, with constant configured thickness. A shadow's
shape is derived from that same B. A content acknowledgement is scoped to the
exact window owner, process birth and geometry generation.

For layout animations, configure the final A size once and animate its
presentation through B. Reflowing application content at every animation sample
is not the intended appearance. Keep the experimental native per-frame configure
mode disabled for normal use. Direct pointer resizing remains interactive.

| Event | What moves and from/to | Duration and curve | Z-order | Stagger | Border | A relative to B |
|---|---|---|---|---|---|---|
| Open | New body grows from 86% of its allocated slot about the slot center, fading 0→1. Existing neighbors move from their current B to their new slots on the same transaction. | New geometry `windowsIn`/bounce; fade `fadeIn`/smooth 300 ms. Neighbors `windowsMove`/drift. | New tile belongs to the tiled plane; same-app dialogs and explicit floats remain above it. | 0 ms by default; any coalesced burst stagger must stay within 0–30 ms. | Geometry is exactly the new body's B at every sample; it fades with the event. | Predict final slot before first visible presentation. Request final A once; present the accepted content through B. Late readiness must have a bounded visible fallback, never an old-position flash. |
| Close | The departing body or captured close image shrinks in place from its current B to 92% around its current center and fades out. Survivors expand immediately. | `windowsOut`/snappy 260 ms; `fadeOut`/smooth 240 ms; survivors drift from the same event epoch. | Captured body retains the tile's plane and order until retired; it cannot cover a modal sheet. | 0 ms. | Shares departing body's rectangle and alpha; removed only after final retirement. | Remove the closing leaf on confirmed departure/accepted close intent, without waiting for its visual fade to finish. Keep survivor A and B on the same transaction; a refused close must preserve the original layout. |
| Focus change | Geometry stays fixed. Border color and configured active opacity change; old focus appearance fades. | Effective `border` override; `fadeSwitch`/smooth 400 ms when opacity differs. | Same-app dialogs and policy floats remain above tiles. | 0 ms. | Color only; a redundant click does not restart geometry or the color fade. | No configure or AX frame operation. |
| 3→2 promotion | Two survivors leave their current displayed rectangles and fill a left/right pair, including the mirrored trigger. | `windowsMove`/drift, one shared epoch. | Tiled order remains stable, with dialogs/floats above. | 0 ms. | Uses each surviving body's B, including the shared cut. | Request both final A frames in parallel; no intermediate top/bottom target and no last-frame correction. |
| Swap/throw | Two tile bodies exchange slots horizontally or vertically as dictated by the actual neighbor. A gentle horizontal throw keeps its horizontal intent. | `windowsMove`/drift, starting from both current B values. | Stable tiled plane; no temporary elevation above modal/floating windows. | 0 ms. | Moves with its own body; focus appearance changes only if focus changes. | Both A targets are issued together. Accepted minimum/grid sizes are incorporated into the landing before the final sample. |
| Shared-edge resize | Every neighbor touching the dragged cut follows the same cut coordinate. The pointer owns the directly manipulated edge. | Interactive warp/direct pointer sample as in reference manual mouse resize; keyboard resize uses configured `windowsMove`. | Stable tiled plane. | 0 ms. | Derived from the same shared geometry; no independently eased edge. | Coalesce stale configure targets per PID/window; respect accepted A without replaying older requests. Button-held interaction cannot transfer focus. |
| Workspace switch | In Lite virtual workspaces, incoming/outgoing window groups move ±12% of logical display width and crossfade. Wallpaper/menu bar remain still. Engine native Spaces retain the OS transition unless a separate verified backend owns it. | Effective `workspacesIn/Out`/drift; reference settling about 739 ms. | Incoming/outgoing groups preserve their internal tiled/float order; parked real windows cannot intercept the pointer. | 0 ms across each group. | Attached to each body's workspace transform. | Store exact original/target A before parking. Restore only exact owned records and acknowledge membership. Native Space transitions freeze census/apply until stable. |
| Restore from hidden | The same live window moves from its last valid displayed/recorded rect toward its allocated current-workspace slot and fades in. Mirrored left/right restores are reflected versions of one operation. | `windowsMove`/drift + `fadeIn`/smooth 300 ms, one shared event epoch. | Restored tile stays beneath dialogs/floats; focus is usable after accepted arrival. | 0 ms with neighbors. | Same geometry/alpha event as body, without a detached jump to target. | Confirm owner, birth, live window and workspace membership before revealing. A rejected/stale request ends visibly and recoverably within its deadline. |
| Fullscreen toggle | Tiled/maximized geometry moves from current B to the intended content area and back. Native macOS fullscreen is a separate OS lifecycle. | `windowsMove`/drift; reference fullscreen visibility uses `fadeIn`/smooth 300 ms. | Modal/float ownership remains correct. Other tiles' visibility follows the validated fullscreen policy. | 0 ms. | Configured fullscreen border policy is applied on the same geometry event, not by a late extra resize. | Preserve exact pre-fullscreen placement and apply one final A target. Native fullscreen windows are excluded from ordinary tiled configure work. |

## Retargeting and landing

A new target starts from the current presented rectangle, opacity and velocity.
Never reuse the last transaction's original start rectangle. A duplicate target
is a no-op. A burst coalesces obsolete targets per exact window identity; it does
not enqueue a visible series of old layouts. A geometry generation supersedes
all pending configure, cover and animation work for earlier generations.

Use the accepted client minimum/grid size in the layout and the final B target.
At landing, B equals that accepted target, border/body displacement is at most
2 physical pixels, transforms are retired without a scale/crop discontinuity,
and the last content update does not create a new visible transition. An
overshoot is permitted only when it settles without a correction frame.

Pause captures the current B and stops retargeting before draining work. Visible
windows stay visible, hidden windows retain their explicit visibility state,
and resume recomputes from current native frames rather than replaying old
commands. Appearance edits and focus edits do not change geometry.

Lite captures a real owned window image for proxy motion. Its proxy, border and
shadow use one display-time sample. Exact real-window parking is persisted
before moving it; failure/quit restores it. If capture or a private capability is
unavailable, fall back to a visible, recoverable real window and report the
reduced capability. A capability or build check is not proof of SIP-on behavior.

## Frame review gate

For each of the nine events, keep a normal-speed `screencapture -v` clip and a
separate slowed `HYPRWM_TIME_SCALE` clip, plus status/native frame evidence from
the same build and session. Extract using `ffmpeg -i clip.mov -vf fps=60
frames/%04d.png`. Inspect the first three frames of each motion, its midpoint,
and its last five frames. Include the frame before onset and final stable frame
for reference.

Reject an event for an old/default-position first-frame flash, body/border
separation over 2 physical pixels, a single-frame teleport/recoil, a late content
resize/crop pop, a wrong final rectangle, a stale replay, an invisible survivor,
or a modal sheet/floating window buried by a tile. Verify mirrored restores and
closing both at rest and during another transition. Save exact frame filenames
and the measured failure in the ledger; a green build is not this gate.

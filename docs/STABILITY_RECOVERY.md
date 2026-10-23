# Stability recovery, 2026-10-17

## Baseline

The local git log and reflog resolve 09:00 MSK to `d813fde`.
Recovery starts from this commit, not the later focus changes or the uncommitted
workspace-command changes. The prior binary and tracked dirty state are retained
outside this checkout. Appearance, menu, bar and application configuration are
unchanged.

The daemon is replaced by an authenticated state-preserving handover. The native
engine, owner applications, hotkeys and menu companion are not restarted. Hidden
window ownership survives the handover and engine errors remain at their prior
cumulative value.

## Live comparison

Both the morning build and the saved later build were run in the same login
session. Evidence is retained locally and is not suitable for publication.

| Scenario | Morning | Saved later build |
| --- | --- | --- |
| Option-Enter twice, close both exact new windows | One existing Ghostty PID, correct final AX frames and keyboard focus, survivors reflow | Same |
| New Ghostty motion | Visible backing/entrance artifacts remain | Visible backing/entrance artifacts remain |
| Zen via Command-Tab, Dock and Spotlight | Visible, focused and tiled at final observation | Command-Tab observed at x=1430 for target x=738 at the earlier observation; final repeated checks settled correctly |
| Five repeated Command-Tab cycles, native-selected window | Five settled-frame checks pass | Five settled-frame checks pass |
| Zen native fullscreen and exit | Native Space, ordinary peer expands, return tiles | Same |
| Zen file dialog | Parent retains frame in this scenario | Same |
| Zen send to existing desktop, Mission Control selection, return | Visible and tiled on destination and return | Same |

The initial repeated-restore probe incorrectly required the newly created Zen
window even when macOS selected another existing Zen window. That probe is not
product-failure evidence. The corrected probe checks the native-selected window.

No reliable good/bad split was established for the three later commits, so the
attempted bisect was cancelled rather than assigning a false culprit. Those
commits are not part of this recovery branch. A later bisect requires a specific
reproducible regression signal.

## AX-confirmed minimum correction

A live four-application crowd scenario exposed Finder accepting width 459 while
its ratio tile requested 362. The AX setter and readback ran, but production
ratio layout discarded learned minima. The client was therefore cropped.

Keep a live window-local, PID/birth-guarded floor only when a successful current
configure actually changes that axis and then settles above the requested size.
Ratio layout honors this floor without trusting persisted app-wide estimates.
Unchanged AX responses still cannot teach a minimum. Closed/recycled identities
cannot transfer their floor to another client.

Checks on the candidate in the same login session:

- The new configure-to-layout regression fails before the fix and passes after.
- Full Swift suite: 266 tests, one skipped, zero failures.
- Live crowded Telegram, Zen, Ghostty and Finder: all four final AX frames equal
  their WM targets; inspected screenshot shows Finder edges and the browser's
  orange viewport border and green bottom-right marker inside their tiles.
- Two Option-Enter windows in the existing Ghostty process, exact-window cleanup
  and survivor reflow pass on an existing native desktop. No new process appears.
- Handover preserves the hidden ledger, owner config, hotkeys and menu process;
  native engine cumulative errors remain at their preceding value of two.

An earlier console attempt received no hotkey event and created no window. The
subsequent actual two-window run passes; the first attempt is not counted as a
pass. This correction does not qualify motion or physically infeasible layouts.
Local screen evidence remains outside git.

## Final AX setter ordering

The native frame setter now writes size, position, size and propagates failure
from every setter. The final size repairs growth clamped against the old origin;
shrinking before positioning also permits placement near the screen edge.
Enhanced-UI animation suppression and restoration remain unchanged. The existing
configure worker still reads back the actual accepted AX frame.

- Native production-setter fixture fails on the former P-S-P order and passes
  with S-P-S, including delayed positioning, unsupported attributes and mode
  restoration.
- Full Swift suite: 266 tests, one skipped, zero failures.
- New live four-application crowd run: four final AX frames match targets;
  screenshot inspected, including both viewport markers in the narrow browser.
- Live Zen native fullscreen/exit, file dialog, Command-Tab, Dock, Spotlight and
  transfer return retain visible, correctly configured windows. Destination
  focus during transfer is not qualified by this run.

## Telegram request clarification

Five pointer-focus cycles and a keyboard search work, but these do not address
the actual request: restore the previously reversed persistent application
activity/connected-state behavior. Investigate the existing client module, not
focus-follows-mouse. Also diagnose first-launch initialization stalls separately
from a warm second launch. Neither issue is declared resolved here.

## Nonblocking AX eligibility census

A stopped owned AppKit client reproduced a 1353 ms control-response stall. The
main-thread sample ended in `WM.tileable -> WM.wmInfo -> ax_tileable ->
AXUIElementCopyAttributeValue`. Main-thread eligibility now reads an asynchronous,
bounded PID/birth-fenced cache. Focus workers still use fresh native eligibility
at their commit boundary. Unknown is never treated as positive evidence; old
in-flight replies cannot replace a newer identity or survive explicit forgetting.

- Five cache tests include a blocked client, independent client progress, changed
  process birth, replacement while an old request is blocked, and pending limits.
- Full Swift suite: 271 tests, one skipped, zero failures; release build passes.
- Live stopped-owned-client comparison: maximum response 1353 ms before, 279 ms
  after; p95 14.4 ms before, 13.4 ms after. The sampled main thread no longer waits
  in synchronous AX eligibility. The remaining latency tail is not declared fixed.
- Two real Option-Enter windows stay in the existing Ghostty process, final frames
  and exact-window cleanup pass, and the inspected screenshot shows both tiles.
- Handover preserves hidden ownership, config, hotkeys, menu and native engine;
  cumulative engine errors remain two.

This does not qualify first-map motion. A separate continuous-opening experiment
still showed startup blanking/overshoot in live Finder frames and was rolled back
before this cache candidate was installed. The user-reported Space migration and
Dock Downloads focus diversion remain open; stale `NSWorkspace` foreground data
in the passive helper must not be mistaken for native focus truth.

## Retain existing tiles during cold AX discovery

The async census exposed a cold-cache regression: an existing tiled Ghostty
window left the tree while AX eligibility was unknown, then reentered as new.
Unknown discovery now retains only an existing, natively present tree member.
The existing window-type cache records pending identity using the same native
PID/process-birth sources as the async cache. Pending is not a positive answer
for admission or focus. Cached answers cannot survive a different process birth.
Confirmed rejection, explicit floating, missing native identity and actual native
disappearance still remove the old member. No readiness or animation change is
included in this correction.

- Eight new regression tests fail with 33 assertions before the correction and
  pass afterward. Coverage includes restored trees without runtime metadata,
  pending-to-positive/negative answers, new-window admission, disappearance,
  floats, native owner changes and recycled process birth.
- Full Swift suite: 279 tests, one skipped, zero failures; release build and diff
  whitespace checks pass. Two existing tab fixtures now supply their native owner.
- Live cold-cache handover: 183 status samples, no missing existing tile or target
  change, same native key window, exact AX frame and inspected screenshot. Four
  socket gaps occur during the intentional daemon replacement, not a latency test.
- Original Finder scenario: 95 samples keep the existing Ghostty member; only the
  exact new Finder window enters and leaves. Its film still shows the default
  position followed by tiled placement; first-map smoothness remains unresolved.
- Two Option-Enter consoles use the existing Ghostty process, final frames and
  exact cleanup pass, and the screenshot is inspected. No application is restarted.
- Hidden ownership, configuration, hotkeys and menu companion survive the daemon
  replacement; native engine cumulative errors remain two.

The rejected first-placement readiness candidate stays outside this branch and
runtime. The accepted classification correction is independent of its reevaluation.
Local evidence labels: `classification-retention-live`,
`finder-first-map-classification`, `classification-retention-console`.

## Long unknown eligibility and retry backoff

A follow-up on the accepted retention base found a second eviction seam: after
60 failed refreshes, `wmInfo` returns no answer during retry backoff even for a
previously confirmed primary window. Cold-cache-only retention did not cover
that state. Keep that existing member under the same PID/birth/native-presence
checks, without treating backoff as positive eligibility. A previously confirmed
negative answer still cannot gain retention during an unknown refresh.

- The long-pending regression fails at step 74, removing the member and changing
  focus; it passes after the one-line retention correction. A separate control
  preserves confirmed-negative behavior.
- Full Swift suite: 281 tests, one skipped, zero failures; release and whitespace
  checks pass.
- `classification-long-pending-live`: LLDB holds only the exact owned AppKit
  process for four seconds, then detaches. All 189 sampled target maps remain
  unchanged; the maximum observed control response is 28.08 ms. The owned client
  is responsive again, its resumed screenshot is inspected, and exact cleanup
  restores the original owner-only layout. Native engine errors remain two.

The live latency result is scoped to this owned stopped-client run, not a general
latency guarantee. No first-map candidate is installed. Separate readiness plus
continuous-motion and engine-consumption-ordering experiments both remained
visually unacceptable (blank entry surface) and were rolled back. Their automated
success does not qualify them for recovery. Configured entrance spring overshoot
alone does not establish competition with native animation; owner curves remain
unchanged.

## Native Space focus recovery epoch

A queued automatic Space/close recovery could survive an unstable native census
and later commit into its previous Space, even when the first unstable sample
still reported the old SID. Invalidate the existing focus-recovery epoch at the
unstable/locked snapshot early return. Stable same-Space recovery remains valid;
no separate focus mechanism or Space action is introduced.

- On the current accepted classification base, the two-test regression produces
  16 failures before the correction. Afterward the full Swift suite has 283
  tests, one skipped, zero failures; release and whitespace checks pass.
- Live owned AppKit roundtrip: native fullscreen Space is created by the owned
  window's public AppKit toggle, then removed on return to the original desktop.
  No native workspace backend or foreign-window Space setter is used.
- Across 68 observations, the two tracked original owner tiles retain their
  source membership and nonzero alpha in stable native snapshots. Both exact
  owned windows return with AX frames matching targets and the correct native
  key window. Fullscreen and returned-window screenshots are inspected.
- Only the owned fixture is closed. Original owner-only layout, hidden ownership,
  configuration, hotkeys and menu companion survive; engine errors remain two.
- The separately installed R11 bar reconnects across daemon replacement and
  restores its complete three-Space census after fullscreen cleanup, available
  rather than retained. Its prepared native action backend remains disabled.

This fixes the demonstrated stale-callback race, not a proven universal cause
of owner-reported Space migration or invisible windows. The live scenario is a
single owned native fullscreen roundtrip, not a qualified arbitrary Mission
Control gesture or all-application visibility gate. Local evidence labels:
`space-epoch-b817-live`, `space-epoch-owned-roundtrip`.

## Remaining gates

This is a recovery baseline, not a claim that WM is stable. Entrance/backing
artifacts, continuous body/shadow motion, native Space gestures and real client
resize under crowding remain unqualified. Stabilize the core and real AX resize
before changing dialogs, focus appearance, bar or palette. Check the actual
client dimensions and rendering on Telegram, Zen, Ghostty and Finder; a clipped
viewport is not a smaller client window.

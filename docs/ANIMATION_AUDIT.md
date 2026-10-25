# HyprWM / Hyprland animation audit

Date: 2026-10-26. Scope: the `fix-20261019` source tree examined during this review. This is an implementation audit, not acceptance of the installed application. The audit only wrote this document; it did not modify code, configuration, Git state, applications, or the native session, and did not run tests. Concurrent changes to arrival, floating-window preservation, pointer focus, and ratio allocation were reread and are marked as source changes below. At the request of the task owner, **the Frame review gate was not performed**. There are no new recordings, extracted frames, measured durations, or measurements proving the two-physical-pixel tolerance. At audit time, no live motion scenarios were observed; the table records source coverage, not release acceptance. Missing screen-recording permission was not established.

The Engine has real consumers for the main geometry curves, retargeting, and open/close/focus channels. It does not match the full Hyprland animation surface: styles are narrower, and most workspace/layer/popup/angle/zoom branches only produce configuration records. The initial review found two visible departures from [MOTION.md](MOTION.md): production restore revealed an actor already at final B, and an already-visible opening warped to its slot. Those branches now request movement from the recorded/current B. The current source also preserves explicitly floating windows across applications and allocates `minimum_policy=ratio` partitions without consulting client minima. These changes address identified command/policy gaps; they do not establish their runtime appearance or input behavior.

There is no evidence here that HyprWM is smoother than Hyprland. The implementation's owner, process-birth, generation, acknowledgement, and recovery guards are valuable protections when managing foreign macOS clients. Their presence alone does not establish frame quality.

## Sources and evidence limits

- **U1:** the official [animation wiki: tree, styles, and Extras](https://github.com/hyprwm/hyprland-wiki/blob/main/content/configuring/core/animations.md), read through its raw URL. No clone was created because this audit was restricted to writing the report.
- **U2:** official [AnimationTree.cpp](https://github.com/hyprwm/Hyprland/blob/main/src/config/shared/animation/AnimationTree.cpp), `CAnimationTreeController::reset`.
- **U3:** [DesktopAnimationManager.cpp](https://github.com/hyprwm/Hyprland/blob/ee58a513f77fa93d0b7e29ac9ad6e59554266711/src/managers/animation/DesktopAnimationManager.cpp), `startAnimation`, `animationPopin`, `animationSlide`, `animationGnomed`, and `setFullscreenFadeAnimation`; [AnimationManager.cpp](https://github.com/hyprwm/Hyprland/blob/ee58a513f77fa93d0b7e29ac9ad6e59554266711/src/managers/animation/AnimationManager.cpp), `tick` and `styleValidInConfigVar`. These are a **pinned revision**, not a locally installed Hyprland version. Their corresponding `main` URLs returned 404. The available revision was used after unsuccessful current-path requests; unknown differences from current main are not presented as verified.
- **U4:** official hyprutils [AnimatedVariable.cpp](https://github.com/hyprwm/hyprutils/blob/main/src/animation/AnimatedVariable.cpp), `getPercent`, `getCurveStep`, and `resetSpringState`; [Spring.cpp](https://github.com/hyprwm/hyprutils/blob/main/src/animation/Spring.cpp), `advanceSpring`.
- **C1:** [Config.swift](../hook/swift/Sources/HyprCore/Config.swift), `HyprConfig.parent/animation/anim/popin`; [RuntimeConfig.swift](../hook/swift/Sources/HyprCore/RuntimeConfig.swift), `NativeRuntimeConfig.build`; [TextConfig.swift](../hook/swift/Sources/HyprCore/TextConfig.swift), `parse/validate`; [runtime.schema.json](../hook/config/runtime.schema.json), `$defs.animation`.
- **C2:** [WM.swift](../hook/swift/Sources/HyprCore/WM.swift), `apply/layout/sync/command/hide/followMouse/configured/confirmAcceptedFrame/tick`; [Channel.swift](../hook/swift/Sources/HyprCore/Channel.swift), `configureAppearance`.
- **C3:** [anim4.c](../hook/src/anim4.c), `spring_adv/retarget/step/frame_win/border_win/fade_colors/p8_make/p8_go`, command consumption, and the batch tick; [LiveEngine.swift](../hook/swift/Sources/hyprwm-swift/LiveEngine.swift), `replaceConfig/setup`.
- **C4:** [RestorePlacement.swift](../hook/swift/Sources/HyprCore/RestorePlacement.swift), `stageRestorePlacement/finishRestorePlacement/PlacementFrameAcceptance.accepted`; [Visibility.swift](../hook/swift/Sources/HyprCore/Visibility.swift), `restoreHidden/completeRestores/parkHidden/refreshWindowOpacity`.
- **C5:** [FocusRecovery.swift](../hook/swift/Sources/HyprCore/FocusRecovery.swift), `FocusRequest.targetAllows/sourceAllows/pointerAllows` and `queueFocus`; [LiveSys.swift](../hook/swift/Sources/hyprwm-swift/LiveSys.swift), `requestFocus/raiseAppFloats/preserveAppFloats/preserveFloatingWindows/redirectTargetModal/pointerHit`; [WMProduction.swift](../hook/swift/Sources/HyprCore/WMProduction.swift), `beginInteraction/updateSharedResize/endInteraction/setEnabled`.
- **C6:** [FirstMapAdmission.swift](../hook/swift/Sources/HyprCore/FirstMapAdmission.swift), `FirstMapAdmission.handle`, `FirstMapLayout.inserting`, and `claimAdmission`; [OrdinaryHandoff.swift](../hook/swift/Sources/HyprCore/OrdinaryHandoff.swift), `prepareOrdinaryBatch`; [birth_presentation.h](../hook/src/birth_presentation.h), `birth_clone_frame`; [presentation_carrier.h](../hook/src/presentation_carrier.h), `rgba_carrier_prepare`.
- **C7:** [Tile.swift](../hook/swift/Sources/HyprCore/Tile.swift), `need/splitBox/withGaps/removeReorientingPromoted`; [LiveBufferMotion.swift](../hook/swift/Sources/HyprCore/LiveBufferMotion.swift), `prepareLiveBuffer/pollLiveBufferShrinks`; [Close.swift](../hook/swift/Sources/HyprCore/Close.swift), `requestClose/confirmedCloseDeparture/observeCloseRequests`.
- **C8:** [WorkspaceCommand.swift](../hook/swift/Sources/HyprCore/WorkspaceCommand.swift), `workspaceCommand`; [SilentSpaceMove.swift](../hook/swift/Sources/HyprCore/SilentSpaceMove.swift), `sendWindowToSpace`; [NativeFullscreen.swift](../hook/swift/Sources/HyprCore/NativeFullscreen.swift), `updateNativeFullscreen`.
- **C9:** [MenuBar.swift](../hook/swift/Sources/hyprwm-swift/MenuBar.swift), `init/settings/presentOnCurrentSpace`; [Onboarding.swift](../hook/swift/Sources/hyprwm-swift/Onboarding.swift), `OnboardingView.advance` and `StartupMarkCanvas.layout`; [main.swift](../hook/swift/Sources/hyprwm-swift/main.swift), the reload handler; [RuntimeOptions.swift](../hook/swift/Sources/HyprCore/RuntimeOptions.swift), `load`.
- **C10:** [axlib.c](../hook/src/axlib.c), `element_flags`; [axpolicy.h](../hook/src/axpolicy.h), native AX classification flags. Current source includes distinct-owning-window transient evidence and an audiovisual document flag inferred from a file URL and UTType. Inference and a complete media-window policy must be distinguished.

**Lite:** this checkout has no `LiteEngine.swift`, `LiteOverlay.swift`, `LiteRuntime.swift`, `LiteSys.swift`, or selectable Lite entry point. [CONFIG.md](CONFIG.md#lite-applicability), [API.md](API.md), and AGENTS refer to the separate experimental `lite/2026-10-16` branch. Public raw URLs for those four files returned 404. Thus `L?` below means **Lite source is unavailable within the audited implementation; unverified**, not that a feature is proven absent from the historical branch. Documented Lite proxy/fade/workspace capabilities are not treated as executable-code evidence.

## Complete animation-tree inventory

All 34 public nodes in U1/U2 appear in `HyprConfig.parent` plus `global`; the schema and `NativeRuntimeConfig.build` recognize their keys (C1). This applies to enabled/curve/duration/time_scale parameters; **style** acceptance is narrower, as described below. “Present” means a source consumer was found; **live behavior remains unverified**. Parent nodes work through inheritance and have no separate visual event.

| Event | Hyprland (U1–U3) | Lite | Engine: actual consumer | Engine status / macOS constraint |
| --- | --- | --- | --- | --- |
| `global` | Root | L? | C1 build → effective leaves | Inheritance present; no separate animation |
| `windows` | Parent; slide/popin/gnomed | L? | C1 → C2/C3 | Partial: inheritance present, fewer styles |
| `windowsIn` | Opening | L? | C2 `apply`: geometry + C3 | Partial: centered scale/fade; visible arrival now moves from B without a new popin |
| `windowsOut` | Closing | L? | C2 `configureAppearance` → C3 `p8_go` | Partial: close-snapshot scale/fade; private backend |
| `windowsMove` | Move/resize | L? | C2 `apply`, C5 interaction → C3 | Path present; landing/frames unverified |
| `layers` | Parent; slide/popin/fade | L? | No event consumer; C1 stores records | Accepted without effect; no layer-shell equivalent, owned panels are feasible |
| `layersIn` | Layer entrance | L? | None | Accepted without effect; unimplemented |
| `layersOut` | Layer exit | L? | None | Accepted without effect; unimplemented |
| `fade` | Alpha parent | L? | C1 → C2/C4 | Inheritance for implemented descendants only |
| `fadeIn` | Opening alpha | L? | C2 `apply`, C4 restore | Path present; entrance channels share the batch epoch |
| `fadeOut` | Closing alpha | L? | C2 `hide/configureAppearance`, C3 `p8_go` | Path present; hide fades without windowsOut geometry |
| `fadeSwitch` | Active opacity | L? | C4 `refreshWindowOpacity` → C3 alpha | Partial: consumer present; transparency is documented as unfinished |
| `fadeShadow` | Active shadow | L? | C2 `configureAppearance` → C3 `border_win` / optional FX API | Partial: legacy Bezier; optional FX implementation outside this tree |
| `fadeGlow` | Active glow | L? | C2 `configureAppearance` → `ch_effects`, C3 FX API | Partial: requires `CH_CAP_EFFECTS`; a packet does not prove rendering |
| `fadeDim` | Inactive dim | L? | None | Accepted without effect; overlay dim is feasible |
| `fadeLayers` | Layer-alpha parent | L? | None | Accepted without effect |
| `fadeLayersIn` | Layer alpha entrance | L? | None | Accepted without effect; owned UI is feasible |
| `fadeLayersOut` | Layer alpha exit | L? | None | Accepted without effect; owned UI is feasible |
| `fadePopups` | Popup-alpha parent | L? | None | Accepted without effect; foreign popups belong to their application |
| `fadePopupsIn` | Popup alpha entrance | L? | None | Accepted without effect; owned popups are feasible |
| `fadePopupsOut` | Popup alpha exit | L? | None | Accepted without effect; owned popups are feasible |
| `fadeDpms` | Display on/off alpha | L? | None | Accepted without effect; no DPMS compositor ownership |
| `border` | Border color | L? | C2 `configureAppearance` → C3 `border_win/fade_colors` | Partial: real Bezier, substituted spring |
| `borderangle` | once/loop | L? | None; angle is static in Appearance.endpoints | Accepted without effect; owned borders could rotate |
| `shadowangle` | once/loop | L? | None | Accepted without effect; unimplemented |
| `glowangle` | once/loop | L? | None | Accepted without effect; unimplemented |
| `workspaces` | Workspace-transform parent | L? | C1 stores records; C8 backend does not read them | Accepted without effect; the OS animates native Spaces |
| `workspacesIn` | Group entrance | L? | None | Accepted without effect; custom native transition unimplemented |
| `workspacesOut` | Group exit | L? | None | Accepted without effect; a virtual compositor would be a separate feature |
| `specialWorkspace` | Scratchpad-transform parent | L? | None | Accepted without effect; no equivalent action backend |
| `specialWorkspaceIn` | Scratchpad entrance | L? | None | Accepted without effect; virtual grouping is feasible |
| `specialWorkspaceOut` | Scratchpad exit | L? | None | Accepted without effect; virtual grouping is feasible |
| `zoomFactor` | Screen zoom | L? | None | Accepted without effect; whole-desktop zoom needs a separate backend |
| `monitorAdded` | Connection zoom | L? | None | Accepted without effect; an owned reveal/reflow is feasible |

The consumer inventory searched `hook/swift/Sources`, `hook/src`, `hook/wm`, and `hook/effects`. Unimplemented branches have configuration/schema/default/preview references, but no event → presentation chain. A SwiftUI settings preview is not a production consumer. FX has [runtime_api.h](../hook/effects/runtime_api.h) and [config_command.h](../hook/effects/config_command.h), but the loaded module implementation is not in this source tree. Its output cannot be promised without the relevant capability and runtime evidence.

## Styles, curves, and inheritance

| Aspect | Hyprland | HyprWM source observation |
| --- | --- | --- |
| Window `slide [top/bottom/left/right]` | U3 `animationSlide`: preserves size; forced/nearest side | C1 text schema rejects slide and its side. Neither `apply` nor the close packet implements side selection |
| `popin N%` | U3 `animationPopin`: centered scaling | C1 accepts N 0…100; C2 concealed opening and C3 closing use scale. Visible opening moves from current B; restore uses windowsMove |
| `gnomed` | U3 `animationGnomed`: vertical unfold/collapse with fixed width | Rejected by the schema; no distinct geometry path |
| Workspace `slide/slidevert/fade/slidefade/slidefadevert N%` | U3 `startAnimation(workspace)`: offset/alpha; vertical percentage uses height, horizontal uses width | C1 build rejects workspace-style overrides. The schema accepts `slidefade{vert} N%` strings, but windowsIn/Out have no corresponding choreography |
| `once/loop` for `*angle` | U1: loop continuously renders, with a power cost | Schema rejects once/loop; enabled/curve/duration are recognized, but no angle is sampled |
| Bezier | U4: elapsed / (speed × 100 ms) | C3 `bezier_y/step`: elapsed time and a baked table; C1 text API converts duration_ms to speed |
| Spring | U4: physical parameters, analytic advance, separate stop criterion | C3 `spring_adv/step`: under/critical/overdamped, displacement and velocity tolerance ≤0.001; `retarget` preserves current B and projected velocity. This is source parity, not a duration measurement |
| Border/shadow spring | Generic animated variables use the curve (U3 `handleUpdate`, U4) | C2 `configureAppearance` writes Bezier `(0.25,1),(0.5,1)` for a legacy border/shadow spring. C3 CA uses those points; full spring color interpolation is absent. FX shadow receives a separate curve packet; its rendering is unverified here |
| Inheritance | U2: tree, nearest configured ancestor | C1 build merges ancestor fields into leaves; `HyprConfig.animation` reads the materialized record. However, global/windows.style also reaches unsupported leaves and is rejected; D4 |
| Units and slow motion | U1: speed in deciseconds; spring is not a fixed duration | C1 duration_ms/100 → speed, then `anim` speed ×0.1. Top-level time_scale/HYPRWM_TIME_SCALE default to scaling geometry; fade/border use their own event time_scale. Spring k becomes k/s² and damping d/s. Slowing geometry alone does not slow every fade |

The normal text pipeline applies schema validation before semantic build. Calling `NativeRuntimeConfig.build` directly without schema validation can accept arbitrary window-style strings; this does not make them supported by normal configuration. If an unknown style reaches the renderer, C2 uses `popin ?? 0` rather than slide/gnomed choreography. Empty style and fade also differ: a minimal centered size versus scale 1.

## The nine MOTION events: coverage and unverified behavior

No normal/slowed clips, onset−1 frame, first three frames, midpoint, last five frames, or final stable frame were collected. The ≤2 px tolerance, actual curve, duration, stale replay, and modal burial are **not established**. `trace/anim_cadence.d` and `trace/frame_pipeline.d` were read as measurement tools but not executed; tick counts do not replace frame acceptance.

| Event | What Engine source establishes | Gap / verification boundary |
| --- | --- | --- |
| Open | C2 `apply`: concealed scale/fade; visible arrival moves from current B after D2. C6 admission predicts a slot and checks owner/birth; native `birth_clone_frame` samples body/border together | A first-visible-B guarantee for every client is not established. FirstMapAdmission only accepts normal/resizable/nonmodal/nonchild/nongrouped clients. Live: unverified |
| Close | C7 confirms departure and keeps layout for Save/modal refusal; C3 `p8_go` starts scale/alpha with one now; C2 reflows survivors | Equality of the close-clone epoch and later Swift survivor publication is not established. Pending close clone `order(...,1,0)` needs plane verification. Live: unverified |
| Focus change | C5 guards against modal/menu/unknown contexts and avoids raising a tile; C4 alpha and C3 border color. C2 followMouse now considers explicit floats/classified-other receivers | Unknown native context, overlays, held buttons, and target primary eligibility still gate requests. Reported application/dialog cases were not reproduced. Border spring is unsupported. Live: unverified |
| 3→2 promotion | C7 `removeReorientingPromoted`; C2 sync/apply publishes survivors in one batch from current visible rectangles | Parallel configure does not establish the absence of intermediate cropping or late landing. Live: neither mirrored case verified |
| Swap/throw | C5 `endInteraction`: actual delta, dominant axis, distance/fastThrow, swap/insert; C2 apply | `beginInteraction` rejects moving/held actors; a slow gesture below the threshold is not a throw. These conditions do not establish the cause of a reported failure. Live: unverified |
| Shared-edge resize | C5 `updateSharedResize`: one cut coordinate, actor warp without a frame setter, neighbors through apply; C7 allocation policy | A missing native ACK or mismatched accepted frame interrupts interaction. Button-held focus protection exists. Shared-edge continuity is unverified live |
| Workspace switch | C8 delegates to a capability-gated native backend; WM freezes on an unstable Space | The Engine OS transition follows MOTION's separate native-Space allowance; custom workspacesIn/Out records have no consumer. Lite ±12% is unverified because its source is unavailable |
| Restore from hidden | C4 checks owner/birth/membership/ACK and bounds waiting; after D1, finish passes the recorded rectangle through restoreFrom/restoring into apply | The actor now receives windowsMove + fadeIn; staging still configures final A while concealed. B continuity and mirrored landing after the change are unverified live |
| Fullscreen toggle | C2 command changes full/fullmode; layout target → apply/windowsMove; border nofull shares the control path; C8 excludes native fullscreen | No separate fullscreen-visibility fadeIn channel or hide-other-tiles lifecycle equivalent to U3 `setFullscreenFadeAnimation`; ordinary opacity uses fadeSwitch. Live: unverified |

## Implementation findings and reproduction scenarios

“Code” identifies a direct contract/documentation mismatch. “Risk” identifies a specific coverage gap, not a proven visual failure. “Source changed” means the revised path was read; runtime acceptance remains pending. The scenarios below **were not executed** and have no captured frame evidence.

| ID / evidence type | Event, mode | Scenario | Evidence / relevant implementation | Frames |
| --- | --- | --- | --- | --- |
| D1 / code, source changed | Restore, Engine | Hide a tile, change layout, restore; repeat mirrored | The finish-only fade was replaced: C4 finishRestorePlacement sets restoring, restoreFrom=record.rect, target=nil, then apply. Revised commands were read; live result unverified | None; gate excluded |
| D2 / code, source changed | Open, Engine | Open a normal window already visible before admission/census | The warp was replaced: C2 presentedOpening sends geom from frm with windowsIn curve/duration, move=false/warp=false. It does not hide the visible client again; first frame and final content unverified | None |
| D3 / code | Window styles, Engine | Set windowsIn.style to slidefade 20% or slidefadevert 20% in normal configuration | C1 schema accepts the string; C2 scale uses popin ?? 0; C3 close is analogous. No movement direction/percentage consumer | None; source establishes absent choreography |
| D4 / code | Inheritance, shared parser | Set animations.windows.style to popin 86%, or set global.style | C1 build merges style into windowsMove/other leaves, then rejects unsupported style. TextConfig drops the invalid node with a warning. CONFIG promises parent-style support | None; validation-path evidence |
| D5 / code | Border, legacy Engine | Select a spring for animations.border and change focus | C2 substitutes fixed smooth Bezier points; C3 fade_colors uses a CA timing function rather than a spring | None |
| D6 / risk, source changed | Floating above tiles, Engine | Explicitly float resizable A; activate tile B in another application; open media from a file manager | Previously only same-PID native floats had preservation. C2 tick now supplies explicit floats/classified-other windows to C5 preserveFloatingWindows, which rechecks owner/birth/Space/foreground/context and submits the existing same-level native order command on the daemon main writer in reverse census order, without selecting a key window. The main writer rechecks current floating/hidden membership and native Space/level/visibility before publishing. Same-PID raiseAppFloats remains separate. Runtime order, focus retention, and modal interaction are pending | None; no reproduced pass/fail |
| D7 / risk, source changed | Dialog/focus, Engine | Hover a tile beneath Save/Open UI; repeat after overlay dismissal and across PIDs | C5 focus guards/native receiver and C2 retained-parent classification protect known modals. C2 followMouse now permits explicit floats/classified-other targets; C5 pointerHit resolves WID ownership rather than trusting event delivery PID. Worker primary/modal/unknown checks still apply. Classification/cache/receiver behavior needs runtime evidence | None |
| D8 / risk | Close/birth Z-order, Engine | Close during motion with a modal/float above; open a tile beneath a float | C3 p8_go orders a pending clone with order(...,1,0); C6 birth clone is above source. Ordinary carrier C6 instead goes below source with an explicit modal-preservation comment. Different presenter paths need coverage | None |
| D9 / code | Fullscreen visibility, Engine | Toggle tiled fullscreen/maximized with neighboring tiles | C2 changes geometry/nofull border; C4 uses fadeSwitch for focus/fullscreen opacity. No independent fullscreen fadeIn and hide-other-tiles lifecycle | None |
| D10 / risk | Throw, Engine | Compare a slow short horizontal throw, a fast throw, and a gesture before landing | C5 beginInteraction busy/held guards; endInteraction defaults of 32 pt, directionRatio 1.25, and accepted-size ±TOL. Capture native epoch and actual delta before changing thresholds | None; refusal cause unestablished |

**Minimum sizes and cropping.** Current C7 `splitBox` returns ratio partitions before consulting `need` whenever minimum_policy is ratio. In this branch, neither learned nor verified client minima alter the partition; production `withGaps` keeps presentation within its allocation. Native-policy allocation still considers minima, and C2 confirmAcceptedFrame additionally records stable accepted floors only for native policy. C4 PlacementFrameAcceptance explicitly permits A larger than B. This differs from the initial audit snapshot, where ratio allocation still consulted verified minima. The new ratio behavior is source-only and unverified on real clients. Cropping B does not make a client render a smaller internal viewport or add application-owned scrollbars; access to clipped menus/controls and native scrolling remains unverified. Space shortage alone is not a float criterion: C2 tileable uses role/style/owner policy. C10 now infers audiovisual file documents through AXDocument and UTType, but an inferred media flag is not itself proof that every media window stays floating or opens naturally above its file-manager source.

## Accepted but ineffective keys and documentation mismatches

| Key / documented statement | Source finding |
| --- | --- |
| layers{,In,Out}, fadeDim, fadeDpms, fadeLayers{,In,Out}, fadePopups{,In,Out}, *angle, workspaces{,In,Out}, specialWorkspace{,In,Out}, zoomFactor, monitorAdded | C1 records exist, but no Engine event/presentation consumer. CONFIG's accepted-but-not-yet-effective status is supported; parsing does not imply a corresponding API action |
| runtime.startup_animation | C9 RuntimeOptions.load passes the flag to MenuBar init, which does not read it. CONFIG correctly marks it ineffective; onboarding logo animation exists independently |
| CONFIG: windowsOut is consumed by WM close/hide | Production close uses native p8; WM.hide reads fadeOut, without windowsOut geometry. The wording exceeds the actual consumer |
| CONFIG: global/windows styles are supported | D4: inherited style causes semantic rejection. Validator or documentation needs correction |
| CONFIG: general spring/event-curve interface | D5: border spring passes configuration, but the legacy renderer gets fixed Bezier points. SettingsPreviews hides spring for border/fadeShadow; that is not a parser restriction |
| CONFIG: windowsIn is opening geometry | Concealed opening scales; visible arrival after D2 moves from current B without another popin; production restore after D1 uses windowsMove. Frame evidence remains absent |
| CONFIG: Lite motion/fades/borders | Not verified against this checkout's source; the documentation identifies a separate branch. These are not Engine-only runtime capabilities |
| MOTION: one epoch and current B/velocity | C3 retarget/batching implements the core contract; after D1 restoreFrom reintroduces recorded B before reveal. Stage→apply handoff and close-clone/survivor epochs still need frame/timestamp evidence |
| Minimum allocation / floating policy | Source now has a ratio partition bypass, cross-PID floating preservation, and broader hover-target selection. These updates supersede the initial code findings but remain pending runtime validation |

## User actions and transition coverage

The action inventory read [API.md](API.md), WM.command, the [hyprwmctl wrapper](../scripts/hyprwmctl), baseline [hyprland.lua](../hook/config/defaults/.config/hypr/hyprland.lua), and NativeHotkeys. A Lua dispatcher in the baseline does not establish that the native daemon implements its Linux action. “Present” below always denotes a source path, not a live pass.

| Action / API / hotkey | Engine behavior in source | Lite |
| --- | --- | --- |
| Directional / pointer focus | Border + fadeSwitch, without geometry configure; C5 guards. Hover now considers explicit floats/classified-other receivers, still subject to worker eligibility | L? |
| Directional move / swap | windowsMove through C2 moveDir/apply | L? |
| Titlebar throw / drag insert | C5 interactive native drag, then windowsMove if the gesture is accepted | L? |
| Pointer shared-edge resize | Direct/warp neighbors; C5 updateSharedResize without easing the pointer-owned edge | L? |
| Keyboard resize, balance, togglesplit | windowsMove for changed targets; C2 command/apply | L? |
| Retile/reset | Apply only changed targets; reset clears layout/minima, without a separate effect | L? |
| Preselect | Changes future insertion policy; no distinct indicator/animation in C2 command | L? |
| Float: tile → float | Releases a landed projection/decoration; actor gets no separate scale/move, neighbors reflow. C2 tick now requests cross-PID floating preservation through C5; runtime pending | L? |
| Float: float → tile | Sync/opening path → apply; visible-arrival choreography follows D2 | L? |
| Pseudotile | No native command/backend in C2; missing functionality rather than an abrupt animation | L? |
| Tiled fullscreen/maximized | windowsMove and border policy; incomplete fullscreen fade lifecycle, D9 | L? |
| Native macOS fullscreen | OS lifecycle/transition; C8 excludes ordinary configure | L? |
| Workspace / previous / wsstep / new | C8 capability-gated native Space backend; OS transition does not consume animation records | L? |
| sendws | C8 changes membership without a dedicated actor slide/fade; survivors apply | L? |
| moveworkspace N follow/silent | API identifies this as Lite. Native WM.command does not implement that name; Engine sendws/launcher transfer are separate paths | L? |
| Special workspace | No action backend; scratch hidden metadata/filtering is not a switchable specialWorkspace | L? |
| Hide / unhide | Hide fadeOut → verified parking; restore after D1 passes recorded B to windowsMove + fadeIn after accepted final A; C4 | L? |
| Restore-all / pause / resume / rescue | Recovery/visibility correctness; instant restore/warps serve recovery rather than a decorative event; C5 setEnabled/C4 | L? |
| Close / quit application | Native p8 close + survivors; quit follows the application's native lifecycle and subsequent close observations; C7 | L? |
| Exec / summon an existing window / launcher | Native opening or ownership/Space transfer. C2/C4 arrivals changed in D1/D2; LauncherArrival separately preplaces hidden before reveal. Consistent visual results across all paths are unverified | L? |
| WM menu/settings/overlays | NSMenu / makeKeyAndOrderFront and SwiftUI; no owned layerIn/Out channels; C9 | L? |
| Onboarding | Own opacity/move transitions of 0.2–0.25 s, logo entrance of 0.6/0.7 s, logo-tile stagger of 70 ms; Reduce Motion handling; C9. This is UI motion, not tile-burst staggering | L? |
| startup_animation | Unused flag in C9 init; onboarding is not evidence of it working | L? |
| Hot reload: gaps/layout/rules | C9 reload calls apply; windowsMove when targets change | L? |
| Hot reload: appearance/curves/focus | Appearance updates packets without reflow. Compatible curves replace immediately; incompatible ones wait for idle with bounded retries. No separate configuration-change animation; C9/C3 | L? |
| Monitor connection | Census/layout changes may send changed targets through windowsMove; monitorAdded zoom consumer absent; C2/C1 | L? |
| macOS tabs | C2 sync explicitly replaces identity/reveals the retained tile without popin; separate tab motion belongs to OS/application | L? |
| Status / subscriptions / doctor / print-config / import | Read/diagnostic/configuration actions need no distinct motion. Import/reload affects later events, not CLI animation | L? |

## Remaining work by visibility and complexity

Complexity is relative to the current architecture, not a delivery estimate. A public macOS backend limitation does not make every approximation using owned surfaces impossible. A private Engine capability likewise does not establish support across every system/SIP configuration.

| Priority | Missing behavior / user visibility | Complexity | macOS feasibility and nearest implementation |
| --- | --- | --- | --- |
| 1 | Verified natural summon/restore, without an abrupt final rectangle | Medium–high | D1/D2 source changed; stage→presentation/landing and the separate LauncherArrival path remain unverified. Preserve identity/ACK and bounded reveal |
| 2 | Verified floating-above-tiled behavior across applications; natural auxiliary/media opening | Medium | C5 preserveFloatingWindows and C2 tick now implement cross-PID preservation; followMouse accepts more receivers. Modal/focus behavior and media classification remain pending runtime evidence; a standard resizable AX window alone cannot express intended presentation |
| 3 | Complete dialog/input/plane coverage during open/close/retarget | High | Existing protection shows this is not a general OS prohibition, but different presenters and delayed native metadata need consistent ownership; C5/C6/C3 |
| 4 | Predictable accepted throws that preserve horizontal intent | Medium | Path present; establish native epoch/delta/refusal threshold in C5 before introducing a different drag system |
| 5 | Verified ratio/crop behavior and access to clipped content | High | C7 ratio mode now bypasses client minima for partitioning. It does not add client-internal scrolling or force arbitrary content reflow; input/presentation behavior requires runtime evidence, C7/C2/C4 |
| 6 | Fullscreen visibility fade and coherent neighbor lifecycle | Medium | Feasible for tiled fullscreen through owned alpha channels; native fullscreen keeps the OS lifecycle; C2/C4/C8 |
| 7 | Window slide/side/gnomed; working parent styles and spring border | Low–medium | B transforms/CA/evaluation already exist; C1/C2/C3. Resolve accepted-but-ineffective combinations first |
| 8 | Virtual workspace/special-workspace choreography | High | Feasible as a separate group with capture/parking/recovery; distinct from changing native Space timing. Lite source/evidence must be assessed separately |
| 9 | WM panel/menu transitions, monitor reveal, dim | Low–medium | Feasible for owned surfaces; C9. Foreign NSMenu/AppKit popups belong to their applications |
| 10 | Angle loops, glow/shadow angle, whole-screen zoom, DPMS fade | Medium–high | Owned decoration loops are feasible; desktop/DPMS need separate ownership. Lower priority than arrival/floating behavior; continuous loops have the cadence/power cost described in U1 |

This report provides the complete source inventory and explicit implementation/evidence boundaries. A green build, settings preview, capability flag, or historical ledger has not been substituted for missing frame evidence.

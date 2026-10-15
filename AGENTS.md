# HyprWM contributor map

HyprWM is an experimental macOS tiling WM. Distinguish implementation, automated checks and live evidence. The active task runbook takes precedence.

## Map and commands

| Concern | Source |
| --- | --- |
| State, apply, census, hide/restore, pointer focus | `hook/swift/Sources/HyprCore/WM.swift` |
| Pause, activation, transfer, drag | `HyprCore/WMProduction.swift` |
| Split tree, geometry, promotion | `HyprCore/Tile.swift` |
| Engine recovery and startup preflight | `HyprCore/EngineRecovery.swift`, runtime `EngineStatePreflight.swift` |
| Focus, dialog policy and restoration | `HyprCore/FocusPolicy.swift`, `FocusRecovery.swift`, `RestorePlacement.swift`, `LauncherArrival.swift` |
| Rules, config, migration | `HyprCore/WindowProperties.swift`, `TextConfig.swift`, `RuntimeConfig.swift`, `ForeignConfigImport.swift` |
| Entry, real AX/Space/process access, engine | `hook/swift/Sources/hyprwm-swift/main.swift`, `LiveSys.swift`, `LiveEngine.swift` |
| Lite runtime, AX, recovery, proxy/borders, shortcuts | `LiteRuntime.swift`, `LiteAX.swift`, `LiteSys.swift`, `LiteRestorePump.swift`, `LiteEngine.swift`, `LiteOverlay.swift`, `LiteHotkeys.swift`, `LiteWorkspaceReceiver.swift` in the runtime target |
| Settings, menu, shortcuts | `Settings*.swift`, `MenuBar.swift`, `NativeHotkeys.swift` in that runtime target; `hook/keys/` |
| Native engine and bridge | `hook/src/`, `hook/wm/`, `hook/identity/` |
| Tests, schema, package | `hook/swift/Tests/`, `hook/config/runtime.schema.json`, `hook/swift/build_app.sh` |
| User references | `docs/CONFIG.md`, `docs/MIGRATING.md`, `docs/TROUBLESHOOTING.md`, `docs/API.md` |

Paths abbreviated `HyprCore/` above are relative to `hook/swift/Sources/`.

```sh
swift build -c release --package-path hook/swift
swift test --package-path hook/swift
git diff --check
```

Binary: `hook/swift/.build/release/hyprwm-swift`; wrapper: `scripts/hyprwm`; live status: `scripts/hyprwmctl status`. `./install.sh` installs without launching; `zsh hook/swift/build_app.sh` builds the separate menu companion. Config: `~/.config/hyprwm/hyprwm.conf` / `HYPRWM_CONFIG`. Control: `/tmp/hyprwm.ctl` / `HYPRWM_CTL`. `hook/start.sh`/`stop.sh` delegate to `hook/lifecycle.py`; inspect its runtime selection before launching.

## Work discipline

1. Record git state and affected baseline before editing; preserve unrelated work. Small diffs, one scenario per English commit; stage exact paths. Commit or record the blocker every 60–90 minutes.
2. Log checks with time, commit, result and evidence. Rerun only after a relevant change. Record pre-existing failures once. Docs normally need source/command/link verification.
3. Timebox bugs to 40 minutes or three failed hypotheses. Record blocker and next new hypothesis, then move on. During stabilization: no refactors, renames or new frameworks; diagnostic tooling gets 20 minutes maximum.
4. Revert baseline regressions immediately. Integration requires a rebuild and affected baseline rows passing. Freeze permits regression fixes only; time running out never completes a milestone.
5. Save progress at phase boundaries. After compaction, reread runbook and ledger; never repeat recorded failed approaches.

## Evidence and baseline matrix

Keep scenario ID, baseline/current status, build and evidence in one matrix. Cover focus, dialogs, restore/transfer, layout, motion/first-frame/tabs/bursts, resize/throw, config, pause, IPC/import, Lite, recovery and installation. Use the active runbook's full matrix.

A live pass needs **two of three** on the current build/session: expected IPC state; native key/input truth; inspected screenshot/clip. Builds, tests and settings previews never prove desktop behavior. For motion inspect first three, midpoint and final five actual frames: body/border divergence ≤2 px, no jump/flash, exact landing. Use disposable windows, verify recovery, close only test windows. One desktop lease/operator at a time.

## Hard lines

- Never kill/restart WindowServer, Dock, loginwindow or owner apps. A wedged engine is a reason to use Lite, not restart the session.
- Never change SIP, NVRAM or boot arguments during a stabilization run. Touch `/etc` only for a specifically authorized temporary sudoers drop-in.
- Never use `git reset --hard`, `git clean`, `git add -A`, force-push or stash-pop onto a changed tree. Do not merge into `main` or publish releases/issues/posts without explicit authorization.
- Never commit caches, private screenshots, title-bearing logs, credentials or machine-specific absolute paths.
- Never overwrite owner configuration except through the validated writer during an authorized test after a backup. Keep file operations reversible; never move owner files without an agreed manifest and restoration path.
- No app-name/bundle-ID special cases in focus, dialog or layout policy. Preserve identity, birth, sequence and epoch guards; make refusals bounded and recoverable.
- Keep hidden-window Mission Control off by default and user transparency labeled unfinished until live evidence establishes otherwise. Do not fabricate media, broaden platform compatibility or call a checkout-dependent companion a standalone installer.

The optional `.githooks/post-commit` runs `git pull --rebase && git push`. Set the correct branch upstream before committing. If synchronization fails on inherited dirt, preserve the commit and report it; never discard unrelated work to satisfy the hook.

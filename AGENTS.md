# HyprWM contributor map

HyprWM is an independent experimental macOS tiling window manager. Read this file in two minutes, then inspect the code for the behavior you are changing. Distinguish implementation, automated checks and live evidence in every claim. A task-specific runbook takes precedence over this reference.

## Map and commands

| Concern | Source |
| --- | --- |
| State, apply, census, hide/restore, pointer focus | `hook/swift/Sources/HyprCore/WM.swift` |
| Pause, activation, transfer, drag | `HyprCore/WMProduction.swift` |
| Split tree, geometry, promotion | `HyprCore/Tile.swift` |
| Focus, dialog policy and restoration | `HyprCore/FocusPolicy.swift`, `FocusRecovery.swift`, `RestorePlacement.swift`, `LauncherArrival.swift` |
| Rules, config, migration | `HyprCore/WindowProperties.swift`, `TextConfig.swift`, `RuntimeConfig.swift`, `ForeignConfigImport.swift` |
| Entry, real AX/Space/process access, engine | `hook/swift/Sources/hyprwm-swift/main.swift`, `LiveSys.swift`, `LiveEngine.swift` |
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

The release binary is `hook/swift/.build/release/hyprwm-swift`. `scripts/hyprwm` locates the checkout's binary; `scripts/hyprwmctl status` queries a running daemon. Packaging: `zsh hook/swift/build_app.sh` (preserves an existing bundle). Configuration: `~/.config/hyprwm/hyprwm.conf`, overridden by `HYPRWM_CONFIG`. Control: `/tmp/hyprwm.ctl`, overridden by `HYPRWM_CTL`. Read source before selecting a live lifecycle command; legacy `hook/start.sh`/`stop.sh` manage the Python path.

## Work discipline

1. Record git state and the affected behavior's baseline before editing. Preserve unrelated dirty/untracked work. Small diffs, one scenario per English commit; stage exact paths. Commit or explain the blocker every 60–90 minutes during a long run.
2. Record each check with time, commit, result and evidence path. Do not rerun it without a relevant code change. A pre-existing failure is recorded once. For documentation, source/command/link verification is normally sufficient.
3. Timebox a bug to 40 minutes or three failed hypotheses. Record the specific blocker and next new hypothesis, then take the next item. No refactors, renames or new frameworks during a stabilization run; new diagnostic tooling is capped at 20 minutes.
4. A passing baseline scenario must stay passing. Revert a change that creates a regression immediately. Integration requires a rebuild and the affected baseline rows to pass; freeze means regression fixes only. Never mark a milestone done because time ran out.
5. Save compact progress at phase boundaries. After compaction, reread the active runbook and check ledger. Never repeat an approach already recorded as failed.

## Evidence and baseline matrix

Keep one matrix with scenario ID, baseline, current status, build and evidence. Include focus (mouse/close/drag/Space), dialogs, hide/restore and transfer, insertion/removal/promotion, animation retarget/landing, first frame/tabs/bursts, resize/throw, config reload/appearance isolation, pause/resume, IPC/import, Lite, recovery and installation. Use the active runbook's complete matrix when provided.

A live pass needs **two of three** on the current build/session: (1) `hyprwmctl status` with expected tree/rects/focus/hidden list, (2) native truth such as the real key window or text landing correctly, (3) an inspected screenshot or sampled motion clip. Builds, unit tests and settings previews never prove desktop behavior. Motion review inspects first three, midpoint and final five frames: body/border divergence ≤2 px, no jump/flash, exact target landing. Use disposable test windows; record recovery and close only those windows afterwards. Only one operator holds the live desktop lease at a time.

## Hard lines

- Never kill/restart WindowServer, Dock, loginwindow or owner apps. A wedged engine is a reason to use Lite, not restart the session.
- Never change SIP, NVRAM or boot arguments during a stabilization run. Touch `/etc` only for a specifically authorized temporary sudoers drop-in.
- Never use `git reset --hard`, `git clean`, `git add -A`, force-push or stash-pop onto a changed tree. Do not merge into `main` or publish releases/issues/posts without explicit authorization.
- Never commit caches, private screenshots, title-bearing logs, credentials or machine-specific absolute paths.
- Never overwrite owner configuration except through the validated writer during an authorized test after a backup. Keep file operations reversible; never move owner files without an agreed manifest and restoration path.
- No app-name/bundle-ID special cases in focus, dialog or layout policy. Preserve identity, birth, sequence and epoch guards; make refusals bounded and recoverable.
- Keep hidden-window Mission Control off by default and user transparency labeled unfinished until live evidence establishes otherwise. Do not fabricate media, broaden platform compatibility or call a checkout-dependent companion a standalone installer.

The optional `.githooks/post-commit` runs `git pull --rebase && git push`. Set the correct branch upstream before committing. If synchronization fails on inherited dirt, preserve the commit and report it; never discard unrelated work to satisfy the hook.

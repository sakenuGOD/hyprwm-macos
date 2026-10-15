# Contributing to HyprWM

Improve one concrete window-management behavior and make its verification reproducible. Read [AGENTS.md](AGENTS.md) for the source map and safety boundaries, then check the [roadmap](docs/ROADMAP.md) and existing issues for overlapping work.

## Build

The Swift package requires macOS 14 or later and Swift 5.9 or later. Install Xcode Command Line Tools. The native engine has additional development-system requirements; a build alone does not establish its compatibility with your macOS version.

From the repository root:

```sh
swift build -c release --package-path hook/swift
swift test --package-path hook/swift
git diff --check
```

The executable is `hook/swift/.build/release/hyprwm-swift`. `scripts/hyprwm --help` shows dry CLI modes. The repository also contains Python/Lua and native integration paths; do not assume `hook/start.sh` selects the Swift runtime. See [packaging](hook/swift/PACKAGING.md) for app bundles and their current distribution limits.

## Choose the narrowest check

Layout, configuration, import and command policy belong in `HyprCore` with deterministic tests. OS adapters live in `hyprwm-swift`; native render and ownership protocols live under `hook/src`/`hook/wm`. Preserve PID/window-birth and epoch guards when changing lifecycle behavior. Prefer generic role/modal/parent signals to app names.

Run a relevant test filter while iterating, then the appropriate completion gate. Record a pre-existing failure once. Do not repeat the same test without a relevant change. Documentation-only changes need command, default, source and relative-link verification; they do not need a new full native build merely to prove prose.

A build or unit test does not prove focus, keyboard routing, visibility or motion. For live work, arrange one desktop operator, use windows you opened yourself, record the build/config/permissions and baseline, then inspect the result. A pass requires two of: expected IPC state, native focus/input truth, and inspected screenshot/clip evidence. Cover the affected baseline rows and restore every test window before leaving. Never attach to WindowServer or change a running session as part of routine automated checks.

For motion, inspect first frames, retargets and landing in real capture: body and border stay together, no old-position flash, no final snap and no invisible survivors. For recovery, verify orderly shutdown and the documented crash path. For config, verify an invalid line does not discard a valid edit, atomic-save reload survives, and appearance edits do not move windows.

## Propose a change

A bug report needs exact steps, expected/actual behavior, macOS version, build identifier, mode, relevant configuration and a checkable acceptance criterion. Remove private titles, application content, personal paths and credentials before sharing evidence. Do not attach an unsanitized window inventory.

Keep pull requests scoped. Lead with the concrete trigger and resulting behavior, then describe meaningful validation and limits. Separate implemented code from live-verified behavior. Public strings and new documentation are English; preserve historical notes. Do not replace real product media with generated screenshots.

Preserve existing changes, stage exact paths and use an English commit message for one scenario. During stabilization, timebox a bug to 40 minutes or three failed hypotheses and record what would unblock the next attempt. A change that breaks a passing baseline row must be reverted before integration.

## Optional synchronization hook

```sh
scripts/setup-hooks.sh
```

This sets `core.hooksPath=.githooks`; the post-commit hook runs `git pull --rebase && git push`. A commit may therefore publish the current branch immediately. Establish the intended upstream first. If inherited dirty work blocks rebase, preserve both the new commit and the unrelated work, report the failure, and use a normal push only when safe. Never force-push to conceal a synchronization problem. Disable the local hook setting with `git config --unset core.hooksPath` when appropriate.

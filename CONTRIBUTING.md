# Contributing to HyprWM

HyprWM is an independent experimental macOS window manager. Contributions should improve a concrete behavior and make its verification reproducible. Check [existing issues](https://github.com/sakenuGOD/hyprwm-macos/issues) and the [roadmap](docs/ROADMAP.md) before opening overlapping work.

## Build and checks

Use macOS with Xcode Command Line Tools and the Swift toolchain required by [Package.swift](hook/swift/Package.swift). From the repository root:

```sh
swift build -c release --package-path hook/swift
swift test --package-path hook/swift
git diff --check
```

The release executable is `hook/swift/.build/release/hyprwm-swift`. Building it does not install the native engine or start a window manager. `hook/swift/build_app.sh` creates an ad-hoc signed local **menu companion** bundle and manifest, preserving an existing output path. It embeds the build checkout path and does not create a standalone distribution. The legacy `hook/start.sh` starts the Python daemon; it does not select the Swift runtime.

Read [AGENTS.md](AGENTS.md) before changing runtime or native integration. Do not launch a daemon, attach to WindowServer, or change system security settings as part of routine build/test checks.

## Source map

| Area | Location |
| --- | --- |
| Layout and window-management policy | `hook/swift/Sources/HyprCore/` |
| Text configuration and runtime schema | `HyprCore/TextConfig.swift`, `hook/config/runtime.schema.json` |
| Runtime entry point and native adapters | `hook/swift/Sources/hyprwm-swift/` |
| Settings, onboarding, menu bar | `Settings*.swift`, `Onboarding.swift`, `Menu*.swift` in the runtime target |
| Native engine and bridges | `hook/src/`, `hook/wm/`, `hook/identity/` |
| Deterministic tests and fixtures | `hook/swift/Tests/` |
| Packaging | `hook/swift/build_app.sh`, `hook/swift/tools/package_app.py` |
| Command and configuration reference | [docs/API.md](docs/API.md) |

## Verification and manual QA

Use the smallest meaningful automated check, then the appropriate build/test gate. Explain what ran and remaining limits in the pull request. Documentation changes need source/link checks; runtime changes need relevant regression tests.

Live desktop testing must be deliberately scheduled with one operator. Record macOS version, build identifier, permissions, configuration, steps, expected/actual results, and recovery result. Sanitize logs and screenshots before sharing. Manual QA should cover:

- Opening, tiling, resizing, moving, closing, hiding/restoring, and orderly shutdown with all windows restored.
- Focus after close, pointer focus, app activation, and keyboard routing.
- Modal dialogs and sheets, including cancellation and owner-window focus.
- Zen browser tabs, multiple windows, fullscreen, close/reopen, and restoration.
- Rapid repeated opens/closes/moves and animation retargeting, without stranded windows or transforms.
- Mission Control entry/exit and selection, testing the default separately from the experimental hidden-window opt-in.
- Appearance changes and transparency, with explicit evidence before marking unfinished behavior complete.

Passing unit tests or compiling a preview does not pass these live checks. Keep unverified scenarios marked unverified.

## Issues and pull requests

For a bug, include a small reproduction, expected/actual behavior, version/build, relevant settings, and a concrete acceptance criterion. For an enhancement, explain the user problem and how completion can be checked. Never include private application content, personal paths, credentials, or unsanitized window inventories.

Keep changes scoped, preserve user edits, and document externally visible changes. Use existing `bug` and `enhancement` labels; use `good first issue` only for bounded tasks with clear guidance.

## Optional automatic synchronization

```sh
scripts/setup-hooks.sh
```

This configures `core.hooksPath=.githooks`. Every commit then runs `git pull --rebase && git push` through `post-commit`, so committing can immediately publish your branch. Ensure its upstream is correct before enabling or committing. Network/rebase failures need resolution before assuming publication; avoid force pushes. To stop using this local setting, run `git config --unset core.hooksPath`.

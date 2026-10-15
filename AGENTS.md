# Repository guidance

HyprWM is an independent experimental macOS window manager. Public documentation must distinguish implemented code, automated checks, and behavior verified on a live desktop.

## Scope and source map

- `hook/swift/Sources/HyprCore/`: layout, state, configuration, command protocol, and testable runtime policy.
- `hook/swift/Sources/hyprwm-swift/`: native adapters, daemon entry point, settings, menu companion, and shutdown.
- `hook/swift/Tests/`: deterministic tests and fixtures; success does not establish live WindowServer behavior.
- `hook/src/`, `hook/wm/`, `hook/identity/`: native engine, bridges, and process/window identity integration.
- `hook/config/`: schema, Lua compatibility code, and default configuration inputs.
- `hook/swift/build_app.sh`, `hook/swift/tools/package_app.py`: local app packaging and build receipts.
- `docs/API.md`: interface reference; `docs/ROADMAP.md`: unfinished work and validation gates.

## Checks

Run from the repository root:

```sh
swift build -c release --package-path hook/swift
swift test --package-path hook/swift
git diff --check
```

For documentation-only changes, verify names, commands, defaults, and relative links against source; a new full native build is unnecessary. Do not add tests that merely mirror prose.

Do not start, stop, inject into, attach a debugger to, or reconfigure the live window manager merely to verify documentation or packaging. Native desktop QA requires explicit task authorization and one operator at a time. Never claim GUI, device, or WindowServer validation from compile/test output.

## Configuration and release truth

The editable configuration is `~/.config/hyprwm/hyprwm.conf`, overridden by `HYPRWM_CONFIG`. Preserve user configuration and unrelated changes. Keep hidden-window Mission Control off by default and describe it as in progress; transparency is unfinished. Focus/dialog/Zen/animation-burst behavior remains unverified until actual manual evidence is recorded.

Current packaging creates a menu companion with a source-checkout dependency and does not install the native engine. Do not describe a DMG as a standalone installer or broaden compatibility claims beyond evidence. Do not publish private diagnostics, window titles, local paths, or fabricated screenshots.

## Commit synchronization

`scripts/setup-hooks.sh` enables `.githooks` through `core.hooksPath`. The current `post-commit` hook runs `git pull --rebase && git push`; a commit can therefore contact the remote and publish the branch immediately. Inspect branch/upstream and the staged diff before committing. If synchronization fails, report the actual failure and preserve the commit; do not force-push or discard other work.

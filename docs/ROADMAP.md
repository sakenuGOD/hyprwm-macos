# Roadmap

This tracks unfinished work, not promised release dates. A passing build or deterministic test is evidence about code; desktop behavior needs separately recorded manual verification.

| Work | Current status | Completion gate |
| --- | --- | --- |
| [Standalone installation](https://github.com/sakenuGOD/hyprwm-macos/issues/1) | App is a menu companion; installed engine, compatible daemon, and source checkout required | Install/uninstall on a clean supported Mac without a developer checkout; package required resources and document native prerequisites |
| [Hidden windows in Mission Control](https://github.com/sakenuGOD/hyprwm-macos/issues/2) | In progress; experimental opt-in **off by default** | Repeat entry/exit/selection/cancellation, restoring exact windows without duplicate/missing cards, focus loss, or stranded geometry |
| [Window transparency](https://github.com/sakenuGOD/hyprwm-macos/issues/3) | Unfinished | Verify configured opacity across focus, movement, animation, fullscreen, hide/restore; restore original opacity on shutdown |
| [Focus and dialogs](https://github.com/sakenuGOD/hyprwm-macos/issues/4) | Live validation outstanding | Validate focus after close, pointer focus, activation, sheets, and modal dialogs with repeatable steps and sanitized evidence |
| Zen browser compatibility | Live validation outstanding | Validate tabs, multiple windows, fullscreen, close/reopen, and restoration without stale identity or focus |
| Animation bursts | Live validation outstanding | Stress repeated open/close/move/resize and retargeting; establish no stranded transforms/windows and record measured results |
| Compatibility and distribution | Build minimum macOS 14; native compatibility not established across versions | Publish tested OS/architecture matrix, verifiable build receipts, release assets, and installation/recovery results |

Track work in [GitHub issues](https://github.com/sakenuGOD/hyprwm-macos/issues). See [contribution guidance](../CONTRIBUTING.md) for reproduction and manual QA requirements. Do not enable experimental behavior by default to make this checklist appear complete.

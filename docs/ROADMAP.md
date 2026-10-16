# Roadmap

This tracks unfinished work, not promised release dates. A passing build or deterministic test is evidence about code; desktop behavior needs separately recorded manual verification.

| Work | Current status | Completion gate |
| --- | --- | --- |
| [Standalone installation](https://github.com/sakenuGOD/hyprwm-macos/issues/1) | Source installer packages a user-local app with bundled config and CLI without launching it. Engine still requires an already verified native installation; a clean public checkout of `9be1b54` passed no-launch packaging, CLI/import/backup and offline uninstall checks. Live stranger installation remains blocked by native runtime dependencies. Lite remains on its experimental branch | Complete tracked runtime dependencies and a supported stranger install; separately pass the Lite live gate, clean-machine permissions and restoration |
| [Hidden windows in Mission Control](https://github.com/sakenuGOD/hyprwm-macos/issues/2) | Hidden-window overview is experimental and **off by default**; visible Engine-managed cards can also be missing with the pool off | Repeat entry/exit/selection/cancellation, restoring exact windows without duplicate/missing cards, focus loss, or stranded geometry |
| [Window transparency](https://github.com/sakenuGOD/hyprwm-macos/issues/3) | Unfinished | Verify configured opacity across focus, movement, animation, fullscreen, hide/restore; restore original opacity on shutdown |
| [Focus and dialogs](https://github.com/sakenuGOD/hyprwm-macos/issues/4) | Live validation outstanding | Validate focus after close, pointer focus, activation, sheets, and modal dialogs with repeatable steps and sanitized evidence |
| [Zen browser compatibility](https://github.com/sakenuGOD/hyprwm-macos/issues/5) | Live validation outstanding | Validate tabs, multiple windows, fullscreen, close/reopen, and restoration without stale identity or focus |
| [Animation bursts](https://github.com/sakenuGOD/hyprwm-macos/issues/6) | Live validation outstanding | Stress repeated open/close/move/resize and retargeting; establish no stranded transforms/windows and record measured results |
| Compatibility and distribution | Build minimum macOS 14; source install is ad-hoc signed, not notarized; native/SIP-on compatibility is not established across OS/hardware versions | Publish tested OS/architecture matrix, verifiable build receipts, release assets, and installation/recovery results |

Track work in [GitHub issues](https://github.com/sakenuGOD/hyprwm-macos/issues). See [contribution guidance](../CONTRIBUTING.md) for reproduction and manual QA requirements. Do not enable experimental behavior by default to make this checklist appear complete.

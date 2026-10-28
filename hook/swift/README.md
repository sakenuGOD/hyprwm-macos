# Swift package

HyprWM's daemon, layout policy, configuration, CLI and Settings live here.
Build with macOS 14+ and Swift 5.9+. Tiling requires the separately installed
native engine on macOS 26.7.1 (25G241), Apple silicon.

## Build and test

From the repository root:

```sh
./scripts/build-hyprwm
./scripts/test-hyprwm
```

The release executable is `hook/swift/.build/release/hyprwm-swift`.
The test wrapper generates ignored scenarios from the Python reference models.
Keep `REFERENCE_*.py`; they define inputs for the Swift comparison tests.

## Targets

| Target | Purpose |
| --- | --- |
| `HyprCore` | Layout, configuration, commands, focus and recovery policy. |
| `hyprwm-swift` | Daemon entry, native adapters, menu, SwiftUI Settings and CLI. |
| `CAX` | Accessibility and macOS window access. |
| `CChan` | Shared native engine channel. |
| `CSnap` | Window snapshots. |
| `HyprCoreTests` | Deterministic configuration, layout, protocol and policy checks. |

## Run and package

`./scripts/hyprwm --help` shows the runtime arguments.
Use `./scripts/hyprwm --print-config` to inspect configuration without starting a daemon.
`./install.sh` builds the runtime app without launching it.
`zsh hook/swift/build_app.sh` builds a menu companion for an existing daemon.
Keep the checkout after installation. Read [packaging and contribution notes](../../CONTRIBUTING.md#how-the-app-bundle-is-built).

See [installation](../../docs/INSTALL.md), [configuration](../../docs/CONFIG.md)
and the [CLI reference](../../docs/CLI.md). Swift tests cannot verify desktop animation or input.

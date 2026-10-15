# HyprWM for macOS

HyprWM is an independent, experimental tiling window manager that brings Hyprland-inspired binary split layouts and motion to macOS. Open a window and the layout makes room; move focus or rearrange tiles from the keyboard, tune gaps and appearance in a native settings window, and keep the same configuration in a hot-reloaded text file. If you are new to tiling, start with two disposable windows; if you already use Hyprland or AeroSpace, start with the [migration guide](docs/MIGRATING.md). This launch branch runs the native Engine and requires an already configured development system. A no-injection Lite implementation is being tested separately; it has not passed its full live acceptance gate.

<a id="showcase"></a>
**Showcase pending:** the launch recording and hero GIF/WebP will be linked here after real desktop capture and frame review. Existing [settings screenshots](#settings) show the interface, not proof of runtime motion.

## 60-second quickstart

The commands take about a minute to enter; the first build takes longer. This source preview lives on `launch/2026-10-16`. You need macOS 14 or later, Xcode Command Line Tools with Swift 5.9 or later, and Python 3. No downloadable standalone release is promised here.

```sh
git clone --branch launch/2026-10-16 https://github.com/sakenuGOD/hyprwm-macos.git
cd hyprwm-macos
./install.sh
```

**This installs an app and CLI without launching a window manager. It does not complete Engine setup.** The installer builds into `~/Applications`, adds `hyprwm` and `hyprwmctl` under `~/.local/bin`, preserves existing configuration and bundles portable configuration resources. Final clean-HOME command verification is pending on the selected launch revision.

Running this branch additionally requires **SIP disabled**, `amfi_get_out_of_my_way=1`, a matching native engine already injected into the current WindowServer, and its verified development `hook` directory with `anim4.state` and generated configuration. A legacy configuration cache rebuild also needs Lua. Required native resources and lifecycle helpers are not all tracked in the public checkout; cloning and installing alone cannot establish this runtime. The installer does not configure those prerequisites. If you do not already have a verified Engine installation, stop after packaging and follow the [experimental Lite branch](#experimental-lite).

Grant **Accessibility** to the process controlling windows in **System Settings → Privacy & Security → Accessibility**, then relaunch it. For an installed app, add `~/Applications/HyprWM.app` with **+** if needed. Screen recording is needed for verification captures; [Apple documents its permission pane](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac). Engine's separate legacy hotkey watcher can require Input Monitoring; the daemon's fixed panic shortcut uses Carbon. Stop another automatic tiler before starting HyprWM.

After quitting the previous instance normally, an explicit foreground launch using your **already verified** native installation is:

```sh
HYPRWM_HOOK=/path/to/verified-native-checkout/hook ~/.local/bin/hyprwm
```

Replace the placeholder with that installation's real path. This starts a real Engine window manager in the desktop session. `HYPRWM_MODE=lite` does not select Lite on this launch branch.

Once running, open two disposable Terminal or TextEdit windows. Try the focus/move shortcuts below and keep the recovery commands available:

```sh
~/.local/bin/hyprwm doctor
~/.local/bin/hyprwmctl status
~/.local/bin/hyprwm restore-all
```

`doctor` diagnoses readiness; `status` reports runtime state; `restore-all` is for HyprWM-owned hidden/parked windows. Explicit restoration leaves tiling paused; inspect the real windows before `hyprwmctl resume`. A pending/refused result needs attention before removal. See [troubleshooting](docs/TROUBLESHOOTING.md).

## Default shortcuts

These are the actual macOS keys represented by the portable baseline. Engine ordinary bindings require the separate legacy `hyprkeys` watcher and its generated baseline; the source app installer does not start that watcher. An existing native installation or imported configuration may differ. **Settings → Hotkeys** shows configured bindings, which does not prove a watcher registered them. The daemon independently registers the fixed Control–Option–P panic shortcut through Carbon; it does not require Input Monitoring. The watcher and settings recorder can need that permission, and another application can already own a chord.

| Shortcut | Action |
| --- | --- |
| Control–Option–P | Panic pause / resume; also available in the menu. |
| Control–Option–Arrow | Focus the neighboring tile. |
| Control–Option–Shift–Arrow | Move the current tile in that direction. |
| Control–Option–Return | Toggle the current split orientation. |
| Control–Option–F | Toggle floating. |
| Option–F | Toggle layout fullscreen. |
| Option–Shift–Return | Toggle maximized layout in the working area. |
| Option–Q | Close the current window. |
| Option–W / Option–Shift–W | Hide / restore the most recently hidden window. |
| Option–Shift–B | Balance split ratios. |
| Control–Option–Shift–T | Retile. |
| Option–1…9, Option–0 | Select workspace 1…10, where the active mode supports it. |
| Control–Option–1…9 / Control–Option–0 | Move to a workspace where supported; verify the mode's command capability. |

Workspace bindings in the baseline do not establish native Space creation or switching support. Engine uses existing macOS Spaces through capability-checked backends; Lite's virtual workspace path is tracked separately. Read the mode status before relying on workspace actions.

## Engine and experimental Lite

| | This launch branch: Engine | Separate experimental Lite branch |
| --- | --- | --- |
| System changes | SIP disabled, `amfi_get_out_of_my_way=1`, matching WindowServer injection and native development resources. | Designed for SIP on, no boot arguments, no injection and no root at runtime. SIP-on behavior has not been verified on this SIP-off test host. |
| Window control | Swift policy and AX client frames plus native presented-frame control. | Public AX placement/focus with capability-checked optional mapping and captured overlays. |
| Motion and borders | Native body/border renderer; first-map, close and landing defects remain under investigation. | Proxy motion and borders exist, but the full flash-free open/close/swap gate remains failed. |
| Workspaces | Existing native macOS Spaces through checked backends. | Virtual workspaces, separate from Mission Control Spaces. |
| Availability | Runtime requires your already verified native setup; app packaging alone is insufficient. | Source implementation on `lite/2026-10-16`; not enabled by this launch branch. |

The installer does not disable SIP, change boot arguments or inject code. Engine changes the system's security posture; [Apple's SIP overview](https://support.apple.com/en-us/102149) explains the protection being relaxed. The macOS 14 deployment target is a build minimum, not proof that private integration works on every macOS version.

<a id="experimental-lite"></a>
### Experimental Lite

The [Lite branch](https://github.com/sakenuGOD/hyprwm-macos/tree/lite/2026-10-16) and its [research report](https://github.com/sakenuGOD/hyprwm-macos/blob/lite/2026-10-16/docs/LITE_RESEARCH.md) contain the unmerged implementation and actual verification limits. Use a separate checkout to inspect or test it:

```sh
git clone --branch lite/2026-10-16 https://github.com/sakenuGOD/hyprwm-macos.git hyprwm-macos-lite
cd hyprwm-macos-lite
```

These commands only obtain source. Follow that branch's current instructions and recovery prerequisites before installing or launching it. Its `HYPRWM_MODE=lite` selection, automatic fallback and Carbon runtime bindings are branch-specific; this launch branch does not implement them.

Lite's observed failures include a default-position first-map flash and stretched/crossfaded content during motion. Accepted native sizes can also differ from logical targets. A captured proxy contains static content during a transition. Apple's [window-created notification](https://developer.apple.com/documentation/applicationservices/kaxwindowcreatednotification) does not guarantee delivery before presentation. No universal flash-free or clean-landing claim is made.

### Returning from Engine to Lite

First run `~/.local/bin/hyprwm restore-all` while Engine is still available, confirm managed windows are visible, and quit HyprWM normally. Preserve state and finish unresolved recovery in the matching Engine runtime before changing modes. The experimental Lite implementation refuses outstanding native Engine hidden-window records because public AX cannot restore their alpha/Space ownership.

Stop any engine auto-injection helper installed by your development setup. A loaded WindowServer library is removed by a normal reboot; do not kill WindowServer to unload it. Restore the saved pre-Engine boot-argument value, removing only the changes you made for Engine and preserving unrelated arguments. If you did not record that value, inspect the existing arguments rather than deleting the whole variable. Re-enable SIP from macOS Recovery with `csrutil enable`, then reboot and verify `csrutil status`, following [Apple’s Recovery procedure](https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection). Testing Lite then requires the separate branch and its prerequisites. App uninstall does not perform these system changes for you.

## How it compares

Different workflows have different strengths. These descriptions were checked against each project's primary documentation on 2026-10-15; they are not a comparative performance benchmark.

| Project | What it offers / does better | Why try HyprWM |
| --- | --- | --- |
| [AeroSpace](https://nikitabobko.github.io/AeroSpace/guide) | Documented i3-style tree/accordion layouts, binding modes, callbacks, monitor assignment and virtual workspaces. Its current config also supports focus follows mouse. | A Hyprland-inspired binary split workflow with a native settings UI and configurable motion path; check the documented Engine prerequisites and current behavior before switching a daily session. |
| [yabai](https://github.com/asmvik/yabai) | Established BSP command/scripting ecosystem and native Space integration. Its [SIP guide](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection) lists features such as animations and Space mutation that need the scripting addition. | A shared text/UI configuration and a planned no-injection Lite motion path, with Engine as a separate opt-in. |
| [Amethyst](https://github.com/ianyh/Amethyst) | A broad choice of tall, wide, column, BSP and custom layouts, plus GUI/YAML configuration. Prefer it if cycling those layouts is central to your workflow. | A focused binary split model with Hyprland-style curve and per-event motion controls. |

HyprWM is a preview. A shorter feature list, unverified mode or unfinished recovery flow is not a reason to claim it beats an established manager. Keep your previous setup until your actual focus/dialog/restore workflow passes.

## Configure it

Edit `~/.config/hyprwm/hyprwm.conf` or use the settings window. Save to hot-reload. `HYPRWM_CONFIG` selects another file.

```conf
layout {
    gaps_in = 8
    gaps_out.top = 12
}
focus {
    follow_mouse = 1
}
runtime {
    overview_hidden_windows = false
}
bind = CTRL ALT, H, focus, left
windowrule = float, app:^Calculator$
```

Readable text bindings use `SUPER` = Command, `ALT` = Option and `CTRL` = Control. The default table above already uses macOS key names. [CONFIG.md](docs/CONFIG.md) documents every key's default, real consumer, bounds and example, including accepted settings without an effective renderer. The [motion specification](docs/MOTION.md) defines the intended choreography; live validation remains separate. User transparency and hidden-window Mission Control remain unfinished; keep opacity at `1` and hidden-window overview off for a conservative setup.

## Bring your configuration

```sh
~/.local/bin/hyprwm import /path/to/aerospace.toml
```

Import conservatively maps supported Hyprland, AeroSpace, yabai/skhd, i3/sway and Amethyst preferences. It makes a backup and reports unsupported lines; it never runs your old shell configuration. **Rectangle conversion is manual**, and automatic import does not map it. See [MIGRATING.md](docs/MIGRATING.md) for concept tables and actual input/output examples for all six families.

## When something goes wrong

- **No tiling:** run `~/.local/bin/hyprwm doctor`, grant Accessibility to the controlling process and relaunch.
- **Invisible/parked window:** run `~/.local/bin/hyprwm restore-all`, read the result and confirm the window is visible before quitting/removing files.
- **Pointer focus stopped:** check `focus.follow_mouse`, pause state, matching rules, menus/modals and held mouse buttons; compare actual keyboard input with the border.
- **Buried dialog:** pause, dismiss normally, and report role/modal/parent behavior rather than adding app-name exceptions.

Detailed recovery, config, hotkey and socket guidance is in [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). The [API reference](docs/API.md) covers IPC and event subscriptions.

## Uninstall

From the same checkout:

```sh
./uninstall.sh
```

The matching uninstaller must restore windows before removing the installed app. If recovery is pending, keep the app, checkout, configuration and state until it completes. Preserve preferences/backups unless you intentionally delete them afterwards. Removing the app does not unload an independently injected engine or reverse SIP/boot-argument changes; follow [Engine reversal](#returning-from-engine-to-lite).

## FAQ

**Is this Hyprland or a fork?** No. It is an independent macOS window manager inspired by Hyprland's behavior and motion.

**Must I disable SIP?** Running this branch requires the Engine prerequisites above. The separate Lite implementation is designed to avoid that requirement, but its full live gate remains failed. Packaging or inspecting the interface does not require changing SIP.

**Is it ready for my main desktop?** It is experimental. Check current mode capability, permissions and recovery, then test your apps with disposable windows. A build/test pass is not live desktop evidence.

**Can I keep another tiler running?** Two automatic managers can fight over frames and focus. Stop the other tiler before starting HyprWM; retain its configuration for rollback.

**Does fullscreen mean macOS fullscreen?** Layout fullscreen/maximized changes HyprWM's layout. Native macOS fullscreen uses a different Space and lifecycle.

**Can I delete the checkout after installing?** The source installer bundles configuration resources and installs local CLI launchers. Engine still needs its matching external native resources; keep those and the checkout for the matching `uninstall.sh`. The separate `build_app.sh` development menu companion still records a checkout dependency. See [packaging](hook/swift/PACKAGING.md).

**Where is the release download?** This README uses the source install flow. A draft release without assets is not an installable distribution.

## Contribute

Start with [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md). Useful reports include mode, macOS/build, minimal config, exact steps, recovery outcome and sanitized evidence. Never attach private window content or unsanitized title logs.

<a id="settings"></a>
## Settings screenshots

[Menu](docs/screenshots/menu.png) · [General](docs/screenshots/general.png) · [Layout](docs/screenshots/layout.png) · [Animations](docs/screenshots/animations.png) · [Appearance](docs/screenshots/appearance.png) · [Focus](docs/screenshots/focus.png) · [Shortcuts](docs/screenshots/hotkeys.png) · [Rules](docs/screenshots/rules.png) · [Advanced](docs/screenshots/advanced.png) · [About](docs/screenshots/about.png).

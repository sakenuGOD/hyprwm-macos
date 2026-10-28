# Troubleshooting

Start with `~/.local/bin/hyprwm doctor` and `~/.local/bin/hyprwmctl status`.
Remove private paths and window information before sharing diagnostics.

## Nothing tiles

Check `sw_vers -buildVersion`: the engine requires **25G241, Apple silicon**, SIP
debugging restrictions disabled and a prepared engine for the current WindowServer.
Follow [native setup](INSTALL.md#native-engine); repeat it after a reboot.
In **System Settings → Privacy & Security → Accessibility**, enable your current
`~/Applications/HyprWM.app`. For source launches, enable the process named by macOS.
Relaunch after changing permissions. A responding socket alone cannot verify tiling.

## A window is invisible or hidden

Keep the app, checkout and saved state. Run `~/.local/bin/hyprwmctl restore-all`.
If the daemon crashed, retain the matching engine resources and restart HyprWM to
let startup recovery restore its saved windows. Read any refusal before continuing.
`Engine restoration pending:` means work is still running. The client waits four
seconds; daemon recovery can take eight. Keep it running, check actual windows,
and retry after the attempt finishes. `status` shows `visibility.restore_pending`
and `visibility.engine_recovery_active`. An empty hidden list alone is insufficient.
Restoration leaves tiling paused; use `~/.local/bin/hyprwmctl resume` only after
checking visibility and placement. Never delete saved state or restart WindowServer,
Dock or an application to recover a window.

## Focus goes to the wrong window

Check `focus.follow_mouse = 1`, matching `no_follow_mouse` rules and Accessibility.
Dialogs, menus, Mission Control, floating windows and a held mouse button can
intentionally delay pointer focus. Move over a tile, stop, and try typing in a
throwaway document. Report whether input or only the border is wrong.
If opening a URL or activating a hidden app leaves it invisible, try `restore-all`.
Use **Control–Option–P** or `hyprwmctl pause` to stop an unexpected focus loop.
A reload reapplies `runtime.enabled`; set it to `false` to stay paused across edits.

## A dialog is behind a tile

Pause HyprWM, dismiss the dialog normally, and check where input returns.
Report the app, how you opened the dialog, and whether it is a sheet or separate
window. Include the smallest relevant rules. Do not add app-name exceptions as a workaround.

## A config edit has no effect

Edit `~/.config/hyprwm/hyprwm.conf`, or the path selected by `HYPRWM_CONFIG`.
Read line-numbered warnings with `hyprwm doctor` and compare `hyprwm --print-config`.
See [settings and limits](CONFIG.md). Some parsed settings have no effect yet.
Float rules stay attached to a window until HyprWM restarts, even after the rule is
removed; saved explicit floating state can also keep a window floating.

## A shortcut does nothing

Check **Settings → Keyboard Shortcuts**, duplicate chords, and Input Monitoring.
Ordinary global shortcuts need the separate keyboard helper; the app installer
does not start it. The fixed Control–Option–P safety shortcut works independently.
Text bindings use `SUPER` = Command, `ALT` = Option, `CTRL` = Control.
See [imports](CONFIG.md#import-from-another-window-manager) for modifier differences.

## The socket is unavailable or a command is refused

Start one daemon. Match `HYPRWM_CTL` in its environment and your client; the default
is `/tmp/hyprwm.ctl`. Keep a live socket in place. Read the first refusal before
retrying: a changing Space, dialog or session lock can prevent a command.
See [CLI commands](CLI.md) for exact arguments and reply handling.

## Motion, transparency or Mission Control looks wrong

Keep opacity at `1` and hidden-window Mission Control off for a simple reproduction.
Both transparency and hidden-window overview are unfinished. Visible managed windows
can also have missing Mission Control cards. Exit normally and inspect desktop windows;
use restoration above if a window stays invisible. For motion bugs, record a short clip
showing the start and landing, and say whether content, border or final size jumps.

## Installation or removal fails

Read the first error. Check Command Line Tools, Swift, Python and writable
`~/Applications`. Keep the source folder: the app still uses it.
Run the matching `./uninstall.sh`; pending restoration must finish before removal.
Remove separately installed services using [rollback steps](INSTALL.md#rollback-and-uninstall).
Report `sw_vers`, chip, `csrutil status`, **About → Copy Diagnostics**, steps and
expected/actual behavior. Keep private titles, files and credentials out of the report.

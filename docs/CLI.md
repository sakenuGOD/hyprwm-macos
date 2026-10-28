# Command-line tools

The installer adds `hyprwm` and `hyprwmctl` to `~/.local/bin`. Add that directory to
`PATH`, or use the full path. In a checkout, use `./scripts/hyprwm` and `./scripts/hyprwmctl`.

## hyprwmctl

This client talks to a running daemon. Use `hyprwmctl --help` for its syntax.

| Command | Action |
| --- | --- |
| `hyprwmctl status` | Print JSON state: enabled, current Space, focus, layout, hidden windows and engine. |
| `hyprwmctl focus left\|right\|up\|down` | Focus a neighboring tile. A queued reply can precede actual focus. |
| `hyprwmctl move left\|right\|up\|down` | Move the focused tile in the layout. |
| `hyprwmctl layout balance` | Balance split ratios. |
| `hyprwmctl layout retile` | Rebuild the current tiling layout. |
| `hyprwmctl layout togglesplit` | Change the focused split direction. |
| `hyprwmctl layout fullscreen` | Toggle the layout's fullscreen view. |
| `hyprwmctl float` | Toggle floating for the focused window. |
| `hyprwmctl reload` | Reload configuration. |
| `hyprwmctl pause` / `resume` | Stop/start automatic tiling for this session. |
| `hyprwmctl restore-all` | Restore managed hidden windows and leave tiling paused. |
| `hyprwmctl pan left\|right\|up\|down\|reset` | Move cropped live content in 64-point steps, without moving its tile. Requires engine support. |
| `hyprwmctl handover` | Prepare state for a controlled daemon update; see [updating](INSTALL.md#updating). |
| `hyprwmctl subscribe` | Read newline-delimited JSON events until disconnected. |

Invalid arguments, a missing socket, a refused command or an empty reply produce a
nonzero exit. `restore-all` retries a pending response for four seconds. The daemon
can continue recovery for eight seconds, so retain it and its state if work is pending.
Check real window visibility before resuming or uninstalling.

The menu's **Quit HyprWM** action restores windows and stops the manager. The raw
socket command `quit` closes the focused application; do not use it to stop HyprWM.

## hyprwm

| Command | Action |
| --- | --- |
| `hyprwm` | Start the daemon using the selected native engine. |
| `hyprwm --help` | Show runtime arguments. |
| `hyprwm doctor` | Report configuration paths, parsing issues, version and permission state. |
| `hyprwm --diagnose` | Read app/engine metadata without enabling tiling. |
| `hyprwm --print-config` | Print resolved layout, curve and animation values without starting the daemon. |
| `hyprwm --init-config` | Create default text configuration only if it is absent. |
| `hyprwm import FILE` | Import supported text settings and back up an existing configuration. |
| `hyprwm --layout STATE SPACE X Y W H` | Calculate layout from a state file without starting the daemon. |
| `hyprwm --menu-only [--show-settings]` | Start a menu companion for an already running daemon. |

Some configuration reads create the default file if absent. `doctor` does not
create it or request permissions. See [configuration and imports](CONFIG.md).

## Sockets and environment

The daemon opens user-owned Unix sockets with mode `0600`. It opens no network port.

| Variable | Default / purpose |
| --- | --- |
| `HYPRWM_CTL` | `/tmp/hyprwm.ctl`; set the same path for the daemon and client. |
| `HYPRWM_EVENTS` | Command socket path plus `.events`; event subscription socket. |
| `HYPRWM_CONFIG` | `~/.config/hyprwm/hyprwm.conf`; editable text configuration. |
| `HYPRWM_HOOK` | Source `hook` directory, when explicitly selecting source resources. |
| `HYPR_HOME` | Optional Lua input directory; otherwise `hook/config/defaults`. |
| `HYPRWM_ENGINE_STATE` | Explicit external engine-state selection. |
| `HYPRWM_STATE_DIR` | Persistent daemon-state directory; native default `/tmp/hyprwm-swift`. |
| `HYPRWM_TIME_SCALE` | Geometry timing multiplier, `0.1…4`. |

Keep window IDs and process IDs within the current session. The daemon checks them
again before changing a window. Do not publish private titles or forward the socket over a network.

## Socket protocol

Send one UTF-8 command followed by a newline, then read through newline or EOF.
The daemon accepts quoted text or a JSON array of strings, without shell expansion.
State replies are JSON; other replies are text. Requests are limited to 64 KiB,
responses to 1 MiB, and an active connection to one second.

```sh
printf '["status"]\n' | nc -U -w 5 /tmp/hyprwm.ctl
```

`subscribe` first emits `{"event":"connected","version":1}`. Later events are
`window_opened`, `window_closed`, `window_focused` and `space_changed`, with
sequence, timestamp, Space and optional window information. Very short-lived
windows may be missed. Initial windows are not replayed, and hiding is not closing.
Reconnect and query `status` after a disconnect. At most 16 subscribers are accepted;
a client with over 32 KiB of pending output is disconnected. Ignore unknown fields.

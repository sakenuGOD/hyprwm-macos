# HyprWM API

HyprWM exposes local Unix sockets owned by the current user with mode `0600`.
The command socket is `/tmp/hyprwm.ctl`; set `HYPRWM_CTL` in both the daemon and
client environment to use another path. No network port is opened.

## Command-line client

From a checkout, use `scripts/hyprwmctl`. The installer also adds `~/.local/bin/hyprwmctl`; use that absolute path or add `~/.local/bin` to your PATH for the short command.

```bash
scripts/hyprwmctl status
scripts/hyprwmctl focus left
scripts/hyprwmctl move right
scripts/hyprwmctl layout balance
scripts/hyprwmctl layout togglesplit
scripts/hyprwmctl layout retile
scripts/hyprwmctl layout fullscreen
scripts/hyprwmctl float
scripts/hyprwmctl reload
scripts/hyprwmctl pause
scripts/hyprwmctl resume
scripts/hyprwmctl restore-all
```

`status` prints the daemon's JSON state. Directional `move` rearranges the focused
window in the current layout. Layout actions operate on the existing dwindle
layout; selecting a different layout engine is not supported. `float` toggles the
focused window between floating and tiled. `pause` and `resume` change the running
session; edit `runtime.enabled` in `hyprwm.conf` for a persistent setting.
The client exits nonzero for invalid arguments, connection failures, empty replies,
or a refused command. A successful queued focus request acknowledges scheduling;
it does not guarantee that an application has already accepted focus.

## Command wire protocol

Connect, write one UTF-8 command followed by a newline, then read one newline
terminated response. The daemon closes the connection after replying. Commands
accept a JSON array of string arguments or quoted text; there is no shell expansion.
State responses are JSON; mutation responses are plain text. Handler failures return
a sanitized `error: …` line (at most 1024 Unicode scalars of message). Protocol/size
failures can still close the connection without a response. Read until newline or EOF, rather than assuming
that one `recv` contains the entire response. Requests are bounded to 64 KiB and
responses to 1 MiB; a serviced connection expires after one second.

```bash
printf '["status"]\n' | nc -U -w 5 /tmp/hyprwm.ctl
printf '["focus","left"]\n' | nc -U -w 5 /tmp/hyprwm.ctl
```

```python
import json
import os
import socket

path = os.environ.get("HYPRWM_CTL", "/tmp/hyprwm.ctl")
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(5)
    client.connect(path)
    client.sendall(json.dumps(["status"]).encode() + b"\n")
    with client.makefile("rb") as stream:
        reply = stream.readline(1_048_577)
        if not reply.endswith(b"\n") or len(reply) > 1_048_576:
            raise RuntimeError("Incomplete or oversized daemon response")
        state = json.loads(reply)
print(state["space"], state["focus"], state["rects"])
```

Useful state fields include `enabled`, `space`, `focus`, `tree`, `rects`, `floating`,
`hidden`, and `engine`. Mode-aware builds also report top-level `mode`, `daemon.mode`,
`engine.mode` and `engine.available`. In Lite, `space` is a virtual workspace ID,
not a native macOS Space ID. The `lite` object reports capture/animation capability,
proxy/direct-placement/capture-failure counters, recovery count/error and hotkey
conflicts; `hotkey_bindings` supplies that mode’s settings metadata. The diagnostic
`lite.focus_context` is `[frontmost PID, AX-focused window ID, focus flags]`, and
`lite.pointer_hit` is the current public census receiver ID or null. A reported
capture capability is not evidence that a particular animation succeeded. Window IDs are session lifetime observations, not
persistent identifiers; obtain a fresh state before acting on them. Additional
fields are diagnostic and may change between releases.

## Event subscriptions

The event socket defaults to `/tmp/hyprwm.ctl.events`; set `HYPRWM_EVENTS` in both
the daemon and client environment to override it. Connect without sending a
request. Each line is a JSON object. The first line is
`{"event":"connected","version":1}`. Subsequent event types are:

| Event | Meaning |
| --- | --- |
| `window_opened` | A layer-zero window first appears in the existing window census. |
| `window_closed` | A previously observed window disappears, or its owning PID changes. |
| `window_focused` | The WM's recorded focus changes; `window` can be null. |
| `space_changed` | The WM observes another current Space. |

```bash
scripts/hyprwmctl subscribe
# Example event (sequence numbers restart with the daemon):
# {"event":"window_focused","sequence":3,"timestamp":1792050000.5,"space":1,"window":{"wid":42,"pid":1234,"space":1}}
```

```python
import json
import os
import socket

control = os.environ.get("HYPRWM_CTL", "/tmp/hyprwm.ctl")
path = os.environ.get("HYPRWM_EVENTS", control + ".events")
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.connect(path)
    with client.makefile("rb") as stream:
        for line in stream:
            event = json.loads(line)
            print(event["event"], event.get("window"))
```

Events use the WM's cached census and add no AX scans. They describe observations,
not guaranteed delivery of every OS transition: a very short-lived window between
censuses may not appear, and hiding is not closing. Initial existing windows are
not replayed as opened events. Use `status` to establish and resynchronize state.
The stream has no history or replay guarantee. Slow clients are disconnected when
their pending output exceeds 32 KiB; at most 16 subscribers are accepted. Reconnect
and query state after disconnection. The event version covers envelope semantics;
clients should ignore unknown fields and event types.

## Configuration and offline CLI

The editable file is `~/.config/hyprwm/hyprwm.conf`, or the explicit `HYPRWM_CONFIG` path. [CONFIG.md](CONFIG.md) lists all accepted keys, defaults, consumers and currently ineffective settings. [MIGRATING.md](MIGRATING.md) gives the supported foreign formats and conversion limits.

After the source installer has bundled the base configuration:

```sh
~/.local/bin/hyprwm --help
~/.local/bin/hyprwm doctor
~/.local/bin/hyprwm --print-config
~/.local/bin/hyprwm import /path/to/aerospace.toml
```

`--print-config` resolves and prints selected layout/curve/animation values; it does not start a daemon or prove live behavior. If the text config is absent, reading it may create a default file. `import FILE` applies supported settings and creates a sibling backup before replacing an existing configuration. Foreign input is never executed. It requires a regular UTF-8 file up to 256 KiB. Unsupported statements are reported by original line number; zero mapped settings is an error. Rectangle is detected but not converted.

`scripts/hyprwm` is the developer wrapper for the source binary; its config-dependent modes additionally need the generated `hook/config/hypr_cfg.json`. The installed CLI uses the app’s bundled baseline instead. `HYPRWM_HOOK` locates a `hook` directory and its schema/base configuration. `HYPRWM_STATE_DIR` selects the persistent daemon-state directory (native default `/tmp/hyprwm-swift`). `HYPRWM_TIME_SCALE` overrides geometry timing in the range `0.1…4`. `HYPRWM_NO_DECO=1` disables the optional native decoration helper. Debug/experimental environment switches are implementation details, not stable API contracts.

## Recovery and diagnostics

`hyprwm doctor` reports version, requested/running mode, the control socket, config path and line-numbered parse issues, and the current process's Accessibility, Screen Recording, Input Monitoring and Automation status. It does not request a permission prompt or create config. Carbon runtime shortcuts do not need Input Monitoring; the settings recorder's event tap can. Automation → System Events is for scripted desktop verification.

`hyprwm --init-config` explicitly creates commented defaults only when the selected config is absent, and preserves an existing file. The source installer uses this entry point with the portable bundled baseline.

`hyprwm restore-all` routes to a responding daemon or, where supported, the stopped Lite runtime's persisted recovery ledger. It restores verified window lifetimes and preserves unresolved records. Success is distinct from a command being queued; confirm native visibility. Restoring outstanding stopped-runtime records needs Accessibility and is a runtime operation, not an offline config check. An empty ledger can be checked without starting a window manager. Offline Lite recovery refuses outstanding Engine hidden-window records; start the matching Engine runtime for those records.

The raw command `quit` targets the focused **application**. It is not a daemon shutdown command. Use **Quit HyprWM** or the matching uninstaller for restoration-aware daemon shutdown.

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for permission panes, visibility recovery, config warnings and safe shutdown. A session pause and restoring hidden windows are separate operations. Treat refusal/pending responses as incomplete work, preserve state, and verify real windows before deleting an installation.

The command protocol is local control, not a remote-service authentication boundary. Do not expose its Unix socket through a network bridge or share a socket with another user. Window/PID identities can be reused; the daemon revalidates ownership for mutations. Consumers should never persist a window ID as a durable external identity.

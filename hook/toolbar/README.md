# Native toolbar source

This directory contains the native workspace toolbar, cropped-content arrow and
reset controls, original-menu representation module, its loader and the shared
owned-process lifecycle. The menu implementation is pinned to macOS build
25G241 and its AppKit UUID. Other native profiles must refuse safely.

Build without launching or installing anything:

```sh
python3 hook/toolbar/build.py --output /absolute/new/toolbar-build
```

The output includes a signed `HyprWM Spaces.app`, arm64 and arm64e menu modules,
the event helper, relative source hashes, module UUIDs and build provenance.
`source-manifest.json` is generated in the output directory. No private checkout,
research artifact, key, grant, capture fixture or per-machine receipt is an input.
The glyph font is registered only inside the toolbar process. Asset licenses and
upstream provenance remain beside the assets.

Generated settings are unqualified, with workspace actions and menu relocation
disabled. `--settings-source` imports only the forest and WM executable paths;
it is not an upgrade writer and must not replace existing settings. Build receipts
and module profiles explicitly do not grant live qualification.

The frozen admission sources in `menu/frozen-admission` reproduce the menu
module's source graph. The separate current `hook/admission` implements the core
v3 client. Preserve an existing owner; do not replace either source set with the
other or assume a frozen v1 install has taken over a v3 owner.

The runtime retains exact birth, image, source, token and socket-peer checks.
Menu callbacks preserve the original NSMenu objects. Crop requests select the
current window by WID, PID, birth and Space, submit once after mouse release and
confirm the requested offset through bounded readback. Queued is not an ACK.

The toolbar panels and switching backend currently target ordinary Spaces.
Fullscreen catalogs remain readable, but fullscreen workspace switching needs
separate integration. Full clean-install/session enable, migration and removal
integration is still being completed; this source directory alone does not
establish those behaviors or qualify every application.

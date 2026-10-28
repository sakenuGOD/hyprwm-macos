# Window identity module

This module observes AppKit tab groups, selected tabs and window lifetimes.
It provides facts for native adapters without changing layout, focus or geometry.
Its optional publisher and reader are disabled until explicitly connected.

Build the module and run its offline checks:

```sh
sh hook/identity/build.sh /tmp/hyprwm-identity-dev
```

The build produces signed arm64 and arm64e libraries plus test tools. It does not
launch a GUI or attach to an application. Native integration requires the exact
supported macOS build; see [installation](../../docs/INSTALL.md).

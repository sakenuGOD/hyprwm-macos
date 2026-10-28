# Native integration

This directory contains the Swift daemon, WindowServer engine, platform bridges,
configuration and test reference models. Start with the [project README](../README.md).
The engine supports only macOS 26.7.1 (25G241) on Apple silicon and needs privileged
setup. Building Swift does not install it. See [installation](../docs/INSTALL.md)
and the [Swift package](swift/README.md). Keep native addresses, framework UUIDs
and recovery guards unchanged unless you can verify them on the supported build.

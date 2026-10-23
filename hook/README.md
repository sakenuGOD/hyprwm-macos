# Native integration sources

This directory contains the native animation engine, Swift daemon, platform bridges, configuration and reference tooling. See the [project README](../README.md) for source builds and the [Swift package](swift/README.md) for runtime interfaces.

Building Swift does not install the native engine. Native deployment requires a separately qualified image for the exact macOS build and framework UUIDs. The legacy native build script is incomplete for the current presentation entry points and also needs an external effects source package.

Preserve the running desktop when investigating failures. Use the manager’s pause and restoration commands; retain unresolved ownership records. Do not restart WindowServer, Dock, loginwindow or client applications to recover an animation, and do not change boot security settings as an installation step.

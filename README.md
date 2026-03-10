# PrinterBridge

PrinterBridge is a planned macOS-first AirPrint bridge for legacy printers that already work through CUPS but do not natively appear as AirPrint printers to Apple devices.

The initial target is a Brother HL-2170W environment verified through:
- development on an Apple Silicon MacBook Pro running macOS 26.x
- deployment and validation on an Intel Mac mini running macOS 15.7.4
- remote access via the existing SSH alias `macmini`

## Status

This repository now has an initial scaffold:
- [Product Spec](docs/product-spec.md)
- shared Swift package core in `packages/core/`
- macOS app and daemon scaffolding in `apps/macos/`
- development, deployment, validation, and CI script entry points in `scripts/`

## Recommended Name

The recommended project name is `PrinterBridge`.

Why this name:
- generic enough for future Linux support
- not tied to Brother or a single printer brand
- avoids a direct naming collision with existing projects named `AirPrint_Bridge`
- clear about the product's job: bridge printers into a different discovery/compatibility model

## Planned Scope

V1 is macOS-first:
- SwiftUI app
- helper/daemon background service
- CUPS-backed printer discovery and job routing
- AirPrint-compatible Bonjour advertisement
- a separate development-only CLI for remote validation and smoke tests

Future phases may add:
- Linux host support
- broader multi-printer support
- Windows investigation if there is real demand

## Repository Layout

- `apps/macos/` macOS app and helper targets
- `packages/core/` shared bridge logic and models
- `platforms/linux/` Linux-specific notes or host implementation later
- `platforms/windows/` Windows-specific notes or host implementation later
- `docs/` product specs, technical design docs, and research notes
- `scripts/` development, deployment, and validation scripts
- `tests/` integration, end-to-end, and fixture assets
- `.github/workflows/` CI workflows

## Development Topology

The expected development loop is:
- build locally on the MacBook Pro
- deploy to the Intel Mac mini using `scp`
- install, launch, and inspect logs over `ssh macmini`
- validate printer discovery and print behavior on the target network

The validation CLI is intentionally separate from the end-user app packaging:
- it is useful for SSH-driven testing and diagnostics
- it should not be bundled into the default release artifact
- it can be built and deployed independently when needed
- the CLI target is built through a separate `PrinterBridgeCLI` scheme and marked `SKIP_INSTALL=YES`
- the current CLI build script emits a universal binary by building `arm64` and `x86_64` slices separately and merging them with `lipo`

## Near-Term Next Steps

- create the Phase 0 / Phase 1 technical design
- replace the daemon placeholder with real helper lifecycle and XPC
- implement printer discovery and capability inspection in the core package
- add real remote install and validation flows for the `macmini` host

## Quick Start

Generate the Xcode project:

```sh
./scripts/dev/generate-xcode-project.sh
```

Build the macOS targets:

```sh
./scripts/dev/build-macos.sh
```

Run the shared core tests:

```sh
./scripts/dev/test-core.sh
```

Build the development CLI:

```sh
./scripts/dev/build-cli.sh
```

Run local diagnostics without launching the GUI:

```sh
./scripts/validate/run-local-cli.sh doctor Brother_HL_2170W_series
```

Inspect the current CUPS-backed queue inventory:

```sh
./scripts/validate/run-local-cli.sh list-printers
./scripts/validate/run-local-cli.sh inspect-printer Brother_HL_2170W_series
```

Run the same diagnostics remotely after deploying the CLI:

```sh
./scripts/deploy/deploy-cli-macmini.sh
./scripts/validate/run-cli-on-macmini.sh doctor Brother_HL_2170W_series
```

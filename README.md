# CocoaInspector

Live process inspector for jailbroken iOS 16.0 or newer — [roothide](https://github.com/roothide) and rootless (`/var/jb`).

SwiftUI app (`Inspector/`), root LaunchDaemon (`CocoaInspectord/`), CLI (`CocoaInspectorCLI/`), and a shared XPC data layer (`Shared/`, `InspectorClient/`). The daemon samples only on authenticated client requests; the app owns its XPC connection for its foreground lifetime, and the daemon exits after the last client disconnects. Clients can list processes, open per-process detail views, export snapshots, and send two-phase `SIGTERM` / `SIGKILL`.

License: [MIT](LICENSE).

> Jailbreak-only. Uses private entitlements and APIs. Not for the App Store.

## Requirements

- macOS with Xcode 16 or newer; CI builds on the `macos-26` GitHub-hosted runner
- `ldid`, `dpkg-deb` (for packaging)
- A jailbroken device running iOS 16.0 or newer: roothide, or a rootless jailbreak that installs under `/var/jb`

## Build

```sh
make build         # check + macOS harness + unsigned iOS targets
make deb           # build, ad-hoc sign, package the roothide .deb (FLAVOR=roothide)
make deb FLAVOR=rootless   # the same build, packaged for /var/jb
make deb-all       # both packages
make harness       # shared data-layer tests on macOS only
```

Both flavors ship the identical arm64 Mach-Os; only the install layout differs.

| FLAVOR | Architecture | Install prefix |
| --- | --- | --- |
| `roothide` (default) | `iphoneos-arm64e` | none — roothide's dpkg relocates into the randomized bootstrap root |
| `rootless` | `iphoneos-arm64` | `/var/jb` |

`make deb` writes the package under `build/Packages` and verifies its layout with `Scripts/verify-deb.sh`. Path helper: `make print-deb-path [FLAVOR=rootless]`.

Optional local signing overrides go in git-ignored `Configuration/Developer*.xcconfig` (see `Configuration/Developer.xcconfig.example`).

## Versioning

`Configuration/Version.xcconfig` is the single source for app, daemon, CLI, and Debian package version:

```sh
make print-version
make set-version VERSION=1.2.3 BUILD=7
```

Pushing a `vX.Y.Z` tag makes CI apply that version, build both packages, and publish a GitHub release with `SHA256SUMS`.

## Install & verify

Install the `.deb` matching your jailbreak (`iphoneos-arm64e` for roothide, `iphoneos-arm64` for rootless) with your package manager or `dpkg`. The archive contains `Inspector.app`, `usr/bin/cocoainspector`, `usr/libexec/cocoainspectord`, and an on-demand LaunchDaemon plist. On roothide those rootful paths are mapped into the randomized jailbreak root by the bootstrap; on rootless they ship under `/var/jb`. The daemon derives the install root from its own path, so client authentication works in both layouts.

```sh
sudo cocoainspector self-test
sudo cocoainspector self-test --signal
sudo cocoainspector list
sudo cocoainspector inspect 1
sudo cocoainspector details 1 all
sudo cocoainspector watch --count 10 --interval-ms 1000
```

The normal self-test is read-only. `--signal` creates and terminates only a child of the CLI so the two-phase signal path can be tested without selecting a system process.

## Architecture notes

Daemon / XPC auth, idle, signal, and jetsam rules: [Documentation/Daemon-XPC-Architecture.md](Documentation/Daemon-XPC-Architecture.md).

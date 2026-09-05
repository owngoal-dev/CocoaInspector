# CocoaInspector

iOS process inspector for roothide and rootless jailbreaks: SwiftUI app (`Inspector/`), XPC daemon (`CocoaInspectord/`), CLI (`CocoaInspectorCLI/`), shared wire/data layer (`Shared/`, `InspectorClient/`).

## Build

- `make build` — validates inputs (`check`), runs the macOS data-layer test harness (`harness`), then builds the unsigned iOS app + daemon + CLI via xcodebuild. Requires `xcodebuild`, `ldid`, `dpkg-deb`.
- `make deb` — build + ad-hoc sign + package the `.deb` for `FLAVOR` (default `roothide`; `FLAVOR=rootless` installs under `/var/jb` as `iphoneos-arm64`), verify it with `Scripts/verify-deb.sh`, and print its sha256. Output path: `make print-deb-path [FLAVOR=rootless]`. `make deb-all` builds both.
- Packaging inputs are templates: `@PREFIX@` in `Packaging/wiki.qaq.cocoainspectord.plist`, `DEBIAN/postinst`, and `DEBIAN/prerm` is substituted at package time (empty for roothide, `/var/jb` for rootless), and `@FLAVOR@` in `DEBIAN/control`. Never hardcode an install prefix in Swift — the daemon derives its install root from `proc_pidpath`.
- `make harness` — run just the shared data-layer tests on macOS (fast; no device needed).
- Build settings live in `Configuration/*.xcconfig`, not in `project.pbxproj`. `Configuration/Version.xcconfig` is the single source of the app, daemon, CLI, and `.deb` version — change it with `make set-version VERSION=1.2.3 [BUILD=n]`; `make check` fails if a version is hardcoded back into the project file.
- Optional local overrides go in the git-ignored `Configuration/Developer*.xcconfig` files (for example `DEVELOPMENT_TEAM`). See `Configuration/Developer.xcconfig.example`.
- Pushing a `vX.Y.Z` tag makes CI apply that version, build both packages, and publish them to a GitHub release. CI is a single job on the GitHub-hosted `macos-26` runner — build, package verification, and release all run there; no self-hosted machine.
- `project.pbxproj` must keep `objectVersion = 77` so Xcode 16+ and the CI runner's Xcode can read it; newer Xcode betas rewrite it on GUI save, and `make check` fails when that happens — revert that line.
- SourceKit/editor diagnostics in this repo are frequently stale false positives (`PBXFileSystemSynchronizedRootGroup`); trust `xcodebuild` output, not the editor.

## Install on a jailbroken device

Install the package produced by `make deb` with your usual workflow (Sileo, `dpkg`, etc.) — the `iphoneos-arm64e` build on roothide, the `iphoneos-arm64` build on rootless. The archive installs `Inspector.app`, `usr/bin/cocoainspector`, `usr/libexec/cocoainspectord`, and the on-demand LaunchDaemon plist, at the jailbreak root (roothide) or under `/var/jb` (rootless).

After install, validate with:

```sh
sudo /usr/bin/cocoainspector self-test   # roothide; on rootless: /var/jb/usr/bin/cocoainspector
uiopen -b wiki.qaq.Inspector             # launch the app
```

Clean up any temporary upload copies after install. Do not leave stray package files on the device.

## On-device inspection: our CLI only (enforced)

All process inspection and verification on the device MUST go through our own CLI — never spawn or fork system tools (`ps`, `pgrep`, `top`, etc.; most don't exist on the device anyway). Paths below are the roothide ones; on rootless prepend `/var/jb`:

- `sudo /usr/bin/cocoainspector list` — pid / ppid / uid / threads / mem / name
- `sudo /usr/bin/cocoainspector inspect <pid>` — full JSON for one process (all collectors, incl. `executablePath`)
- `sudo /usr/bin/cocoainspector details <kind> <pid>`, `watch`, `signal`, `self-test`

Dogfooding the CLI is the point: if it can't answer a question about a process, that's a product gap to fix, not a reason to shell out.

## RootHide runtime dependency policy

Evaluate official `libroothide`/`libvroot` before adding a new bootstrap path
shim. This native app/daemon currently keeps a physical-path contract: process
identity, filesystem decisions and Foundation must refer to the same path.
Do not apply `symredirect` to only one side of that boundary. Packaging rejects
an accidental vroot dependency on the native daemon. Both package layouts may
reuse these native binaries; `libvroot` itself is RootHide-specific and is not
made rootless-compatible by changing the Debian architecture label.
References: `roothide/Developer`'s `vroot.md`, and `roothide/libroothide`'s
`init.c` and `stub.h`. `libroot` is a separate Rootless v2 path API.

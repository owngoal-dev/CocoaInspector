# Inspector engineering notes

- `Inspector.xcodeproj` is canonical; do not add XcodeGen or regenerate the project from YAML.
- Build and package a rootless Debian archive; do not add IPA or TIPA output.
- Keep the user-created `Inspector` SwiftUI files untouched until UI work is explicitly requested.
- Do not introduce a framework or Swift package until the user explicitly authorizes that architecture.
- Install the rootless app under `/var/jb/Applications/Inspector.app` and keep package architecture aligned with the target device.
- CocoaTap research is paused until the user explicitly authorizes it after the machine and Debian package are ready.
- Keep private entitlements minimal and add a capability only when an implemented collector requires it.
- Keep validation artifacts outside the Debian staging root so temporary metadata cannot leak into the installed filesystem.
- Normalize the Debian staging root to mode 0755; `mktemp -d` creates 0700 and that mode otherwise appears in `data.tar`.

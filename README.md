# Inspector

`Inspector.xcodeproj` is the only project definition. The repository does not use XcodeGen, Swift Package Manager, a separate UI framework, or TIPA packaging.

The current milestone only provides an Xcode build and a rootless Debian package harness for the Inspector app created in Xcode. UI and process-inspection implementation are intentionally untouched.

## Build

Open `Inspector.xcodeproj` in Xcode, or use:

```sh
make build
make deb
```

`make deb` builds a Release `Inspector.app` for iOS 17, signs it with the private inspection entitlements in `Packaging/Inspector.entitlements`, and creates an `iphoneos-arm64e` package under `build/Packages`.

The package installs the app at `/var/jb/Applications/Inspector.app` and refreshes the app registration with `uicache`.

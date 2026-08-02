#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "$#" -ne 7 ]]; then
    echo "usage: $0 <app-bundle> <control-template> <entitlements> <output-deb> <package-id> <version> <architecture>" >&2
    exit 64
fi

app_bundle="$1"
control_template="$2"
entitlements="$3"
output_deb="$4"
package_id="$5"
version="$6"
architecture="$7"

if [[ ! -d "$app_bundle" || ! -f "$app_bundle/Info.plist" ]]; then
    echo "error: app bundle is missing or incomplete: $app_bundle" >&2
    exit 66
fi
if [[ ! -f "$control_template" || ! -f "$entitlements" ]]; then
    echo "error: packaging inputs are missing" >&2
    exit 66
fi
if [[ "$output_deb" != *.deb ]]; then
    echo "error: output must use the .deb extension" >&2
    exit 64
fi
if [[ ! "$package_id" =~ ^[a-z0-9][a-z0-9+.-]+$ ]]; then
    echo "error: invalid Debian package id: $package_id" >&2
    exit 64
fi
if [[ ! "$version" =~ ^[0-9A-Za-z.+:~_-]+$ ]]; then
    echo "error: invalid Debian version: $version" >&2
    exit 64
fi
if [[ ! "$architecture" =~ ^[A-Za-z0-9][A-Za-z0-9-]+$ ]]; then
    echo "error: invalid Debian architecture: $architecture" >&2
    exit 64
fi

app_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_bundle/Info.plist")"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Info.plist")"
if [[ -z "$app_executable" || ! -x "$app_bundle/$app_executable" ]]; then
    echo "error: app executable is missing: $app_executable" >&2
    exit 65
fi
if [[ "$bundle_identifier" != "wiki.qaq.Inspector" ]]; then
    echo "error: unexpected bundle identifier: $bundle_identifier" >&2
    exit 65
fi

output_name="$(basename "$output_deb")"
output_directory="$(dirname "$output_deb")"
mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd -P)"
output_deb="$output_directory/$output_name"

staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/inspector-deb.XXXXXX")"
temporary_deb="$output_directory/.$output_name.tmp.$$"
signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/inspector-entitlements.XXXXXX.plist")"
trap 'rm -rf "$staging_directory"; rm -f "$temporary_deb" "$signed_entitlements"' EXIT
chmod 0755 "$staging_directory"

debian_directory="$staging_directory/DEBIAN"
installed_app="$staging_directory/var/jb/Applications/Inspector.app"
mkdir -p "$debian_directory" "$(dirname "$installed_app")"
/usr/bin/ditto "$app_bundle" "$installed_app"
rm -rf "$installed_app/_CodeSignature"
rm -f "$installed_app/embedded.mobileprovision"

ldid -S"$entitlements" -Cadhoc "$installed_app/$app_executable"

ldid -e "$installed_app/$app_executable" >"$signed_entitlements"
for entitlement in \
    platform-application \
    proc_info-allow \
    task_for_pid-allow \
    com.apple.private.security.no-sandbox \
    com.apple.system-task-ports.read; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$signed_entitlements" 2>/dev/null || true)"
    if [[ "$value" != true ]]; then
        echo "error: signed executable is missing entitlement: $entitlement" >&2
        exit 65
    fi
done

installed_size="$(du -sk "$installed_app" | awk '{print $1}')"
sed \
    -e "s/@PACKAGE_ID@/$package_id/g" \
    -e "s/@VERSION@/$version/g" \
    -e "s/@ARCHITECTURE@/$architecture/g" \
    -e "s/@INSTALLED_SIZE@/$installed_size/g" \
    "$control_template" >"$debian_directory/control"

packaging_root="$(cd "$(dirname "$control_template")/.." && pwd -P)"
/usr/bin/ditto "$packaging_root/DEBIAN/postinst" "$debian_directory/postinst"
/usr/bin/ditto "$packaging_root/DEBIAN/prerm" "$debian_directory/prerm"
chmod 0644 "$debian_directory/control"
chmod 0755 "$debian_directory/postinst" "$debian_directory/prerm"

dpkg-deb --root-owner-group -Zzstd -b "$staging_directory" "$temporary_deb"
dpkg-deb --info "$temporary_deb" >/dev/null
if [[ "$(dpkg-deb -f "$temporary_deb" Package)" != "$package_id" ||
      "$(dpkg-deb -f "$temporary_deb" Version)" != "$version" ||
      "$(dpkg-deb -f "$temporary_deb" Architecture)" != "$architecture" ]]; then
    echo "error: Debian metadata validation failed" >&2
    exit 65
fi
if ! dpkg-deb --contents "$temporary_deb" | grep -F './var/jb/Applications/Inspector.app/Inspector' >/dev/null; then
    echo "error: Debian package is missing Inspector.app" >&2
    exit 65
fi

mv -f "$temporary_deb" "$output_deb"
echo "Packaged Inspector: $output_deb"
shasum -a 256 "$output_deb"

#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "$#" -ne 14 ]]; then
    echo "usage: $0 <app> <daemon> <cli> <control> <app-entitlements> <daemon-entitlements> <cli-entitlements> <launch-plist> <output-deb> <package-id> <version> <architecture> <flavor> <install-prefix>" >&2
    exit 64
fi

app_bundle="$1"
daemon_binary="$2"
cli_binary="$3"
control_template="$4"
app_entitlements="$5"
daemon_entitlements="$6"
cli_entitlements="$7"
launch_plist="$8"
output_deb="$9"
package_id="${10}"
version="${11}"
architecture="${12}"
flavor="${13}"
install_prefix="${14}"

[[ -d "$app_bundle" && -f "$app_bundle/Info.plist" ]] || { echo "error: incomplete app bundle" >&2; exit 66; }
[[ -x "$daemon_binary" ]] || { echo "error: daemon binary is missing" >&2; exit 66; }
[[ -x "$cli_binary" ]] || { echo "error: cli binary is missing" >&2; exit 66; }
for input in "$control_template" "$app_entitlements" "$daemon_entitlements" "$cli_entitlements" "$launch_plist"; do
    [[ -f "$input" ]] || { echo "error: missing packaging input: $input" >&2; exit 66; }
done
[[ "$output_deb" == *.deb ]] || { echo "error: output must end in .deb" >&2; exit 64; }
[[ "$package_id" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || { echo "error: invalid package id" >&2; exit 64; }
[[ "$version" =~ ^[0-9A-Za-z.+:~_-]+$ ]] || { echo "error: invalid version" >&2; exit 64; }
[[ "$architecture" =~ ^[A-Za-z0-9][A-Za-z0-9-]+$ ]] || { echo "error: invalid architecture" >&2; exit 64; }
case "$flavor" in
    roothide) [[ -z "$install_prefix" ]] || { echo "error: roothide packages install at rootful paths" >&2; exit 64; } ;;
    rootless) [[ "$install_prefix" == /var/jb ]] || { echo "error: rootless packages install under /var/jb" >&2; exit 64; } ;;
    *) echo "error: flavor must be roothide or rootless" >&2; exit 64 ;;
esac

app_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_bundle/Info.plist")"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Info.plist")"
[[ "$bundle_identifier" == wiki.qaq.Inspector && -x "$app_bundle/$app_executable" ]] || {
    echo "error: unexpected app identity" >&2
    exit 65
}

# The package version comes from Configuration/Version.xcconfig, which is also
# what the app was built with — refuse to ship a .deb that disagrees.
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Info.plist")"
[[ "$app_version" == "$version" ]] || {
    echo "error: app version '$app_version' does not match package version '$version'" >&2
    exit 65
}

output_name="$(basename "$output_deb")"
mkdir -p "$(dirname "$output_deb")"
output_directory="$(cd "$(dirname "$output_deb")" && pwd -P)"
output_deb="$output_directory/$output_name"
staging="$(mktemp -d "${TMPDIR:-/tmp}/inspector-deb.XXXXXX")"
temporary_deb="$output_directory/.$output_name.tmp.$$"
app_signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/inspector-app-entitlements.XXXXXX.plist")"
daemon_signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/inspector-daemon-entitlements.XXXXXX.plist")"
cli_signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/inspector-cli-entitlements.XXXXXX.plist")"
trap 'rm -rf "$staging"; rm -f "$temporary_deb" "$app_signed_entitlements" "$daemon_signed_entitlements" "$cli_signed_entitlements"' EXIT
chmod 0755 "$staging"

debian="$staging/DEBIAN"
installed_app="$staging$install_prefix/Applications/Inspector.app"
installed_daemon="$staging$install_prefix/usr/libexec/cocoainspectord"
installed_cli="$staging$install_prefix/usr/bin/cocoainspector"
installed_plist="$staging$install_prefix/Library/LaunchDaemons/wiki.qaq.cocoainspectord.plist"
mkdir -p "$debian" "$(dirname "$installed_app")" "$(dirname "$installed_daemon")" "$(dirname "$installed_cli")" "$(dirname "$installed_plist")"
/usr/bin/ditto "$app_bundle" "$installed_app"
/usr/bin/ditto "$daemon_binary" "$installed_daemon"
/usr/bin/ditto "$cli_binary" "$installed_cli"
sed -e "s|@PREFIX@|$install_prefix|g" "$launch_plist" >"$installed_plist"
rm -rf "$installed_app/_CodeSignature"
rm -f "$installed_app/embedded.mobileprovision"
chmod 0755 "$installed_daemon" "$installed_cli"
chmod 0644 "$installed_plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$installed_plist")" == "$install_prefix/usr/libexec/cocoainspectord" ]] || {
    echo "error: launch daemon plist does not point at the installed daemon" >&2
    exit 65
}

ldid -S"$app_entitlements" -Cadhoc "$installed_app/$app_executable"
ldid -S"$daemon_entitlements" -Cadhoc "$installed_daemon"
ldid -S"$cli_entitlements" -Cadhoc "$installed_cli"
ldid -e "$installed_app/$app_executable" >"$app_signed_entitlements"
ldid -e "$installed_daemon" >"$daemon_signed_entitlements"
ldid -e "$installed_cli" >"$cli_signed_entitlements"

require_true() {
    local plist="$1"
    local key="$2"
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)" == true ]] || {
        echo "error: signed executable is missing entitlement: $key" >&2
        exit 65
    }
}

for entitlement in platform-application com.apple.private.security.no-sandbox com.apple.private.security.storage.AppBundles com.apple.private.security.storage.AppDataContainers wiki.qaq.inspector.client; do
    require_true "$app_signed_entitlements" "$entitlement"
    require_true "$cli_signed_entitlements" "$entitlement"
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.exception.mach-lookup.global-name:0' "$app_signed_entitlements")" == wiki.qaq.inspector.service ]] || {
    echo "error: app is missing the daemon mach lookup entitlement" >&2
    exit 65
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.exception.mach-lookup.global-name:0' "$cli_signed_entitlements")" == wiki.qaq.inspector.service ]] || {
    echo "error: cli is missing the daemon mach lookup entitlement" >&2
    exit 65
}
for entitlement in platform-application com.apple.private.security.no-sandbox com.apple.private.security.storage.AppBundles com.apple.private.security.storage.AppDataContainers com.apple.private.kernel.get-kext-info com.apple.private.network.statistics proc_info-allow task_for_pid-allow com.apple.system-task-ports.read; do
    require_true "$daemon_signed_entitlements" "$entitlement"
done

# DEBIAN is still empty at this point, so this measures only the payload.
installed_size="$(du -sk "$staging" | awk '{print $1}')"
sed \
    -e "s/@PACKAGE_ID@/$package_id/g" \
    -e "s/@VERSION@/$version/g" \
    -e "s/@ARCHITECTURE@/$architecture/g" \
    -e "s/@INSTALLED_SIZE@/$installed_size/g" \
    -e "s/@FLAVOR@/$flavor/g" \
    "$control_template" >"$debian/control"

packaging_root="$(cd "$(dirname "$control_template")/.." && pwd -P)"
for script in postinst prerm; do
    sed -e "s|@PREFIX@|$install_prefix|g" "$packaging_root/DEBIAN/$script" >"$debian/$script"
done
chmod 0644 "$debian/control"
chmod 0755 "$debian/postinst" "$debian/prerm"

dpkg-deb --root-owner-group -Zzstd -b "$staging" "$temporary_deb"
[[ "$(dpkg-deb -f "$temporary_deb" Package)" == "$package_id" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Version)" == "$version" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Architecture)" == "$architecture" ]]
contents="$(dpkg-deb --contents "$temporary_deb")"
grep -F ".$install_prefix/Applications/Inspector.app/Inspector" <<<"$contents" >/dev/null
grep -F ".$install_prefix/usr/libexec/cocoainspectord" <<<"$contents" >/dev/null
grep -F ".$install_prefix/usr/bin/cocoainspector" <<<"$contents" >/dev/null
grep -F ".$install_prefix/Library/LaunchDaemons/wiki.qaq.cocoainspectord.plist" <<<"$contents" >/dev/null

mv -f "$temporary_deb" "$output_deb"
echo "Packaged Inspector ($flavor): $output_deb"
shasum -a 256 "$output_deb"

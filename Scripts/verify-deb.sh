#!/usr/bin/env bash
# Verify a packaged Inspector .deb: control fields, payload layout, and the
# install prefix baked into the LaunchDaemon plist and maintainer scripts.

set -Eeuo pipefail

if [[ "$#" -ne 5 ]]; then
    echo "usage: $0 <deb> <package-id> <version> <architecture> <install-prefix>" >&2
    exit 64
fi

deb="$1"
package_id="$2"
version="$3"
architecture="$4"
install_prefix="$5"

[[ -f "$deb" ]] || { echo "error: missing package: $deb" >&2; exit 66; }

expect() {
    local label="$1" actual="$2" wanted="$3"
    [[ "$actual" == "$wanted" ]] || {
        echo "error: $label is '$actual', expected '$wanted'" >&2
        exit 65
    }
}

expect "Package" "$(dpkg-deb -f "$deb" Package)" "$package_id"
expect "Version" "$(dpkg-deb -f "$deb" Version)" "$version"
expect "Architecture" "$(dpkg-deb -f "$deb" Architecture)" "$architecture"

contents="$(dpkg-deb --contents "$deb")"
for payload in \
    "/Applications/Inspector.app/Inspector" \
    "/Applications/Inspector.app/AppIcon60x60@2x.png" \
    "/Applications/Inspector.app/AppIcon76x76@2x~ipad.png" \
    "/usr/libexec/cocoainspectord" \
    "/usr/bin/cocoainspector" \
    "/Applications/Inspector.app/Frameworks/libswift_Concurrency.dylib" \
    "/usr/lib/cocoainspector/libswift_Concurrency.dylib" \
    "/Library/LaunchDaemons/wiki.qaq.cocoainspectord.plist"
do
    grep -F ".$install_prefix$payload" <<<"$contents" >/dev/null || {
        echo "error: package is missing $install_prefix$payload" >&2
        exit 65
    }
done

# Nothing may ship outside the prefix: on rootless every path lives under
# /var/jb, and a stray rootful path would install onto the sealed system.
if [[ -n "$install_prefix" ]]; then
    allowed=("./")
    walked="./"
    while IFS= read -r component; do
        walked="$walked$component/"
        allowed+=("$walked")
    done < <(tr '/' '\n' <<<"${install_prefix#/}")
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        [[ "$path" == ".$install_prefix/"* ]] && continue
        printf '%s\n' "${allowed[@]}" | grep -Fxq "$path" || {
            echo "error: package ships '$path' outside $install_prefix" >&2
            exit 65
        }
    done < <(awk '{print $6}' <<<"$contents")
fi

payload_root="$(mktemp -d "${TMPDIR:-/tmp}/inspector-verify.XXXXXX")"
trap 'rm -rf "$payload_root"' EXIT
dpkg-deb -x "$deb" "$payload_root"
expect "LaunchDaemon program" \
    "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$payload_root$install_prefix/Library/LaunchDaemons/wiki.qaq.cocoainspectord.plist")" \
    "$install_prefix/usr/libexec/cocoainspectord"

for script in postinst prerm; do
    body="$(dpkg-deb -I "$deb" "$script")"
    if grep -F '@PREFIX@' <<<"$body" >/dev/null; then
        echo "error: $script kept an unsubstituted install prefix" >&2
        exit 65
    fi
done

dpkg-deb -I "$deb" postinst \
    | grep -F "$install_prefix/Library/LaunchDaemons/wiki.qaq.cocoainspectord.plist" >/dev/null || {
    echo "error: postinst does not bootstrap the installed LaunchDaemon plist" >&2
    exit 65
}

echo "Verified $(basename "$deb") ($architecture, prefix '${install_prefix:-/}')"

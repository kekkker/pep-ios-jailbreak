#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
source_file="$script_dir/Sources/AppDelegate.swift"
info_plist="$script_dir/Info.plist"
build_root="$script_dir/build"
payload_dir="$build_root/Payload"
app_name="LocalNotificationControl"
app_bundle="$payload_dir/$app_name.app"
executable="$app_bundle/$app_name"
ipa="$build_root/$app_name-unsigned.ipa"

if [[ $(uname -s) != "Darwin" ]]; then
    echo "This script requires macOS with Xcode installed." >&2
    exit 1
fi

for input in "$source_file" "$info_plist"; do
    if [[ ! -f "$input" ]]; then
        echo "Missing build input: $input" >&2
        exit 1
    fi
done

developer_dir=${DEVELOPER_DIR:-$(xcode-select -p)}
export DEVELOPER_DIR="$developer_dir"

sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
swift_compiler=$(xcrun --sdk iphoneos --find swiftc)

rm -rf "$build_root"
mkdir -p "$app_bundle"

"$swift_compiler" \
    -sdk "$sdk_path" \
    -target arm64-apple-ios16.0 \
    -swift-version 5 \
    -parse-as-library \
    -whole-module-optimization \
    -O \
    -module-name "$app_name" \
    -framework UIKit \
    -framework UserNotifications \
    "$source_file" \
    -o "$executable"

cp "$info_plist" "$app_bundle/Info.plist"
plutil -lint "$app_bundle/Info.plist"
chmod 0755 "$executable"

# New Apple linkers can attach an ad-hoc signature while producing a Mach-O.
# Strip it so the IPA has a deliberately unsigned executable for ldid or
# TrollStore to sign with its normal non-platform identity.
if codesign --display "$executable" >/dev/null 2>&1; then
    codesign --remove-signature "$executable"
fi

if codesign --display "$executable" >/dev/null 2>&1; then
    echo "The generated executable is unexpectedly signed." >&2
    exit 1
fi

# Normalize archive member timestamps so identical inputs and toolchains
# produce a byte-for-byte identical IPA. Callers can override the default
# timestamp with a Unix SOURCE_DATE_EPOCH value.
source_date_epoch=${SOURCE_DATE_EPOCH:-946684800}
if [[ ! "$source_date_epoch" =~ ^[0-9]+$ ]]; then
    echo "SOURCE_DATE_EPOCH must be a non-negative Unix timestamp." >&2
    exit 1
fi
archive_timestamp=$(date -u -r "$source_date_epoch" +%Y%m%d%H%M.%S)
TZ=UTC touch -t "$archive_timestamp" "$executable" "$app_bundle/Info.plist"
TZ=UTC touch -t "$archive_timestamp" "$app_bundle" "$payload_dir"

(
    cd "$build_root"
    COPYFILE_DISABLE=1 ditto -c -k --keepParent Payload "$ipa"
)

echo "Built unsigned IPA:"
echo "$ipa"
file "$executable"

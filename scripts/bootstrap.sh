#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
work_root="$repo_root/work"

rm -rf "$work_root"
mkdir -p "$work_root"

git clone --filter=blob:none https://codeberg.org/pEp/pEpForiOS-build.git "$work_root/pEpForiOS-build"

"$repo_root/scripts/clone-pinned.sh" \
    "$work_root/pEpForiOS-build/.submodules.json" \
    "$work_root"

"$repo_root/scripts/clone-pinned.sh" \
    "$work_root/pEpForiOS.XCFrameworks/.submodules.json" \
    "$work_root/pEpForiOS.XCFrameworks"

git -C "$work_root/pEpForiOS" apply \
    "$repo_root/patches/oauth-login-hint.patch"

git -C "$work_root/pEpForiOS" apply \
    "$repo_root/patches/compact-toolbar-unread-crash.patch"

git -C "$work_root/pEpForiOS" apply \
    "$repo_root/patches/notification-background-diagnostics.patch"

git -C "$work_root/pEpForiOS" apply \
    "$repo_root/patches/background-task-identifier.patch"

git -C "$work_root/pEpForiOS" apply \
    "$repo_root/patches/trollstore-legacy-background-fetch.patch"

git -C "$work_root/pEpForiOS" apply \
    "$repo_root/patches/near-instant-mail-notifications.patch"

git -C "$work_root/pEpForiOS" apply \
    "$repo_root/patches/pep-native-daemon-support.patch"

git -C "$work_root/pEpForiOS" apply \
    "$repo_root/patches/native-same-executable-notifications.patch"

git -C "$work_root/pEpForiOS" apply \
    "$repo_root/patches/preserve-delivered-notifications.patch"

mkdir -p "$work_root/pEpForiOS-intern/pEp4iosIntern"
cp -R "$repo_root/shim/pEp4iosIntern/." "$work_root/pEpForiOS-intern/pEp4iosIntern/"
cp "$repo_root/shim/secret.xcconfig" "$work_root/pEpForiOS-intern/secret.xcconfig"
xcodegen generate \
    --spec "$work_root/pEpForiOS-intern/pEp4iosIntern/project.yml" \
    --project "$work_root/pEpForiOS-intern/pEp4iosIntern"

# Current upstream raised only the app target to iOS 18.5. Its dependency
# builder still targets iOS 12. Lower all explicit app/test targets to iOS 16.
perl -pi -e 's/IPHONEOS_DEPLOYMENT_TARGET = 18\.5;/IPHONEOS_DEPLOYMENT_TARGET = 16.0;/g' \
    "$work_root/pEpForiOS/pEpForiOS.xcodeproj/project.pbxproj"

# Use the SDK selected by xcrun instead of requiring copied Xcode 14 SDKs.
perl -pi -e 's/"iphoneos18\.5"/"iphoneos"/g; s/"iphonesimulator18\.5"/"iphonesimulator"/g; s/"macosx26\.2"/"macosx"/g' \
    "$work_root/pEpForiOS.XCFrameworks/src/platform.zig"

# This pipeline produces a device-only IPA. Building simulator and universal
# macOS slices triples the native work and is unnecessary for an iphoneos app.
perl -pi -e 's/const Platforms = \[_\]Platform\{ \.macosx, \.iphoneos, \.iphonesimulator \};/const Platforms = [_]Platform{ .iphoneos };/; s/const Archs = \[_\]Arch\{ \.arm64, \.x86_64 \};/const Archs = [_]Arch{ .arm64 };/;' \
    "$work_root/pEpForiOS.XCFrameworks/src/build.zig"

# Autoconf 2.72 selects C23 by default, but libetpan still contains valid
# K&R-style definitions that C23 removed. Keep this legacy dependency on C17.
perl -pi -e 's/^AC_PROG_CC$/AC_PROG_CC\nCC="\$CC -std=gnu17"/' \
    "$work_root/pEpForiOS.XCFrameworks/libetpan/configure.ac"

echo "Bootstrap complete: $work_root"

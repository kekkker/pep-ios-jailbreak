#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
work_root="$repo_root/work"
derived_data="$repo_root/DerivedData"
artifacts="$repo_root/artifacts"

export PATH="/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/opt/libtool/libexec/gnubin:$PATH"

rustup target add \
    aarch64-apple-ios \
    aarch64-apple-ios-sim \
    aarch64-apple-darwin
if ! command -v cargo-cbuild >/dev/null; then
    cargo install cargo-c
fi

if [[ ! -d "$HOME/yml2/.git" ]]; then
    git clone https://codeberg.org/fdik/yml2.git "$HOME/yml2"
fi

pushd "$work_root/pEpForiOS.XCFrameworks"
zig build run
popd

rm -rf "$derived_data" "$artifacts"
mkdir -p "$derived_data" "$artifacts"

set -o pipefail
xcodebuild \
    -workspace "$work_root/pEpForiOS/pEpForiOS.xcworkspace" \
    -scheme pEp \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived_data" \
    IPHONEOS_DEPLOYMENT_TARGET=16.0 \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    DEVELOPMENT_TEAM= \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS=arm64 \
    ENABLE_MODULE_VERIFIER=NO \
    build | tee "$artifacts/xcodebuild.log"

app=$(find "$derived_data/Build/Products/Release-iphoneos" -maxdepth 1 -type d -name '*.app' -print -quit)
if [[ -z "$app" ]]; then
    echo "No application bundle was produced" >&2
    exit 1
fi

sdk=$(xcrun --sdk iphoneos --show-sdk-path)
products=$(dirname "$app")
native_build="$repo_root/build/native-notifier"
rm -rf "$native_build"
mkdir -p "$native_build"

# Build a tiny host executable against the exact MessageModel framework that
# xcodebuild just embedded in pEp.app. The embedded copy has its compiler
# modules stripped, so compile against the unstripped sibling product and load
# the embedded copy at runtime. It contains no IMAP implementation.
if [[ ! -d "$products/MessageModel.framework/Modules/MessageModel.swiftmodule" ]]; then
    echo "Unstripped MessageModel compiler module was not produced" >&2
    exit 1
fi
xcrun --sdk iphoneos swiftc \
    -target arm64-apple-ios16.0 \
    -sdk "$sdk" \
    -I "$products" \
    -F "$products" \
    -Xcc -I"$work_root/pEpForiOS.XCFrameworks/pEpEngine/build-mac/include" \
    "$repo_root/notifier/pep-native-notifier.swift" \
    -framework MessageModel \
    -framework UserNotifications \
    -Xlinker -rpath \
    -Xlinker @executable_path/Frameworks \
    -o "$app/pEpNativeNotifier"

for architecture in arm64 arm64e; do
    xcrun --sdk iphoneos clang \
        -fobjc-arc \
        -dynamiclib \
        -target "${architecture}-apple-ios16.0" \
        -isysroot "$sdk" \
        -framework Foundation \
        -Wl,-undefined,dynamic_lookup \
        -Wl,-install_name,/var/jb/Library/MobileSubstrate/DynamicLibraries/pep-notifier-bridge.dylib \
        "$repo_root/notifier/pep-notifier-bridge.m" \
        -o "$native_build/pep-notifier-bridge-${architecture}.dylib"
done
xcrun lipo -create \
    "$native_build/pep-notifier-bridge-arm64.dylib" \
    "$native_build/pep-notifier-bridge-arm64e.dylib" \
    -output "$native_build/pep-notifier-bridge.dylib"

# TrollStore preserves entitlements already present on an ldid-fakesigned
# executable. The application stores its Core Data database in this app-group
# container and aborts at launch when the entitlement is absent.
ldid -S"$repo_root/signing/pEp-trollstore.entitlements" \
    "$app/pEpNativeNotifier"
ldid -S"$repo_root/signing/pEp-trollstore.entitlements" \
    "$app/$(defaults read "$app/Info" CFBundleExecutable)"
ldid -S "$native_build/pep-notifier-bridge.dylib"

mkdir -p "$artifacts/Payload"
cp -R "$app" "$artifacts/Payload/"
(
    cd "$artifacts"
    ditto -c -k --sequesterRsrc --keepParent Payload pEp-iOS16-trollstore.ipa
)

package="$repo_root/build/package"
rm -rf "$package"
mkdir -p \
    "$package/DEBIAN" \
    "$package/var/jb/usr/libexec" \
    "$package/var/jb/Library/LaunchDaemons" \
    "$package/var/jb/Library/MobileSubstrate/DynamicLibraries"

cp "$repo_root/notifier/control" "$package/DEBIAN/control"
cp "$repo_root/notifier/postinst" "$package/DEBIAN/postinst"
cp "$repo_root/notifier/prerm" "$package/DEBIAN/prerm"
cp "$repo_root/notifier/pep-native-notifier-launcher" \
    "$package/var/jb/usr/libexec/"
cp "$repo_root/notifier/software.pep.notifier.plist" \
    "$package/var/jb/Library/LaunchDaemons/"
cp "$native_build/pep-notifier-bridge.dylib" \
    "$package/var/jb/Library/MobileSubstrate/DynamicLibraries/"
cp "$repo_root/notifier/pep-notifier-bridge.plist" \
    "$package/var/jb/Library/MobileSubstrate/DynamicLibraries/"

chmod 755 \
    "$package/DEBIAN/postinst" \
    "$package/DEBIAN/prerm" \
    "$package/var/jb/usr/libexec/pep-native-notifier-launcher" \
    "$package/var/jb/Library/MobileSubstrate/DynamicLibraries/pep-notifier-bridge.dylib"
chmod 644 \
    "$package/DEBIAN/control" \
    "$package/var/jb/Library/LaunchDaemons/software.pep.notifier.plist" \
    "$package/var/jb/Library/MobileSubstrate/DynamicLibraries/pep-notifier-bridge.plist"

dpkg-deb --root-owner-group --build "$package" \
    "$artifacts/software.pep.notifier_1.0.5_iphoneos-arm64.deb"

file "$app/$(defaults read "$app/Info" CFBundleExecutable)"
file "$app/pEpNativeNotifier"
codesign -d --entitlements :- "$app" 2>/dev/null || true
ls -lh \
    "$artifacts/pEp-iOS16-trollstore.ipa" \
    "$artifacts/software.pep.notifier_1.0.5_iphoneos-arm64.deb"

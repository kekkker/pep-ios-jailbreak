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

# TrollStore preserves entitlements already present on an ldid-fakesigned
# executable. The application stores its Core Data database in this app-group
# container and aborts at launch when the entitlement is absent.
ldid -S"$repo_root/signing/pEp-trollstore.entitlements" \
    "$app/$(defaults read "$app/Info" CFBundleExecutable)"

mkdir -p "$artifacts/Payload"
cp -R "$app" "$artifacts/Payload/"
(
    cd "$artifacts"
    ditto -c -k --sequesterRsrc --keepParent Payload pEp-iOS16-trollstore.ipa
)

file "$app/$(defaults read "$app/Info" CFBundleExecutable)"
codesign -d --entitlements :- "$app" 2>/dev/null || true
ls -lh "$artifacts/pEp-iOS16-trollstore.ipa"

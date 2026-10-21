#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) MultiDock.app next to this script.
set -e
cd "$(dirname "$0")"

APP=build/MultiDock.app
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $ARCH-apple-macosx14.0 \
    -framework AppKit -framework ServiceManagement -framework SwiftUI \
    -o build/obj/MultiDock-$ARCH Sources/*.swift
done
lipo -create build/obj/MultiDock-arm64 build/obj/MultiDock-x86_64 -output "$APP/Contents/MacOS/MultiDock"

cp Info.plist "$APP/Contents/Info.plist"
[[ -f AppIcon.icns ]] && cp AppIcon.icns "$APP/Contents/Resources/"

# SIGN_IDENTITY is MultiDock's signing certificate (set in CI); without it
# the app is signed ad hoc, which is fine for trying out local builds.
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $PWD/$APP"

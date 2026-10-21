#!/bin/zsh
# Builds MultiDock and makes the two release files:
#   dist/MultiDock.dmg  — for new installs (app + Applications shortcut + instructions)
#   dist/MultiDock.zip  — what the in-app updater downloads
set -e
cd "$(dirname "$0")"

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
STAGE=build/dmg
rm -rf "$STAGE" dist/MultiDock*.dmg(N) dist/MultiDock.zip(N)
mkdir -p "$STAGE"

cp -R build/MultiDock.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "dist/How to Install.txt" "$STAGE/"

hdiutil create -volname "MultiDock $VERSION" -srcfolder "$STAGE" -ov -format UDZO dist/MultiDock.dmg >/dev/null
ditto -c -k --keepParent build/MultiDock.app dist/MultiDock.zip
echo "Packaged MultiDock $VERSION: dist/MultiDock.dmg, dist/MultiDock.zip"

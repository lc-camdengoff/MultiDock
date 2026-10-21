#!/bin/zsh
# Publishes a new MultiDock version to GitHub Releases. Everyone's copy of the
# app sees it within a few hours (or right away via Check for Updates).
#
#   ./release.sh 1.1 "Added top-corner docks, fixed the label flicker"
set -e
cd "$(dirname "$0")"

VERSION=$1
NOTES=${2:-"MultiDock $VERSION"}
if [[ -z "$VERSION" ]]; then
  echo "usage: ./release.sh <version> [release notes]" >&2
  exit 1
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "Releases must be signed with MultiDock's certificate. Use Actions → Release on GitHub." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash your changes first." >&2
  exit 1
fi

BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $BUILD" Info.plist

./package.sh

git commit -am "Release v$VERSION"
git tag "v$VERSION"
git push origin HEAD "v$VERSION"

gh release create "v$VERSION" dist/MultiDock.dmg dist/MultiDock.zip --title "MultiDock $VERSION" --notes "$NOTES"
echo "Released v$VERSION"

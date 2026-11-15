#!/bin/bash
# Baut eine universelle VideoMaster.app (Apple Silicon + Intel) und packt sie in
# build/VideoMaster-<Version>.dmg. Die App ist nur ad hoc signiert (keine Developer ID),
# deshalb install.sh aus dem DMG ausführen (siehe README).
set -euo pipefail
cd "$(dirname "$0")"

./build_app.sh

echo "Baue die Intel-Version…"
swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build-x86
ARM="$(swift build -c release --show-bin-path)/VideoMaster"
X86=".build-x86/x86_64-apple-macosx/release/VideoMaster"

APP="build/VideoMaster.app"
lipo -create "$ARM" "$X86" -output "$APP/Contents/MacOS/VideoMaster"
codesign --force --sign - "$APP" >/dev/null
lipo -info "$APP/Contents/MacOS/VideoMaster"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/VideoMaster-$VERSION.dmg"
STAGE="$(mktemp -d)/VideoMaster"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp install.sh "$STAGE/install.sh"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "VideoMaster $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo ""
echo "Fertig: $(pwd)/$DMG"

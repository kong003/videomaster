#!/bin/zsh
# Baut VideoMaster.app (benötigt nur Swift / Command Line Tools, kein Xcode)
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/VideoMaster.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VideoMaster "$APP/Contents/MacOS/VideoMaster"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VideoMaster</string>
  <key>CFBundleDisplayName</key><string>VideoMaster</string>
  <key>CFBundleIdentifier</key><string>local.videomaster.app</string>
  <key>CFBundleExecutable</key><string>VideoMaster</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Video</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.movie</string><string>public.audiovisual-content</string></array>
    </dict>
  </array>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "Fertig: $APP"

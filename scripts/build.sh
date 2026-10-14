#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
mkdir -p dist/'UGOS Sync.app'/Contents/{MacOS,Resources}
cp .build/release/UGOSSync dist/'UGOS Sync.app'/Contents/MacOS/UGOSSync
cp .build/release/UGOSSyncDaemon dist/'UGOS Sync.app'/Contents/MacOS/UGOSSyncDaemon
cp .build/release/UGOSSyncEngine dist/'UGOS Sync.app'/Contents/MacOS/UGOSSyncEngine
cat > dist/'UGOS Sync.app'/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.nakutop.ugos-sync</string>
<key>CFBundleName</key><string>UGOS Sync</string>
<key>CFBundleExecutable</key><string>UGOSSync</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - dist/'UGOS Sync.app'/Contents/MacOS/UGOSSyncDaemon
codesign --force --sign - dist/'UGOS Sync.app'/Contents/MacOS/UGOSSyncEngine
codesign --force --sign - dist/'UGOS Sync.app'
codesign --verify --strict dist/'UGOS Sync.app'

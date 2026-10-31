#!/bin/bash
# Build "Stablecoin Yield.app" with CommandLineTools' swiftc only.
# No Xcode project, no xcodebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Stablecoin Yield.app"
BIN_NAME="StablecoinYield"

echo "==> Cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling Swift"
swiftc \
  -O \
  -target arm64-apple-macosx14.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework WebKit \
  -framework Foundation \
  -o "$APP/Contents/MacOS/$BIN_NAME" \
  "$ROOT/Sources/main.swift" \
  "$ROOT/Sources/Models.swift" \
  "$ROOT/Sources/DataSources.swift" \
  "$ROOT/Sources/Verifier.swift" \
  "$ROOT/Sources/AppModel.swift" \
  "$ROOT/Sources/ContentView.swift" \
  "$ROOT/Sources/WebView.swift"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Stablecoin Yield</string>
  <key>CFBundleDisplayName</key>       <string>Stablecoin Yield</string>
  <key>CFBundleExecutable</key>        <string>StablecoinYield</string>
  <key>CFBundleIdentifier</key>        <string>local.stablecoin.yield</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing (so network + subprocess calls are permitted)"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "    (codesign skipped - app is unsigned but still runnable)"

echo "==> Done: $APP"
ls -la "$APP/Contents/MacOS/"
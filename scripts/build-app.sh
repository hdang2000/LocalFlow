#!/bin/sh
# Builds LocalFlow.app (release) in the temporary build directory. Pass --install to copy it to ~/Applications.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
build="${TMPDIR:-/tmp}/localflow-build"
cd "$root"
swift build -c release --scratch-path "$build" --product LocalFlow
# Staged outside the project so Spotlight/Launchpad show only the installed copy.
app="$build/LocalFlow.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$build/release/LocalFlow" "$app/Contents/MacOS/LocalFlow"
cp "$root/Assets/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.localflow.LocalFlow</string>
  <key>CFBundleName</key><string>LocalFlow</string>
  <key>CFBundleExecutable</key><string>LocalFlow</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>LocalFlow records your voice while you hold the dictation shortcut and transcribes it on this Mac.</string>
</dict></plist>
PLIST
# macOS ties Accessibility/Microphone grants to the signature. A stable local
# certificate (scripts/make-signing-cert.sh) keeps grants across rebuilds;
# without it the build is ad-hoc signed and grants must be renewed each time.
signing="$HOME/Library/Application Support/LocalFlow/signing"
if [ -f "$signing/localflow-signing.keychain-db" ]; then
  security unlock-keychain -p "$(cat "$signing/keychain-password")" "$signing/localflow-signing.keychain-db"
  codesign --force --keychain "$signing/localflow-signing.keychain-db" --sign "LocalFlow Local Signing" "$app"
else
  echo "warning: no local signing certificate; ad-hoc signing (run scripts/make-signing-cert.sh)" >&2
  codesign --force --sign - "$app"
fi
echo "Built $app"
if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/LocalFlow.app"
  cp -R "$app" "$HOME/Applications/LocalFlow.app"
  echo "Installed to ~/Applications/LocalFlow.app"
fi

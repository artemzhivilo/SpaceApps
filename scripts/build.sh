#!/bin/zsh
# Build SpaceApps, bundle it as an app, install it to ~/Applications and start it.
#   scripts/build.sh            build, install, (re)start
#   scripts/build.sh --no-run   build and install only
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/SpaceApps.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SpaceApps "$APP/Contents/MacOS/SpaceApps"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>SpaceApps</string>
    <key>CFBundleDisplayName</key><string>SpaceApps</string>
    <key>CFBundleIdentifier</key><string>com.artem.SpaceApps</string>
    <key>CFBundleExecutable</key><string>SpaceApps</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Artem Zhivilo. MIT License.</string>
</dict>
</plist>
PLIST

# Sign with your Apple Development certificate if you have one (Xcode → Settings → Accounts),
# so macOS keeps SpaceApps' Accessibility permission across rebuilds. Otherwise sign ad hoc,
# and turn Accessibility off and on again after each rebuild.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad hoc}"

# Install and (re)start
pkill -x SpaceApps 2>/dev/null || true
for _ in {1..30}; do pgrep -xq SpaceApps || break; sleep 0.1; done  # wait for it to quit
mkdir -p ~/Applications
rm -rf ~/Applications/SpaceApps.app
cp -R "$APP" ~/Applications/SpaceApps.app
echo "Installed ~/Applications/SpaceApps.app"
[[ "${1:-}" == "--no-run" ]] || open ~/Applications/SpaceApps.app

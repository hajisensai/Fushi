#!/bin/bash
# --------------------------------------------------------------------------
# package_mac.sh - Build shadow JAR -> custom JRE (jlink) -> macOS .app bundle
#
# No jpackage required. The full JRE is embedded inside the .app.
#
# Usage:
#   chmod +x package_mac.sh
#   ./package_mac.sh            # builds .dmg in dist/
# --------------------------------------------------------------------------
set -euo pipefail

APP_NAME="MExtensionServer"
BUNDLE_ID="com.mangayomi.mextensionserver"
DEST="dist"
APP_BUNDLE="$DEST/${APP_NAME}.app"
# Always create DMG as requested
CREATE_DMG=true

# Parse args if any (for future proofing, though default is now true)
for arg in "$@"; do
  [[ "$arg" == "--no-dmg" ]] && CREATE_DMG=false
done

ICON_SRC="server/src/main/resources/icon-black.png"

# Check tools
for tool in jlink java sips iconutil; do
  if ! command -v "$tool" &>/dev/null; then
    echo "Error: '$tool' not found. Make sure JAVA_HOME points to a JDK 17+."
    exit 1
  fi
done

# Build shadow JAR
echo "[*] Building shadow JAR..."
./gradlew shadowJar

JAR_FILE=$(ls server/build/${APP_NAME}-*.jar 2>/dev/null | head -1)
if [[ -z "$JAR_FILE" ]]; then
  echo "Error: shadow JAR not found in server/build/"
  exit 1
fi
JAR_NAME=$(basename "$JAR_FILE")
echo "  JAR: $JAR_FILE"

# Convert PNG icon -> ICNS
ICNS_FILE=""
if [[ -f "$ICON_SRC" ]]; then
  echo ""
  echo "[*] Converting icon to .icns..."
  ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET_DIR"
  # Generate all required sizes from the source PNG
  for SIZE in 16 32 64 128 256 512; do
    sips -z $SIZE $SIZE "$ICON_SRC" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}.png"       &>/dev/null
    sips -z $((SIZE*2)) $((SIZE*2)) "$ICON_SRC" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}@2x.png" &>/dev/null
  done
  ICNS_FILE="$(mktemp -d)/AppIcon.icns"
  iconutil --convert icns --output "$ICNS_FILE" "$ICONSET_DIR"
  rm -rf "$(dirname "$ICONSET_DIR")"
  echo "  Icon: $ICNS_FILE"
else
  echo "  Warning: icon not found at $ICON_SRC - skipping"
fi

# Build custom JRE with jlink
JRE_TMPDIR="$(pwd)/.jre_build_tmp"
rm -rf "$JRE_TMPDIR"

echo ""
echo "[*] Building custom JRE with jlink..."
jlink \
  --add-modules \
  java.base,java.compiler,java.datatransfer,java.desktop,java.instrument,\
java.logging,java.management,java.naming,java.prefs,java.scripting,java.se,\
java.security.jgss,java.security.sasl,java.sql,java.transaction.xa,java.xml,\
jdk.attach,jdk.crypto.ec,jdk.jdi,jdk.management,jdk.net,jdk.unsupported,\
jdk.unsupported.desktop,jdk.zipfs,jdk.accessibility \
  --output "$JRE_TMPDIR" \
  --strip-debug \
  --no-man-pages \
  --no-header-files \
  --compress=2

echo "  JRE size: $(du -sh "$JRE_TMPDIR" | cut -f1)"

# Assemble .app bundle
echo ""
echo "[*] Assembling ${APP_NAME}.app..."

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Java"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 4a. Embed JRE
cp -R "$JRE_TMPDIR" "$APP_BUNDLE/Contents/runtime"
rm -rf "$JRE_TMPDIR"

# 4b. Copy JAR
cp "$JAR_FILE" "$APP_BUNDLE/Contents/Java/$JAR_NAME"

# 4c. Copy icon
if [[ -n "$ICNS_FILE" && -f "$ICNS_FILE" ]]; then
  cp "$ICNS_FILE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$ICNS_FILE")"
fi

# 4d. Launcher script (the executable macOS runs)
LAUNCHER="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cat > "$LAUNCHER" << 'LAUNCHER_EOF'
#!/bin/bash
# Resolve the bundle's real path even when launched via symlink / Finder
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTENTS="$(cd "$SCRIPT_DIR/.." && pwd)"
JAVA="$CONTENTS/runtime/bin/java"
JAR=$(ls "$CONTENTS/Java/"*.jar | head -1)

exec "$JAVA" \
  -Xmx512m \
  --add-opens=java.base/java.lang=ALL-UNNAMED \
  --add-opens=java.base/java.util=ALL-UNNAMED \
  --add-opens=java.base/java.lang.reflect=ALL-UNNAMED \
  -Dapple.awt.application.name="MExtension Server" \
  -Dapple.laf.useScreenMenuBar=true \
  -jar "$JAR" \
  --ui \
  "$@"
LAUNCHER_EOF
chmod +x "$LAUNCHER"

# 4e. Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>MExtension Server</string>
    <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleVersion</key>         <string>1.0.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>  <string>11.0</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key>
        <string>Copyright © 2026 kodjodevf. MPL-2.0.</string>
    <key>LSApplicationCategoryType</key>
        <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST_EOF

# 4f. PkgInfo (required by macOS)
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Reset macOS icon cache so Finder picks up the new icon immediately
if command -v /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister &>/dev/null; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_BUNDLE" &>/dev/null || true
fi

# 5. Create .dmg via hdiutil
if $CREATE_DMG; then
  DMG_PATH="$DEST/${APP_NAME}.dmg"
  STAGING="$(mktemp -d)"

  echo ""
  echo "[*] Building DMG..."
  cp -R "$APP_BUNDLE" "$STAGING/"
  rm -rf "$APP_BUNDLE"

  # Create symlink so users can drag to Applications
  ln -s /Applications "$STAGING/Applications"

  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH" \
    -quiet

  rm -rf "$STAGING"

  echo "✓  DMG created: $DMG_PATH"
else
  # If not creating DMG, at least keep the .app or notify
  echo "✓  Bundle created: $APP_BUNDLE (no DMG)"
fi

echo ""
echo "[OK] Mac packaging complete!"

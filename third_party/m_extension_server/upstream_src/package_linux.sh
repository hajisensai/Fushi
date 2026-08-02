#!/bin/bash
# --------------------------------------------------------------------------
# package_linux.sh - Build shadow JAR -> custom JRE (jlink) -> Linux bundle
#
# Creates a portable .tar.gz bundle with embedded JRE.
# Optionally creates an AppImage (requires appimagetool).
# Optionally creates a .deb package (requires dpkg, fakeroot).
#
# Usage:
#   chmod +x package_linux.sh
#   ./package_linux.sh                    # builds everything (portable, .appimage, .deb)
#   ./package_linux.sh --no-appimage      # skip AppImage
#   ./package_linux.sh --no-deb           # skip .deb
# --------------------------------------------------------------------------
set -euo pipefail

APP_NAME="MExtensionServer"
BUNDLE_NAME="MExtensionServer-Linux-x64"
DEST="dist"
BUILD_APPIMAGE=true
BUILD_DEB=true
ICON_SRC="server/src/main/resources/icon-black.png"

for arg in "$@"; do
  [[ "$arg" == "--no-appimage" ]] && BUILD_APPIMAGE=false
  [[ "$arg" == "--no-deb" ]] && BUILD_DEB=false
done

# Check tools
echo "[*] Checking prerequisites..."

for tool in jlink java; do
  if ! command -v "$tool" &>/dev/null; then
    echo "Error: '$tool' not found. Make sure JAVA_HOME points to a JDK 17+."
    exit 1
  fi
done

# Check optional tools
if $BUILD_APPIMAGE && ! command -v appimagetool &>/dev/null; then
  echo "  [!] Warning: appimagetool not found. AppImage build will be skipped."
  echo "      Install: https://github.com/AppImage/AppImageKit/releases"
  BUILD_APPIMAGE=false
fi

if $BUILD_DEB && ! command -v dpkg &>/dev/null; then
  echo "  [!] Warning: dpkg not found. .deb build will be skipped."
  echo "      Install: sudo apt-get install dpkg fakeroot"
  BUILD_DEB=false
fi

# Build shadow JAR
echo ""
echo "[*] Building shadow JAR..."
./gradlew shadowJar

JAR_FILE=$(ls server/build/${APP_NAME}-*.jar 2>/dev/null | head -1)
if [[ -z "$JAR_FILE" ]]; then
  echo "Error: JAR not found in server/build/"
  exit 1
fi
JAR_NAME=$(basename "$JAR_FILE")
echo "  JAR: $JAR_FILE"

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

JRE_SIZE=$(du -sh "$JRE_TMPDIR" | cut -f1)
echo "  JRE size: $JRE_SIZE"

# Assemble bundle
echo ""
echo "[*] Assembling Linux bundle..."

BUNDLE_DIR="$DEST/$BUNDLE_NAME"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/jre" "$BUNDLE_DIR/bin"

# 3a. Copy JRE
cp -R "$JRE_TMPDIR" "$BUNDLE_DIR/jre/runtime"
rm -rf "$JRE_TMPDIR"

# 3b. Copy JAR
cp "$JAR_FILE" "$BUNDLE_DIR/$JAR_NAME"

# 3c. Launcher script (bash)
cat > "$BUNDLE_DIR/launcher.sh" << 'LAUNCHER_EOF'
#!/bin/bash
# Resolve the bundle's real path even when symlinked
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAVA="$SCRIPT_DIR/jre/runtime/bin/java"
JAR=$(ls "$SCRIPT_DIR"/*.jar | head -1)

exec "$JAVA" \
  -Xmx512m \
  --add-opens=java.base/java.lang=ALL-UNNAMED \
  --add-opens=java.base/java.util=ALL-UNNAMED \
  --add-opens=java.base/java.lang.reflect=ALL-UNNAMED \
  -jar "$JAR" \
  --ui \
  "$@"
LAUNCHER_EOF
chmod +x "$BUNDLE_DIR/launcher.sh"

# 3d. Copy icon to bundle
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$BUNDLE_DIR/icon.png"
fi

# 3e. Create README
cat > "$BUNDLE_DIR/README.txt" << 'README_EOF'
MExtension Server for Linux
=============================

QUICK START:
  ./launcher.sh

Or with custom port/directory:
  ./launcher.sh 8080 ./config

REQUIREMENTS:
  None! Everything is bundled (JRE is included).

UNINSTALL:
  rm -rf this_directory

Installation to system (optional):
  sudo mkdir -p /opt/mextensionserver
  sudo cp -r * /opt/mextensionserver/
  sudo ln -s /opt/mextensionserver/launcher.sh /usr/local/bin/mextensionserver

Or use the .deb package if you built one.

README_EOF

echo "[OK] Bundle created: $BUNDLE_DIR"

# ── 4. Create portable .tar.gz ────────────────────────────────────────────────
echo ""
echo "▸ Creating .tar.gz archive…"
tar -C "$DEST" -czf "$DEST/$BUNDLE_NAME.tar.gz" "$(basename "$BUNDLE_DIR")"
echo "[OK] Portable archive: $DEST/$BUNDLE_NAME.tar.gz"

# Optional: Create AppImage
if $BUILD_APPIMAGE; then
  echo ""
  echo "[*] Creating AppImage..."

  # Install appimagetool if missing (useful for CI)
  if ! command -v appimagetool &>/dev/null; then
    echo "  [!] appimagetool not found. Downloading..."
    curl -Lo appimagetool-x86_64.AppImage https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
    chmod +x appimagetool-x86_64.AppImage
    # We use the local binary to avoid sudo issues
    APPIMAGE_TOOL="./appimagetool-x86_64.AppImage"
  else
    APPIMAGE_TOOL="appimagetool"
  fi

  APPIMAGE_DIR="$(mktemp -d)"
  APP_DIR="$APPIMAGE_DIR/$APP_NAME.AppDir"
  mkdir -p "$APP_DIR/usr/bin" "$APP_DIR/usr/share/applications" "$APP_DIR/usr/share/pixmaps"

  # Copy bundle to AppImage structure
  cp -R "$BUNDLE_DIR"/* "$APP_DIR/"
  ln -sf ../launcher.sh "$APP_DIR/AppRun" || true
  cp "$BUNDLE_DIR/launcher.sh" "$APP_DIR/usr/bin/mextensionserver"

  # Desktop entry
  cat > "$APP_DIR/usr/share/applications/$APP_NAME.desktop" << 'DESKTOP_EOF'
[Desktop Entry]
Type=Application
Name=MExtension Server
Comment=Extensions Inspector
Exec=mextensionserver
Icon=icon
Categories=Utility;
Terminal=false
DESKTOP_EOF

  # Copy icon
  if [[ -f "$BUNDLE_DIR/icon.png" ]]; then
    cp "$BUNDLE_DIR/icon.png" "$APP_DIR/usr/share/pixmaps/icon.png"
  fi

  # Create AppImage
  APPIMAGE_OUTPUT="$DEST/${APP_NAME}-x86_64.AppImage"
  # Use ARCH=x86_64 for compatibility and ensure we don't need fuse with --appimage-extract-and-run if needed
  # However, we installed libfuse2 so it should be fine.
  ARCH=x86_64 $APPIMAGE_TOOL "$APP_DIR" "$APPIMAGE_OUTPUT" -n
  chmod +x "$APPIMAGE_OUTPUT"

  rm -rf "$APPIMAGE_DIR"
  # Clean up the tool if we downloaded it
  if [[ "$APPIMAGE_TOOL" == "./appimagetool-x86_64.AppImage" ]]; then
    rm -f "./appimagetool-x86_64.AppImage"
  fi
  echo "[OK] AppImage: $APPIMAGE_OUTPUT"
fi

# Optional: Create .deb package
if $BUILD_DEB; then
  echo ""
  echo "[*] Creating .deb package..."

  DEB_TMPDIR="$(mktemp -d)"
  DEB_DIR="$DEB_TMPDIR/mextensionserver-1.0.0"

  mkdir -p "$DEB_DIR/DEBIAN" "$DEB_DIR/opt/mextensionserver" "$DEB_DIR/usr/bin"

  # Copy bundle
  cp -R "$BUNDLE_DIR"/* "$DEB_DIR/opt/mextensionserver/"

  # Create symlink in /usr/bin
  ln -sf /opt/mextensionserver/launcher.sh "$DEB_DIR/usr/bin/mextensionserver"

  # Create control file
  cat > "$DEB_DIR/DEBIAN/control" << 'CONTROL_EOF'
Package: mextensionserver
Version: 1.0.0
Architecture: amd64
Maintainer: kodjodevf
Description: MExtension Server
 A headless Mihon (Tachiyomi)/Aniyomi extensions server.
 Everything is bundled, no dependencies required.
CONTROL_EOF

  # Create postinst script for desktop integration
  cat > "$DEB_DIR/DEBIAN/postinst" << 'POSTINST_EOF'
#!/bin/bash
set -e
# Update desktop database if available
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications || true
fi
exit 0
POSTINST_EOF
  chmod +x "$DEB_DIR/DEBIAN/postinst"

  # Build .deb
  DEB_OUTPUT="$DEST/mextensionserver_1.0.0_amd64.deb"
  fakeroot dpkg-deb --build "$DEB_DIR" "$DEB_OUTPUT"

  rm -rf "$DEB_TMPDIR"
  echo "[OK] Debian package: $DEB_OUTPUT"
  echo "     Install with: sudo dpkg -i $DEB_OUTPUT"
fi

echo ""
echo "[OK] Linux packaging complete!"

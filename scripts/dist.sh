#!/usr/bin/env bash
# dist.sh — build an ad-hoc–signed, shareable GrammarBar.app + zip
#
# This produces a *non-notarized* distributable for personal/informal sharing.
# Recipients WILL hit Gatekeeper and must manually allow the app (see the
# instructions printed at the end / in the generated OPEN-ME.txt).
#
# For real distribution to arbitrary Macs, enroll in the Apple Developer
# Program and use a Developer ID certificate + notarization instead.
#
# Usage:
#   bash scripts/dist.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SCHEME="GrammarBar"
CONFIG="Release"
DIST_DIR="$REPO_ROOT/dist"
DERIVED="$DIST_DIR/DerivedData"
ENTITLEMENTS="$REPO_ROOT/Sources/GrammarBar/Resources/GrammarBar.entitlements"

# Single source of truth for the app version.
VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION" 2>/dev/null || echo "0.0.0")"

# Ad-hoc signing identity ("-"). No certificate required, works on any Mac.
SIGN_ID="-"

echo "=== GrammarBar distribution build ==="

# ── 1. Regenerate project (in case project.yml changed) ──────────────────────
if command -v xcodegen &>/dev/null; then
  echo "[1/6] xcodegen generate"
  xcodegen generate >/dev/null
else
  echo "[1/6] xcodegen not found — using existing GrammarBar.xcodeproj"
fi

# ── 2. Clean + Release build (no signing yet; we sign inside-out ourselves) ──
echo "[2/6] Building $SCHEME ($CONFIG)…"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
xcodebuild \
  -project GrammarBar.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

APP="$DERIVED/Build/Products/$CONFIG/GrammarBar.app"
if [ ! -d "$APP" ]; then
  echo "[ERROR] Build did not produce $APP"
  exit 1
fi
echo "      Built: $APP"

# ── 2b. Stamp version into the built app (must happen before signing) ────────
echo "      Stamping version $VERSION into Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# ── 3. Sign nested code inside-out (dylibs + llama-server), hardened runtime ─
echo "[3/6] Signing bundled dylibs + llama-server…"
RES="$APP/Contents/Resources"
while IFS= read -r -d '' lib; do
  codesign --force --timestamp=none --options runtime -s "$SIGN_ID" "$lib"
done < <(find "$RES" -name "*.dylib" -print0)

if [ -f "$RES/llama-server" ]; then
  # llama-server runs as its own subprocess under hardened runtime. It must be
  # signed WITH the entitlements (specifically disable-library-validation) so it
  # can load its sibling ad-hoc-signed dylibs — otherwise library validation
  # rejects them ("different Team IDs") and the server fails to start.
  codesign --force --timestamp=none --options runtime \
    --entitlements "$ENTITLEMENTS" \
    -s "$SIGN_ID" "$RES/llama-server"
fi

# ── 4. Sign the app bundle last, with entitlements + hardened runtime ────────
echo "[4/6] Signing GrammarBar.app…"
codesign --force --timestamp=none --options runtime \
  --entitlements "$ENTITLEMENTS" \
  -s "$SIGN_ID" "$APP"

# ── 5. Verify signature + structure ──────────────────────────────────────────
echo "[5/6] Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"

# ── 6. Package as a zip that preserves symlinks/permissions ──────────────────
echo "[6/6] Packaging…"
STAGE="$DIST_DIR/GrammarBar"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"

cat > "$STAGE/OPEN-ME.txt" <<'EOF'
GrammarBar — how to open (unsigned / not notarized build)
==========================================================

Because this build is not notarized by Apple, macOS Gatekeeper will block it
on first launch. To open it:

1. Drag GrammarBar.app into your /Applications folder.

2. Remove the quarantine flag (recommended — easiest). Open Terminal and run:

       xattr -dr com.apple.quarantine /Applications/GrammarBar.app

   ...then double-click the app.

   (Alternative: double-click the app, let it get blocked, then go to
    System Settings > Privacy & Security, scroll down, and click
    "Open Anyway".)

3. GrammarBar lives in the menu bar (top-right). Click its icon > Settings >
   Permissions and grant BOTH:
       - Accessibility
       - Input Monitoring
   Then quit and relaunch the app.

4. Click the menu-bar icon > Settings > Models, download a model
   (Gemma 2 2B recommended), and click "Use".

Requirements: Apple Silicon Mac (arm64), macOS 13.0 or later.
Everything runs locally; no text leaves your machine.
EOF

ZIP="$DIST_DIR/GrammarBar-$VERSION.zip"
rm -f "$ZIP"
( cd "$STAGE/.." && ditto -c -k --sequesterRsrc --keepParent "GrammarBar" "$ZIP" )

echo ""
echo "=== Done ==="
echo "Version: $VERSION"
echo "App:     $APP"
echo "Zip:     $ZIP"
echo ""
echo "Share the zip. Recipients must follow OPEN-ME.txt to bypass"
echo "Gatekeeper (this build is NOT notarized)."

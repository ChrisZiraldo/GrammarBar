#!/usr/bin/env bash
# setup.sh — one-time setup for GrammarBar
# Run from the repo root: bash scripts/setup.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES_DIR="$REPO_ROOT/Sources/GrammarBar/Resources"
BINARY_DEST="$RESOURCES_DIR/llama-server"

echo "=== GrammarBar Setup ==="
echo ""

# ── 1. Homebrew ──────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
  echo "[ERROR] Homebrew is required. Install from https://brew.sh then re-run."
  exit 1
fi
echo "[1/4] Homebrew found: $(brew --version | head -1)"

# ── 2. XcodeGen ──────────────────────────────────────────────────────────────
if ! command -v xcodegen &>/dev/null; then
  echo "[2/4] Installing XcodeGen…"
  brew install xcodegen
else
  echo "[2/4] XcodeGen found: $(xcodegen version 2>/dev/null || echo 'ok')"
fi

# ── 3. llama-server binary + dependencies ────────────────────────────────────
# Homebrew's llama-server is dynamically linked against several dylibs
# (libllama, libggml, libmtmd, libomp, openssl, etc.) that live outside
# the binary's own directory. To make the app bundle self-contained (so it
# runs without Homebrew's exact layout present), we use dylibbundler to
# recursively copy the full dependency closure next to the binary and
# rewrite all install paths to @loader_path (i.e. "next to the binary").
echo "[3/4] Fetching llama-server binary and bundling its dependencies…"
mkdir -p "$RESOURCES_DIR"

if ! command -v llama-server &>/dev/null; then
  echo "      llama.cpp not found in PATH — installing via Homebrew…"
  brew install llama.cpp
fi

if ! command -v dylibbundler &>/dev/null; then
  echo "      dylibbundler not found — installing via Homebrew…"
  brew install dylibbundler
fi

LLAMA_BIN="$(which llama-server 2>/dev/null || true)"
if [ -z "$LLAMA_BIN" ]; then
  # Homebrew cellar fallback
  LLAMA_BIN="$(brew --prefix llama.cpp 2>/dev/null)/bin/llama-server"
fi

if [ ! -f "$LLAMA_BIN" ]; then
  echo "[ERROR] Could not find llama-server after installing llama.cpp."
  echo "        Locate it manually and copy to: $BINARY_DEST"
  exit 1
fi

STAGING_DIR="$(mktemp -d)"
LIBS_DIR="$STAGING_DIR/libs"
mkdir -p "$LIBS_DIR"
cp "$LLAMA_BIN" "$STAGING_DIR/llama-server"
chmod +w "$STAGING_DIR/llama-server"

BREW_PREFIX="$(brew --prefix)"
dylibbundler -cd -of -b \
  -x "$STAGING_DIR/llama-server" \
  -d "$LIBS_DIR" \
  -p "@loader_path/" \
  -s "$BREW_PREFIX/lib" \
  -s "$BREW_PREFIX/opt/ggml/lib" \
  -s "$BREW_PREFIX/opt/openssl@3/lib" \
  -s "$BREW_PREFIX/opt/libomp/lib" \
  < /dev/null

rm -f "$RESOURCES_DIR"/llama-server
find "$RESOURCES_DIR" -maxdepth 1 -name "*.dylib" -delete
cp "$STAGING_DIR/llama-server" "$BINARY_DEST"
cp "$LIBS_DIR"/*.dylib "$RESOURCES_DIR/"
chmod +x "$BINARY_DEST"
rm -rf "$STAGING_DIR"

echo "      Bundled: $LLAMA_BIN + $(ls "$RESOURCES_DIR"/*.dylib | wc -l | tr -d ' ') dylibs → $RESOURCES_DIR"

# Sanity check: the binary must run standalone from its final location
if ! "$BINARY_DEST" --version &>/dev/null; then
  echo "[ERROR] Bundled llama-server failed to run standalone. Check dylib bundling above."
  exit 1
fi
echo "      Verified: llama-server runs standalone from Resources/"

# ── 4. Generate Xcode project ────────────────────────────────────────────────
echo "[4/4] Generating Xcode project…"
cd "$REPO_ROOT"
xcodegen generate

echo ""
echo "=== Setup complete! ==="
echo ""
echo "Next steps:"
echo "  1. Open GrammarBar.xcodeproj in Xcode"
echo "  2. Select your Development Team in the target's Signing settings"
echo "  3. Build & Run (⌘R)"
echo "  4. On first launch, open GrammarBar → Settings → Permissions"
echo "     and grant Accessibility + Input Monitoring"
echo "  5. Go to Settings → Models and download a model"
echo ""
echo "Models are stored in ~/Library/Application Support/GrammarBar/models/"

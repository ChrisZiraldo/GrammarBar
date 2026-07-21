# GrammarBar

A macOS menu-bar app that watches your focused text field, streams a grammar and spelling correction through a local LLM (via llama.cpp), and shows the suggestion in a floating speech-bubble anchored below the menu-bar icon. Pressing **Enter** sends your original text untouched. Pressing **⌃Return (Ctrl+Return)** or clicking **Accept** overwrites the field with the corrected version.

Everything runs locally — no text leaves your machine.

## Requirements

- macOS 13.0+ (Ventura or later)
- Apple Silicon Mac (arm64) — Intel is not supported by the bundled llama-server binary
- Xcode 15+
- Homebrew

## Quick start

```bash
# Clone and set up
git clone <repo>
cd <repo>
bash scripts/setup.sh
```

The script:
1. Installs XcodeGen (via Homebrew) if not already present
2. Installs `llama.cpp` and `dylibbundler` (via Homebrew), then bundles `llama-server` and its full dependency closure (dylibs) into `Sources/GrammarBar/Resources/` so the app doesn't depend on Homebrew's exact layout at runtime
3. Runs `xcodegen generate` to produce `GrammarBar.xcodeproj` (target: `GrammarBar`)

Then:
1. Open `GrammarBar.xcodeproj` in Xcode
2. Set your **Development Team** in the target's Signing & Capabilities tab
3. Build and Run (⌘R)

## First-launch setup

1. **Grant permissions** — The app adds a menu-bar icon. Click it → **Settings → Permissions**:
   - **Accessibility**: lets GrammarBar read text from the focused field and write corrections back
   - **Input Monitoring**: lets GrammarBar detect typing pauses
   - After granting both, quit and relaunch the app

2. **Download a model** — Click the menu-bar icon → **Settings → Models** and click **Download** next to a model. Recommended starting point: **Gemma 2 2B** (~1.7 GB, fast, high quality).

3. **Select the model** — Click **Use** next to the downloaded model. The server starts automatically.

## Using GrammarBar

- Type normally in any supported text field.
- After you pause (~0.4 seconds by default; adjustable in Settings → General), a floating overlay appears below the menu-bar icon showing the corrected text streaming in.
- **Press Return, or keep typing** — sends/inserts your original text as usual and dismisses the overlay.
- **Press ⌃Return (Ctrl+Return), or click Accept** in the overlay — replaces your field's text with the correction.
- **Click ✕** — dismisses the overlay without accepting.
- Switching to a different app hides the overlay automatically, but clicking into another field in the *same* app does not — it stays put until you type, press Return, or click ✕.

## Model catalog

| Model | Size | Speed | Quality |
|---|---|---|---|
| Qwen2.5-1.5B Instruct | ~1.0 GB | Fastest | Good |
| **Gemma 2 2B Instruct** | ~1.7 GB | Fast | **Recommended** |
| Qwen2.5-3B Instruct | ~1.9 GB | Moderate | Better |
| Llama 3.2 3B Instruct | ~2.0 GB | Moderate | Better |
| Phi-3.5 Mini Instruct | ~2.4 GB | Slower | Best |

Models are stored in `~/Library/Application Support/GrammarBar/models/`.

## Settings

- **General → Enable/Disable**: toggle the correction globally, or use the menu-bar menu.
- **General → Correction delay**: how long after you stop typing before a correction is requested (0.2–2.0 s).
- **General → App allow-list**: paste one bundle ID per line to restrict GrammarBar to specific apps. Leave empty to enable everywhere.
- **Models**: download, switch, or delete models; shows the llama-server status.
- **Permissions**: live permission status with quick-links to System Settings panes.

## Supported app types

**Every app, including Chrome** — Mail, Notes, Slack, Messages, TextEdit, Terminal, Chrome, and other Chromium-based browsers — is supported out of the box via the Accessibility API, no extra setup needed beyond granting permissions above. Chromium-based apps (Chrome, Cursor, VS Code, Slack, etc.) don't expose their accessibility tree by default; GrammarBar detects this and force-enables it (`AXManualAccessibility`) on the frontmost app automatically.

## Architecture overview

```
EventTapController (CGEventTap, defaultTap)
        │ keystroke detected
        ▼
FocusTracker (AXUIElement) ──── reads text value + bounds
        │
        ▼
CorrectionEngine (Debouncer ~400ms)
        │ sends text to
        ▼
LlamaClient (streaming POST /v1/chat/completions)
        │
        ▼
llama-server subprocess (bundled binary)
        │
        ▼ tokens stream back
OverlayPanel (speech bubble, anchored below the menu-bar icon)
        │ Ctrl+Enter to accept
        ▼
TextWriter (select-all + paste replace)
```

## Distribution

For personal use, run unsigned from Xcode. For distribution:

1. Set your Developer ID in Xcode → Signing & Capabilities (for the `GrammarBar` target).
2. Archive → Distribute → Developer ID.
3. `llama-server` and its bundled dylibs (already ad-hoc signed by `dylibbundler` during setup) must be **re-signed** with your Developer ID before archiving:
   ```bash
   codesign --force --sign "Developer ID Application: Your Name (TEAMID)" \
     Sources/GrammarBar/Resources/llama-server \
     Sources/GrammarBar/Resources/*.dylib
   ```
4. Submit for Apple notarization after archiving.

## Privacy

- All text processing happens on-device via the local llama-server.
- No telemetry, no network calls except the HuggingFace model download.
- The HuggingFace download is a direct HTTPS fetch; no account required for public models.
- GrammarBar never stores or logs your typed text.
- Secure/password text fields are always skipped — GrammarBar never reads their contents.

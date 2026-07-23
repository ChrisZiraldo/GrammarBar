# AGENTS.md

Guidance for AI coding agents (and humans) working on **GrammarBar** — a macOS menu-bar app that proofreads/rephrases the text in your focused field using a local llama.cpp server.

## Overview

- **Type:** macOS menu-bar agent app (`LSUIElement`, no Dock icon)
- **Language:** Swift 5.9, AppKit + SwiftUI
- **Bundle ID:** `com.grammarbar.app`
- **Deployment target:** macOS 13.0 (Ventura)
- **Architecture:** Apple Silicon (arm64) only — the bundled `llama-server` is arm64
- **Project generation:** [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml` → `GrammarBar.xcodeproj`)
- **No SPM / no third-party Swift packages** — only Apple frameworks plus a bundled `llama-server` binary

## Prerequisites

- macOS on Apple Silicon
- Xcode 15.x with command-line tools
- [Homebrew](https://brew.sh)

## First-time setup

Run the setup script once from the repo root. It installs the Homebrew tooling, bundles the
`llama-server` binary + its dylibs into `Sources/GrammarBar/Resources/`, and generates the
Xcode project:

```bash
bash scripts/setup.sh
```

This does the following:

1. Installs `xcodegen`, `llama.cpp`, and `dylibbundler` via Homebrew (if missing)
2. Copies `llama-server` and its full dylib closure into `Sources/GrammarBar/Resources/`
   (rewritten with `@loader_path/` so the app is self-contained)
3. Verifies the bundled binary runs standalone
4. Runs `xcodegen generate`

> **Important:** The app cannot start its LLM backend without the bundled `llama-server`.
> If you skip setup, the build will succeed but the app won't function.

## Building

Signing is already configured in Xcode (automatic signing). **Do not pass manual
`CODE_SIGN_IDENTITY` / `CODE_SIGN_STYLE` overrides** — let the project settings take effect:

```bash
pkill -x GrammarBar 2>/dev/null   # avoid llama-server port 8765 conflicts
xcodebuild \
  -project GrammarBar.xcodeproj \
  -scheme GrammarBar \
  -destination "platform=macOS" \
  -configuration Debug \
  build
```

Or just open it in Xcode:

```bash
open GrammarBar.xcodeproj
```

## Running

Launch the freshly built binary from its exact DerivedData path (avoid globbing
`GrammarBar-*` — stale DerivedData folders exist and a glob may launch the wrong binary):

```bash
pkill -x GrammarBar 2>/dev/null; sleep 1
BUILT=$(xcodebuild \
  -project GrammarBar.xcodeproj \
  -scheme GrammarBar \
  -destination "platform=macOS" \
  -configuration Debug \
  -showBuildSettings 2>/dev/null | grep "BUILT_PRODUCTS_DIR" | head -1 | awk '{print $3}')
open "$BUILT/GrammarBar.app"
```

### Required permissions

GrammarBar needs two macOS privacy permissions to function:

- **Accessibility** — read/write the focused text field via the Accessibility API
- **Input Monitoring** — system-wide keystroke tap (`CGEventTap`) to detect typing pauses

Grant both in **System Settings → Privacy & Security**:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

### Models

Models are **not bundled**. On first launch, pick a model in Settings → Models; it is
downloaded (GGUF from HuggingFace, catalog in `Resources/models.json`) to
`~/Library/Application Support/GrammarBar/models/`. The app then spawns `llama-server`
on `127.0.0.1:8765`.

## Common gotchas

- **Re-run `xcodegen generate` after adding/removing/renaming Swift files.** The project is
  generated from `project.yml`; there is no manual project editing.
- **`GrammarBar.xcodeproj` is gitignored** — regenerate it, never commit it.
- **`llama-server` and `*.dylib` in `Resources/` are gitignored** — they come from `setup.sh`,
  don't commit them.
- **Permissions can reset after `xcodegen generate`.** Regenerating the project can produce a
  new DerivedData path; macOS TCC permissions are keyed to the binary path, so you may need to
  re-grant Accessibility + Input Monitoring once.
- **Kill any running instance before rebuilding** (`pkill -x GrammarBar`) to avoid port 8765
  conflicts with an orphaned `llama-server`.
- **Not sandboxed** — `CGEventTap` and `AXUIElement` require non-sandboxed execution. Hardened
  Runtime is enabled.

## Distribution

To produce an ad-hoc–signed, zipped distributable (used by CI on `VERSION` changes):

```bash
bash scripts/dist.sh
```

This builds Release, stamps the version from the `VERSION` file, signs the dylibs +
`llama-server` + app bundle (ad-hoc), and packages `dist/GrammarBar-<version>.zip`. A release
is cut automatically by `.github/workflows/release.yml` when `VERSION` changes on `main`.

## Project layout

```
project.yml                     XcodeGen spec (source of truth for the Xcode project)
VERSION                         Single source of truth for the app version
scripts/setup.sh                One-time dev setup (deps + llama-server bundling + xcodegen)
scripts/dist.sh                 Release build + ad-hoc signing + zip packaging
Sources/GrammarBar/
  main.swift                    AppKit bootstrap (creates AppDelegate, runs NSApplication)
  App/
    AppDelegate.swift           Orchestrates event tap, focus, correction, overlay, server
    StatusBarController.swift    Menu-bar icon, menu, settings window, server status
    LoginItem.swift             Launch-at-login via SMAppService
  Capture/
    EventTapController.swift    System-wide CGEventTap for keystrokes / Return handling
    FocusTracker.swift          Reads focused text field via Accessibility API
    TextWriter.swift            Writes corrections via select-all + paste
  Correction/
    CorrectionEngine.swift      Debounced correction pipeline; streams LLM output
    Debouncer.swift             Delay before firing correction after a typing pause
    CorrectionMode.swift        Writing-style enum used in LLM system prompts
    Readability.swift           Local Flesch reading-ease / text stats (no LLM)
  Llama/
    LlamaServerManager.swift    Spawns/manages the bundled llama-server subprocess
    LlamaClient.swift           HTTP streaming client for /v1/chat/completions
    ModelManager.swift          Downloads GGUF models to Application Support
    ModelCatalog.swift          Loads model metadata from bundled models.json
  Overlay/
    OverlayPanel.swift          Floating speech-bubble NSPanel + SwiftUI content
  Settings/
    SettingsStore.swift         UserDefaults-backed settings
    SettingsView.swift          SwiftUI settings window (Models / General / Permissions)
    InstalledAppsScanner.swift   Scans installed apps for the per-app block list
  Resources/
    Info.plist                  Bundle metadata + usage descriptions + LSUIElement
    GrammarBar.entitlements     Hardened Runtime entitlements (no sandbox)
    models.json                 Catalog of downloadable GGUF models
    llama-server, *.dylib       Bundled by setup.sh (gitignored)
```

## Runtime architecture

```
EventTapController → FocusTracker → CorrectionEngine (Debouncer)
    → LlamaClient (HTTP streaming) → llama-server subprocess (127.0.0.1:8765)
    → OverlayPanel → TextWriter (on Accept)
```

All inference is local. The only outbound network calls are model downloads from HuggingFace.

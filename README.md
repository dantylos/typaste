# LocalType

Native macOS menu-bar assistant for local text autocompletion powered by Apple Silicon Metal GPU and MLX.

LocalType observes text around the caret in supported macOS applications via Accessibility APIs, runs local on-device inference using a 4-bit quantized language model (`Qwen3-1.7B-Base`), and inserts confirmed completions alongside the cursor.

---

## Features

- **100% Local & Private:** Runs entirely offline on Apple Silicon via Metal and MLX Swift LM. No network requests.
- **Smart Completion:**
  - Mid-word completion (completes the current word without duplicating typed prefixes or adding erroneous spaces).
  - Multi-word suggestion continuation (up to 4 words).
- **Non-intrusive Overlay:** Floating HUD (`NSPanel`) anchored next to the text caret.
- **Keyboard Shortcuts:**
  - `⇥ Tab`: Accept the next word (or finish current word).
  - `⇧⇥ Shift+Tab`: Accept the entire suggestion.
  - `⎋ Esc`: Dismiss the current suggestion.
- **Safe Fallbacks:** Two-tier text insertion (Direct `kAXSelectedTextAttribute` with clipboard-safe `Cmd+V` fallback).

---

## Requirements

- **OS:** macOS 14.0+ (Sonoma or newer)
- **Hardware:** Apple Silicon (M1/M2/M3/M4/M5)
- **Toolchain:** Xcode 16+ / Swift 6.2
- **Permissions:**
  - **Accessibility** (`System Settings → Privacy & Security → Accessibility`): required for reading text field context and caret coordinates via `AXUIElement`.
  - **Input Monitoring** (`System Settings → Privacy & Security → Input Monitoring`): required for intercepting `Tab`, `Shift+Tab`, and `Esc` via `CGEventTap`.

---

## Project Structure

```text
├── Models/
│   └── Qwen3-1.7B-Base-mlx-4Bit/     # Local model weights and tokenizer config
├── Sources/
│   ├── LocalType/
│   │   ├── Accessibility/            # AXAdapter (AXUIElement, caret calculation)
│   │   ├── Coordinator/              # AssistantCoordinator (state & debounce)
│   │   ├── EventTap/                 # EventTapManager (CGEventTap callback)
│   │   ├── Model/                    # InferenceService & SuggestionText logic
│   │   ├── UI/                       # OverlayController (HUD NSPanel)
│   │   └── main.swift                # App entry point & NSStatusBar menu
│   ├── ModelSpike/                   # CLI verification tool for model loading
│   └── AXProbe/                      # Accessibility exploration tool
├── Tests/
│   └── LocalTypeTests/               # Unit & integration test suite (20 tests)
├── Package.swift
└── SPEC.md                           # Detailed architecture specification
```

---

## Build & Run

### 1. Build

Build the project using `xcodebuild`:

```bash
xcodebuild -scheme LocalType -destination "platform=macOS,arch=arm64" -derivedDataPath DerivedData -skipPackagePluginValidation build
```

> **Note:** Use `xcodebuild` rather than bare `swift build`, as `mlx-swift` requires Xcode's Metal shader compiler toolchain.

### 2. Run Tests

Execute unit tests and on-device Metal integration checks:

```bash
xcodebuild -scheme LocalType -destination "platform=macOS,arch=arm64" -derivedDataPath DerivedData -skipPackagePluginValidation test
```

### 3. Run Application

```bash
./DerivedData/Build/Products/Debug/LocalType
```

Once launched, the app appears as `✦ LocalType` in the macOS menu bar. Ensure Accessibility and Input Monitoring permissions are granted to the executing terminal or application bundle.

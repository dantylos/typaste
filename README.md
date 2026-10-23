# LocalType

Native macOS menu-bar assistant for local text autocompletion powered by Apple Silicon Metal GPU and MLX.

LocalType observes text around the caret in supported macOS applications via Accessibility APIs, learns your personal phrases in a local SQLite database (`PersonalMemoryStore`), runs local on-device inference using **`Qwen3-1.7B-Instruct` (4-bit)** with `<think>` disabled (supporting Russian & English), and inserts confirmed completions alongside the cursor.

---

## Features

- **100% Local & Private:** Runs entirely offline on Apple Silicon via Metal and MLX Swift LM. No network requests.
- **Conversational Model (`Qwen3-1.7B-Instruct` 4-bit, No-Think):**
  - Uses `mlx-community/Qwen3-1.7B-4bit` with `<think>\n\n</think>` prefill disabled for fast, context-aware conversational completions in **Russian** and **English**.
- **Personal Memory Store (SQLite3):**
  - Automatically learns phrases confirmed via `Tab`/`Shift+Tab` as well as completed sentences typed on screen (`~/Library/Application Support/LocalType/personal_memory.sqlite3`).
  - **Indexed Prefix Lookup:** Suggests completions for your frequent phrases without waiting for GPU generation.
  - **Dynamic Style Few-Shot Prompting:** Injects your top language-matched and app-prioritized (`bundleID`) phrases into the `Qwen3-1.7B-Instruct` system prompt so completions match your personal vocabulary.
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
- **Toolchain:** Xcode with Swift 6.2 or newer and the Metal toolchain installed
- **Permissions:**
  - **Accessibility** (`System Settings → Privacy & Security → Accessibility`): required for reading text field context and caret coordinates via `AXUIElement`.
  - **Input Monitoring** (`System Settings → Privacy & Security → Input Monitoring`): required for intercepting `Tab`, `Shift+Tab`, and `Esc` via `CGEventTap`.

---

## Project Structure

```text
├── Models/
│   └── Qwen3-1.7B-mlx-4Bit/          # Qwen3-1.7B-Instruct 4-bit weights and tokenizer config
├── Sources/
│   ├── LocalType/
│   │   ├── Accessibility/            # AXAdapter (AXUIElement, caret calculation)
│   │   ├── Coordinator/              # AssistantCoordinator (state, debounce & memory integration)
│   │   ├── EventTap/                 # EventTapManager (CGEventTap callback)
│   │   ├── Model/                    # InferenceService, PersonalMemoryStore (SQLite3) & SuggestionText
│   │   ├── UI/                       # OverlayController (HUD NSPanel)
│   │   └── main.swift                # App entry point & NSStatusBar menu
│   ├── ModelSupport/                 # Shared tokenizer bridge and loader
│   ├── ModelSpike/                   # CLI verification tool for model loading
│   └── AXProbe/                      # Accessibility exploration tool
├── Tests/
│   └── LocalTypeTests/               # Unit & integration test suite (XCTest and Swift Testing)
├── Package.swift
└── SPEC.md                           # Detailed architecture specification
```

---

## Build & Run

### 1. Download model weights

The tokenizer and configuration are tracked in Git; the large weights are not.
Install the [Hugging Face CLI](https://huggingface.co/docs/huggingface_hub/guides/cli), then run from the repository root:

```bash
hf download mlx-community/Qwen3-1.7B-4bit model.safetensors --local-dir Models/Qwen3-1.7B-mlx-4Bit
```

The [model repository](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/tree/main) supplies the weights. This setup step requires network access; inference runs offline.
To use a complete model directory elsewhere, set `LOCALTYPE_MODEL_DIR` to its absolute path.

### 2. Build

Build the project using `xcodebuild`:

```bash
xcodebuild -scheme LocalType -destination "platform=macOS,arch=arm64" -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/LocalTypeCLI" -skipPackagePluginValidation build
```

> **Note:** Use `xcodebuild` rather than bare `swift build`, as `mlx-swift` requires Xcode's Metal shader compiler toolchain.

### 3. Run Tests

Execute unit tests and on-device Metal integration checks:

```bash
xcodebuild -scheme LocalType -destination "platform=macOS,arch=arm64" -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/LocalTypeCLI" -skipPackagePluginValidation test
```

### 4. Run Application

```bash
"$HOME/Library/Developer/Xcode/DerivedData/LocalTypeCLI/Build/Products/Debug/LocalType"
```

Once launched, the app appears as `✦ LocalType` in the macOS menu bar. Ensure Accessibility and Input Monitoring permissions are granted to the executing terminal or application bundle.

## Build output and diagnostics

Keep build output outside the repository using the commands above. Xcode normally uses its own Derived Data directory. Existing `DerivedData/` and `.build/` folders are ignored caches, not duplicate source code.

A warning that the same Metal toolchain is "already registered" comes from the Xcode installation when a bundled toolchain and a downloaded toolchain share an identifier. It is separate from Swift source diagnostics. Manage downloaded components in Xcode Settings rather than removing files inside Xcode.app.

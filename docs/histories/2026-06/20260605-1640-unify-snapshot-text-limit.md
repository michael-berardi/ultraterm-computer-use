## [2026-06-05 16:40] | Task: Unify snapshot text limit

### Execution Context
* **Agent ID**: `Codex`
* **Base Model**: `GPT-5`
* **Runtime**: `Codex desktop`

### User Query
> Unify the default snapshot text truncation across macOS, Linux, and Windows to 500 characters, append `...` when truncated, and add an explicit full-text parameter for `get_app_state` and `snapshot`.

### Changes Overview
**Scope:** macOS Swift renderer, Linux runtime, Windows runtime, CLI/tool schema, tests.

**Key Actions:**
- Added optional `show_full_text` / `--show-full-text` support for full accessibility text output.
- Changed macOS snapshot text truncation from 160 to the shared 500 character default.
- Unified Linux and Windows truncation markers so truncated text appends `...`.
- Kept node count, tree depth, image, and action-result refresh protections unchanged.

### Design Intent (Why)
Default truncation protects snapshot size and preserves upstream-compatible behavior, while the explicit full-text option lets users inspect long semantic text such as chat messages without adding URL- or page-specific rendering rules.

### Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/OpenComputerUseCLI.swift`
- `apps/OpenComputerUseLinux/runtime.py`
- `apps/OpenComputerUseWindows/runtime.ps1`

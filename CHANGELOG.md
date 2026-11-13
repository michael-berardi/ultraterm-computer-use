# Changelog

## 0.8.0

This release brings in the upstream project's work through 2026-11-13 and adds our own changes. The main change is that the runtime now works in the background by default. See `docs/background-operation.md` and `docs/state-id.md`.

**Changed behaviour**

- macOS: a hidden app, a minimized window, or an app with no open window is no longer brought forward. When its window cannot be read where it is, `get_app_state` fails with `The app has no window that can be read in the background` and changes nothing. Set `ULTRATERM_COMPUTER_USE_ALLOW_FOREGROUND=1` to get the old recovery.
- Linux: coordinate clicks, `drag`, `click_method=global`, and keys or `scroll` for a window that is not active are refused unless `ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` is set. Before, `auto` fell back to mouse synthesis.
- `call --calls` waits 0.2 seconds between successful steps. It was 1 second. `--sleep` still sets it.
- The visual cursor move takes at most 0.18 seconds by default. It was about 1.43 seconds per click.
- Locked Use components are bundled only when the build sets `ULTRATERM_COMPUTER_USE_INCLUDE_LOCKED_USE=1`.

**Background by default**

- macOS never activates an app, raises or unminimizes a window, or unhides an app unless `ULTRATERM_COMPUTER_USE_ALLOW_FOREGROUND=1`. This covers snapshot recovery, the accessibility click fallback, the `Raise` secondary action, and launching an app (it is launched without activation).
- The real pointer is still behind `ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1`.
- The visual cursor is a drawn overlay, never the real pointer. `ULTRATERM_COMPUTER_USE_VISUAL_CURSOR=0` turns it off.

**Stale-state protection**

- Every state and every action result carries a `state_id`, on macOS, Linux and Windows.
- `click`, `perform_secondary_action`, `scroll`, `drag`, `type_text`, `press_key` and `set_value` take an optional `state_id`. On macOS `select_text` takes it too.
- If the app was captured again since, the action is refused with `stale_state` before anything is sent.

**Reliability fixes**

- An uncertain click is not retried another way.
- The mouse button is released if a drag or click fails partway.
- `set_value` reads the value back and reports a mismatch. A disabled control is not pressed.
- The element is checked against its recorded identity before the runtime acts on it.
- Password field values are never returned on any platform.

**Tools and observation**

- macOS adds `query` and `select_text`.
- `get_app_state` takes `include_ax` and `include_screenshot` on all three platforms.
- A sheet can be the root of the snapshot.
- Covered windows and windows on other Spaces can be read, through occlusion keep-alive and hardware window capture.
- Accessibility attributes are read in batches.
- Screenshot format and size are set with the `config` command. JPG and WebP are available.
- JavaScript mode: `js`, `repl` and `capabilities`.

**Speed**

- The visual cursor move is bounded to 0.18 seconds (`ULTRATERM_COMPUTER_USE_VISUAL_CURSOR_MOVE_DURATION` sets it in seconds, 0 to 2).
- The idle cursor animation runs at 20 Hz instead of 60 Hz.
- The sequence gap is 0.2 seconds.

**Linux**

- A click on a field with no click action focuses it through accessibility.
- A plain Return on a focused GTK 3 text field runs its activate action. The activate action of a GTK 3 text field is not treated as a click.
- `type_text` inserts at the caret in the focused editable field only. Whitespace is kept as written.
- A read-only field is refused by `set_value`.
- An unknown key modifier is rejected. Locked modifiers are always released.
- The MCP server no longer loops forever on a malformed line.
- Session discovery does not copy the accessibility bus address from other processes, so a sandbox socket is not picked up.

**Windows**

- The MCP server no longer loops forever on a malformed line.
- `type_text` sends the literal text.
- The standard output and standard error of the PowerShell bridge are kept apart.
- `press_key` describes what it does accurately: window messages, no key combinations unless `key_method=global`.
- Covered windows are captured with `PrintWindow`.
- A hung window fails fast before anything is sent. An elevated app is refused.
- UWP and secondary windows are resolved to the right window.
- The bridge starts without a console window flash.
- An element that changed, or cannot be matched to one element, is refused.

**Packaging and docs**

- npm package metadata is stamped with the real repository at release.
- The docs check fails on non-English text, dead paths and workflow mentions.
- The CI script runs every suite: docs and hygiene checks, script syntax checks, Linux Python tests, Go tests for both runtimes, Node tests, and on macOS `swift build` and `swift test`.
- `THIRD_PARTY_NOTICES.md` includes the libwebp notice. WebP encoding links libwebp 1.6.0.
- New pages: `docs/background-operation.md` and `docs/state-id.md`.

**Tested**

- macOS: unit tests and the fixture smoke suites, on macOS 27.
- Linux: unit tests, and the GTK 3 and AT-SPI smoke test in an Ubuntu 24.04 container under Xvfb.
- Windows: Go unit tests only. The Windows runtime was not run on a Windows machine.

## 0.7.3

Fixed: the Windows installer (`install.ps1`) read the user Path with entries such as `%USERPROFILE%\AppData\Local\Microsoft\WindowsApps` already expanded and wrote it back as a plain string, so those entries were permanently hard-coded and the value lost its expandable type. It now reads the raw value from `HKCU\Environment`, treats the bin folder as present when an entry matches it literally or after expansion, and writes the Path back with its existing registry type (expandable when it did not exist). The Windows installer was tested under PowerShell 7 on Linux and not yet on a Windows machine.

## 0.7.2

Fixed: README: real owner in install, badge and clone links; neutrality test allows the repo's own URL.

## 0.7.1

Fixed: an `install.sh`, `install.ps1` or `install-ultraterm-computer-use.sh` fetched from the main branch (an unstamped source copy) downloaded its tarball and checksums from a placeholder GitHub account that anyone could register. These scripts now refuse to run unless they are the stamped copies attached to a GitHub release (`UTCU_RELEASE_BASE` still works for tests); the stamp cannot rewrite the guard. Also fixed: `install.sh` could nest a new release inside an existing release folder with the same name (it now creates a unique folder), and under `curl | sh` the macOS message now prints the correct `sh -s -- --npm` command. The signed release build now finishes with `finalize-release.sh --require-all` once the npm tarball exists, so a partial `SHA256SUMS` cannot be uploaded. The Windows installer was tested under PowerShell 7 on Linux and not yet on a Windows machine.

## 0.7.0

Added one-step release installers: `scripts/install.sh` for Linux (on macOS it points at the signed .pkg and offers the npm route with `--npm`) and `scripts/install.ps1` for Windows. Both verify the release tarball's SHA-256, use Node 18+ from the system or fetch the official Node 22 LTS into the tool's own folder, install under one home folder, write a command shim, and finish with the CLI version check. Release packaging now ships `install.sh` and `install.ps1` as assets covered by `SHA256SUMS`. Added `scripts/test-install.sh` covering local, Linux container, and PowerShell 7 runs.

The release scripts stamp the real GitHub owner/repo into the installers (`scripts/stamp-installers.sh`) and one final step (`scripts/finalize-release.sh`) writes a single combined `SHA256SUMS` and manifest covering the .pkg, .zip, .tgz and installers, in either build order. The Windows installer runs `npm.cmd` (not the policy-blocked `npm.ps1`), uses a `%~dp0`-relative or OEM-encoded `.cmd` shim, never overwrites a command it did not write, keeps the live release when re-run, and both installers always run the absolute `node`. The Windows installer was tested under PowerShell 7 on Linux and not yet on a Windows machine.

## 0.6.1

The published 0.6.0 release had no assets. This release restores signed assets using the existing shipped app identity, preserving macOS permissions and update compatibility. Release identity is supplied through environment configuration rather than embedded in shipped files.

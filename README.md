# UltraTerm Computer Use

<p align="center">
  <img src="plugins/ultraterm-computer-use/assets/ultraterm-computer-use.svg" alt="UltraTerm Computer Use" width="180" />
</p>

<p align="center">
  <strong>Local desktop automation for MCP-capable agents.</strong><br />
  <a href="#install">Install</a> ·
  <a href="#configure-an-mcp-client">MCP setup</a> ·
  <a href="#commands">CLI</a> ·
  <a href="SECURITY.md">Security</a>
</p>

<p align="center">
  <a href="https://github.com/michael-berardi/ultraterm-computer-use/releases/latest"><img src="https://img.shields.io/github/v/release/michael-berardi/ultraterm-computer-use?label=release" alt="Latest release" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/michael-berardi/ultraterm-computer-use" alt="MIT License" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey" alt="macOS, Linux and Windows" />
  <img src="https://img.shields.io/badge/MCP-9%20to%2011%20tools-8A2BE2" alt="Nine to eleven MCP tools" />
</p>

UltraTerm Computer Use lets an agent operate desktop apps on macOS, Linux and Windows while you keep using the computer. It is MIT licensed, runs locally, and works with any MCP-capable agent. Screenshots, accessibility trees and input never leave the machine.

## It stays out of your way

An agent that takes over the screen is an agent you have to sit and watch. By default this runtime:

- never activates an app, raises a window, unminimizes one or unhides an app. When a window cannot be read where it is, the error says so and names the switch that allows bringing it forward;
- never moves your pointer. Clicks, keys, scrolls and drags are delivered to the target app or window directly;
- reads and drives windows that are covered or on another Space (macOS);
- launches a missing app without giving it the keyboard;
- never returns the contents of a password field.

Anything that would break those rules is refused with an error naming the switch that enables it: `ULTRATERM_COMPUTER_USE_ALLOW_FOREGROUND=1` to bring apps forward (macOS), `ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` for real-pointer input. Linux has no per-app input channel, so there coordinate clicks, drags, and keys or scrolling for a window that is not active need the second switch; accessibility actions work without it. The full table is in [`docs/background-operation.md`](./docs/background-operation.md).

## It does not act on a stale screen

Every state and action result carries a `state_id`. Pass it with the next action: if the app's state was captured again in between, the action is refused with `stale_state` before anything is sent. Element indexes are also checked against what the snapshot showed (role, name, identifier), disabled controls are not pressed, an uncertain click is not retried a second way, and `set_value` reads the value back before reporting success.

## Supported platforms

| Platform | Requirements |
| --- | --- |
| macOS 14+ | Logged-in desktop; Accessibility and Screen Recording permissions |
| Linux | Logged-in graphical desktop; AT-SPI2 and D-Bus accessibility |
| Windows | Logged-in desktop; UI Automation |

All three runtimes expose the same nine MCP tools: `list_apps`, `get_app_state`, `click`, `perform_secondary_action`, `scroll`, `drag`, `type_text`, `press_key`, and `set_value`. macOS adds `query`, which finds controls by text or role without a screenshot or a full tree, and `select_text`. `get_app_state` takes `include_ax` and `include_screenshot`, so an agent pays only for what it reads.

## Install

One step, every platform. Each installer downloads the latest release, verifies its SHA-256 before installing anything, and finishes by running the tool's own version check.

macOS and Linux:

```bash
curl -fsSL https://github.com/michael-berardi/ultraterm-computer-use/releases/latest/download/install.sh | sh
```

Windows (PowerShell 5.1 or PowerShell 7):

```powershell
irm https://github.com/michael-berardi/ultraterm-computer-use/releases/latest/download/install.ps1 | iex
```

What the one-step installers do:

- Linux: install the release npm package (with the bundled native Linux runtimes) under `~/.ultraterm-computer-use` and put `ultraterm-computer-use` in `~/.local/bin`. If Node 18 or newer is missing, the official Node 22 LTS is fetched into the tool's own folder, checksum verified. No sudo, no shell profile edits; the installer prints one line when the bin directory is not on PATH.
- macOS: `install.sh` points at the signed `.pkg` route below and installs nothing, so the signed installer is never bypassed silently. To install the npm package under `~/.ultraterm-computer-use` instead, pass `--npm`: `curl -fsSL https://github.com/michael-berardi/ultraterm-computer-use/releases/latest/download/install.sh | sh -s -- --npm`
- Windows: install under `%LOCALAPPDATA%\UltraTermComputerUse`, write an `ultraterm-computer-use.cmd` shim into its `bin` folder, and add that folder to the user Path only when it is absent. Node is handled the same way as on Linux.

Update by re-running the same one-liner; it upgrades in place. Remove by deleting the install folder and the shim (on Windows, also remove the `bin` folder from your user Path). Set `UTCU_VERSION` to pin a version, `UTCU_HOME` and `UTCU_BIN_DIR` to change locations.

Real app control still needs a logged-in desktop session: Accessibility and Screen Recording on macOS, AT-SPI2 and D-Bus on Linux, UI Automation on Windows.

### Manual: npm package (macOS, Linux, and Windows)

Install the release package with npm:

```bash
npm install --global https://github.com/michael-berardi/ultraterm-computer-use/releases/download/v0.8.0/ultraterm-computer-use-0.8.0.tgz
ultraterm-computer-use --version
```

The package includes native arm64 and x86-64 runtimes and selects the current platform at launch. Each release's `SHA256SUMS` covers the package.

### Manual: signed macOS installer

```bash
curl -fsSLo /tmp/install-ultraterm-computer-use.sh \
  https://github.com/michael-berardi/ultraterm-computer-use/releases/latest/download/install-ultraterm-computer-use.sh
bash /tmp/install-ultraterm-computer-use.sh
rm /tmp/install-ultraterm-computer-use.sh
```

The installer verifies the SHA-256 checksum, Developer ID signature, notarization, bundle identifier, and designated requirement before installing `/Applications/UltraTerm Computer Use.app`.

For a remote install, the expected bundle identifier and team come from the release manifest, whose checksum and the package checksum are verified against `SHA256SUMS`. Checksums distributed alongside artifacts do not authenticate the publisher; set `ULTRATERM_COMPUTER_USE_BUNDLE_ID` and `ULTRATERM_COMPUTER_USE_TEAM_ID` to independently trusted values to pin the expected signing identity. The environment values take precedence over the manifest.

For a local package, both identity variables are required:

```bash
ULTRATERM_COMPUTER_USE_BUNDLE_ID=<bundle-id> \
ULTRATERM_COMPUTER_USE_TEAM_ID=<team-id> \
  ./scripts/install-ultraterm-computer-use.sh --local path/to/UltraTerm-Computer-Use.pkg
```

## Configure an MCP client

```json
{
  "mcpServers": {
    "ultraterm-computer-use": {
      "command": "ultraterm-computer-use",
      "args": ["mcp"]
    }
  }
}
```

Installer helpers are included for common clients:

```bash
ultraterm-computer-use install-codex-mcp
ultraterm-computer-use install-claude-mcp
ultraterm-computer-use install-gemini-mcp
ultraterm-computer-use install-opencode-mcp
```

On macOS, run `ultraterm-computer-use doctor` once and approve the requested permissions. Opening System Settings does not count as a grant; the runtime reads the live OS permission state.

## Commands

```bash
ultraterm-computer-use --help
ultraterm-computer-use doctor
ultraterm-computer-use list-apps
ultraterm-computer-use snapshot TextEdit
ultraterm-computer-use call get_app_state --args '{"app":"TextEdit"}'
ultraterm-computer-use mcp
```

Capture fresh state before using an element index and pass its `state_id` with the action. Prefer element actions over coordinates. `call --calls '<json-array>'` runs several steps in one process and stops at the first error. Design notes for each behaviour are in [`docs/`](./docs/ARCHITECTURE.md).

## UltraTerm Computer Use Pro

The open-source edition includes the complete standard Computer Use tool surface. A separate Pro edition adds live window preview, bounded screen recording and native UltraTerm integration.

## Safety and privacy

Computer Use acts in the user's real desktop session and does not bypass OS permissions. Ask before sending, deleting, purchasing, approving, uploading, or making another externally visible change. Do not inspect password managers or unrelated private content.

Computer Use sends no telemetry or usage data. See [`SECURITY.md`](./SECURITY.md).

## Build from source

```bash
swift build
swift test
./scripts/build-ultraterm-computer-use-app.sh debug
./scripts/build-ultraterm-computer-use-linux.sh --configuration release --arch arm64
./scripts/build-ultraterm-computer-use-windows.sh --configuration release --arch amd64
```

For signed macOS releases, set `ULTRATERM_COMPUTER_USE_BUNDLE_ID` to the existing shipped bundle identifier and `ULTRATERM_COMPUTER_USE_TEAM_ID` to its Apple Developer team. Also configure `ULTRATERM_COMPUTER_USE_CODESIGN_IDENTITY`, `ULTRATERM_COMPUTER_USE_INSTALLER_IDENTITY`, and `ULTRATERM_COMPUTER_USE_NOTARYTOOL_PROFILE` before running `scripts/build-ultraterm-computer-use-release.sh`. Release builds reject missing or example identity values. Ordinary app builds default to `com.example.ultraterm-computer-use`; debug builds append `.dev` to the configured identifier.

Swift 6.2 is required for the macOS app. Go 1.22+ builds the Linux and Windows runtimes.

## License and attribution

UltraTerm Computer Use is released under the [MIT License](./LICENSE). It began from [`iFurySt/open-codex-computer-use`](https://github.com/iFurySt/open-codex-computer-use); [`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md) preserves upstream and third-party attribution.

---

Part of [Pareto Cybernetics](https://paretocybernetics.com/projects/ultraterm-computer-use/): free, private, open-source tools for working with AI agents.

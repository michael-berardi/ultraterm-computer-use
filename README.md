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
  <a href="https://github.com/your-org/ultraterm-computer-use/releases/latest"><img src="https://img.shields.io/github/v/release/your-org/ultraterm-computer-use?label=release" alt="Latest release" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/your-org/ultraterm-computer-use" alt="MIT License" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey" alt="macOS, Linux and Windows" />
  <img src="https://img.shields.io/badge/MCP-9%20tools-8A2BE2" alt="Nine MCP tools" />
</p>

UltraTerm Computer Use is an MIT-licensed Computer Use runtime for macOS, Linux, and Windows. Screenshots, accessibility trees, and input actions stay on the machine. The runtime works with Codex, Claude, Gemini, OpenCode, and other MCP-capable agents.

## Supported platforms

| Platform | Requirements |
| --- | --- |
| macOS 14+ | Logged-in desktop; Accessibility and Screen Recording permissions |
| Linux | Logged-in graphical desktop; AT-SPI2 and D-Bus accessibility |
| Windows | Logged-in desktop; UI Automation |

All three runtimes expose the same nine MCP tools: `list_apps`, `get_app_state`, `click`, `perform_secondary_action`, `scroll`, `drag`, `type_text`, `press_key`, and `set_value`.

## Install

### npm — macOS, Linux, and Windows

Install the release package with npm:

```bash
npm install --global https://github.com/your-org/ultraterm-computer-use/releases/download/v0.6.1/ultraterm-computer-use-0.6.1.tgz
ultraterm-computer-use --version
```

The package includes native arm64 and x86-64 runtimes and selects the current platform at launch. Each release lists a `.sha256` checksum next to the package.

### Signed macOS installer

```bash
curl -fsSLo /tmp/install-ultraterm-computer-use.sh \
  https://raw.githubusercontent.com/your-org/ultraterm-computer-use/main/scripts/install-ultraterm-computer-use.sh
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
ultraterm-computer-use tools
ultraterm-computer-use snapshot TextEdit
ultraterm-computer-use call get_app_state --args '{"app":"TextEdit"}'
ultraterm-computer-use mcp
```

Capture fresh state before using an element index. Prefer semantic actions over coordinate input. Coordinate actions may move the system pointer or require the target app to be visible, depending on the platform.

## UltraTerm Computer Use Pro

The open-source edition includes the complete standard Computer Use tool surface. A separate Pro edition adds advanced visual capture and recording, multi-step automation sessions, and native UltraTerm integration.

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

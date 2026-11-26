# UltraTerm Computer Use

<p align="center">
  <img src="plugins/ultraterm-computer-use/assets/ultraterm-computer-use.svg" alt="UltraTerm Computer Use" width="180" />
</p>

<p align="center">
  <strong>Local desktop automation for agents: a skill and a CLI.</strong><br />
  <a href="#install">Install</a> ·
  <a href="#use-it-from-an-agent">Agent skill</a> ·
  <a href="#commands">CLI</a> ·
  <a href="SECURITY.md">Security</a>
</p>

<p align="center">
  <a href="https://github.com/michael-berardi/ultraterm-computer-use/releases/latest"><img src="https://img.shields.io/github/v/release/michael-berardi/ultraterm-computer-use?label=release" alt="Latest release" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/michael-berardi/ultraterm-computer-use" alt="MIT License" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey" alt="macOS, Linux and Windows" />
  <img src="https://img.shields.io/badge/tools-9%20to%2011-8A2BE2" alt="Nine to eleven tools" />
</p>

UltraTerm Computer Use lets shell-capable agents inspect and control desktop apps through a CLI and skill. An optional stdio MCP server exposes the same tools. It runs locally and sends no telemetry; your agent host decides where returned screenshots and text go.

On macOS, background input and window capture let you keep working without handing over your pointer. Foreground activation and global-pointer fallbacks are opt-in. Linux and Windows have different input limits; see [background operation](docs/background-operation.md).

Capture state before acting and pass its `state_id` to reject stale observations. Element actions check the captured identity; `set_value` verifies the written value. Password fields are excluded from returned values.

| Platform | Requirements | Tools |
| --- | --- | --- |
| macOS 14+ | Logged-in desktop; Accessibility and Screen Recording permissions | Nine common tools, plus `query` and `select_text` |
| Linux | Logged-in graphical desktop; Python 3, PyGObject/GDK, AT-SPI2 and D-Bus | Nine common tools |
| Windows | Logged-in desktop; PowerShell and UI Automation | Nine common tools |

The common tools are `list_apps`, `get_app_state`, `click`, `perform_secondary_action`, `scroll`, `drag`, `type_text`, `press_key`, and `set_value`. `get_app_state` can omit either the accessibility tree or screenshot.

## Install

Use the signed installer below on macOS. On Linux and Windows, the one-step installers download the release npm package, verify its SHA-256 and run a version check.

Linux:

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

Update with `ultraterm-computer-use update` or by re-running the same one-liner. Remove by deleting the install folder, the shim and the update cache folder ([Updates](docs/updates.md#files)); on Windows, also remove the `bin` folder from your user Path. Set `UTCU_VERSION` to pin a version, `UTCU_HOME` and `UTCU_BIN_DIR` to change locations.

Real app control still needs a logged-in desktop session: Accessibility and Screen Recording on macOS, AT-SPI2 and D-Bus on Linux, UI Automation on Windows.

### Manual: npm package (macOS, Linux, and Windows)

Install the release package with npm:

```bash
npm install --global https://github.com/michael-berardi/ultraterm-computer-use/releases/download/v0.11.0/ultraterm-computer-use-0.11.0.tgz
ultraterm-computer-use --version
```

The package includes native arm64 and x86-64 runtimes and selects the current platform at launch. Each release's `SHA256SUMS` covers the package.

### Signed macOS installer

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

## Updates

`ultraterm-computer-use update` installs a newer release after checking it against the release `SHA256SUMS`; `update --check` only reports. In a terminal, the CLI mentions a new release at most once a day. Automatic installs are off unless you run `update --auto on`. See [Updates](docs/updates.md).

## Use it from an agent

The default route is the skill plus the CLI. The skill (`skills/ultraterm-computer-use`) tells the agent to run `ultraterm-computer-use`; the agent asks the CLI for help on the one tool it is about to use, so there is nothing like an MCP tool list in its context ([measured](./docs/context-cost.md): about 15 KB of MCP schemas against a 326-byte skill description until the skill is used).

Install the skill with the `skills` CLI for your agent (commands in [`references/installation.md`](./skills/ultraterm-computer-use/references/installation.md)), then on macOS:

```bash
ultraterm-computer-use doctor        # macOS: approve Accessibility and Screen Recording once
ultraterm-computer-use list_apps
ultraterm-computer-use get_app_state --app TextEdit --media-dir /tmp/shots
ultraterm-computer-use click --app TextEdit --element-index 3 --state-id "STATE_ID_FROM_LAST_RESULT"
```

On macOS the Computer Use app keeps the captured state between calls, so a `state_id` from one call is valid in the next. Output is plain text; `--json` prints the full result envelope. See [Commands](#commands) and [`docs/state-id.md`](./docs/state-id.md).

On macOS, run `ultraterm-computer-use doctor` once and approve the requested permissions. Opening System Settings does not count as a grant; the runtime reads the live OS permission state.

### Optional: MCP server

For a host that can run MCP tools but not shell commands, `ultraterm-computer-use mcp` starts the stdio MCP server with the same tools:

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

Installer helpers write that entry for common clients: `ultraterm-computer-use install-codex-mcp`, `install-claude-mcp`, `install-gemini-mcp`, `install-opencode-mcp`. The Codex plugin does not register the server by default; `plugins/ultraterm-computer-use/optional/mcp.json` is the opt-in entry (see the plugin's `README.md`). On Linux and Windows the CLI keeps state only inside one process, so read-then-act flows there use `call --calls` or this server.

## Commands

See the [CLI reference](docs/cli.md) for tool flags, capture limits, errors and exit statuses.

## Safety

Computer Use acts in the user's real desktop session and does not bypass OS permissions. Ask before sending, deleting, purchasing, approving, uploading, or making another externally visible change. Do not inspect password managers or unrelated private content. See also [`SECURITY.md`](./SECURITY.md).

## Privacy

No telemetry, analytics or crash reports; desktop control works offline.
Screenshots and accessibility text go to your agent host, which may send them to your model provider.
One anonymous update check at most daily, only in a terminal; turn it off with `ULTRATERM_COMPUTER_USE_NO_UPDATE_CHECK=1`.
Installers and `update` download releases from GitHub over HTTPS and verify them against `SHA256SUMS`.
Settings and saved captures stay until you delete them; logs and temp files are capped or removed automatically.
Uninstalling keeps that data; [PRIVACY.md](./PRIVACY.md) lists every path and how to delete it.

## Build from source

```bash
swift build -j 4
swift test -j 4
./scripts/build-ultraterm-computer-use-app.sh debug
./scripts/build-ultraterm-computer-use-linux.sh --configuration release --arch arm64
./scripts/build-ultraterm-computer-use-windows.sh --configuration release --arch amd64
```

For signed macOS releases, set `ULTRATERM_COMPUTER_USE_BUNDLE_ID` to the existing shipped bundle identifier and `ULTRATERM_COMPUTER_USE_TEAM_ID` to its Apple Developer team. Also configure `ULTRATERM_COMPUTER_USE_CODESIGN_IDENTITY`, `ULTRATERM_COMPUTER_USE_INSTALLER_IDENTITY`, and `ULTRATERM_COMPUTER_USE_NOTARYTOOL_PROFILE` before running `scripts/build-ultraterm-computer-use-release.sh`. It builds, notarizes and staples the `.pkg` and `.zip`, packs the npm tarball from that notarized app, and writes one `SHA256SUMS`. Release builds reject missing or example identity values. Ordinary app builds default to `com.example.ultraterm-computer-use`; debug builds append `.dev` to the configured identifier.

Swift 6.2 or newer is required for the macOS app. Go 1.22+ builds the Linux and Windows runtimes.

## License and attribution

UltraTerm Computer Use is released under the [MIT License](./LICENSE). It began from [`iFurySt/open-codex-computer-use`](https://github.com/iFurySt/open-codex-computer-use); [`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md) preserves upstream and third-party attribution.

---

Part of [Pareto Cybernetics](https://paretocybernetics.com/projects/ultraterm-computer-use/): free, private, open-source tools for working with AI agents.

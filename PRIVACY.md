# Privacy

UltraTerm Computer Use runs on your computer. It sends no telemetry, usage data, crash reports or
identifiers.

## What leaves your computer

- **Results your agent asks for.** Screenshots, accessibility text and action results go to the program
  that runs the tool, usually an agent host. That host decides where they go.
- **The update check.** At most once a day, and only after a command you run in a terminal: one anonymous
  HTTPS GET of the public GitHub latest-release record for this project, with the User-Agent
  `ultraterm-computer-use-update-check`. It carries no version, identifier, machine or usage data. GitHub
  sees the request's IP address, as with any web request.
- **Updates you install.** `ultraterm-computer-use update` downloads the release's `SHA256SUMS` and
  installer or package from the same GitHub release.

There is no check outside a terminal, in CI, under agent hosts, with `--json` or after `mcp`.

## What is stored

- `update-state.json` in the cache folder listed in [docs/updates.md](docs/updates.md#files): when the last
  check ran and what it found, a skipped version, when the notice was last shown, and the automatic-install
  choice. Owner-only.
- `auto-update.log` in the same folder, only if you turn on automatic updates; kept under 256 KB.
- Your settings in `~/.config/ultraterm-computer-use/config.json`, if you change any.

## Turning the check off

Set `ULTRATERM_COMPUTER_USE_NO_UPDATE_CHECK=1`, or run
`ultraterm-computer-use config set updates.check false` (signed macOS app: add
`"updates": {"check": false}` to the config file). Deleting the cache folder removes all update state.

# Privacy

This file details the data flows and local files for the UltraTerm Computer Use CLI, stdio MCP server, skill, native runtimes and installers. It applies to released builds and to source builds of the same code.

## Egress and telemetry

- The CLI, MCP server, skill and native runtimes send **no telemetry, analytics, crash reports or usage data**. There is no background network activity and no update prompt.
- Local desktop control works offline. Accessibility text and screenshots are returned to the agent host that called the tool. UltraTerm Computer Use does not upload them; your agent host and its model provider decide what they send onward.
- Commands you run yourself, such as `npm install` or `npx skills add`, are your own network activity, not tool behaviour. The optional `js` command executes the JavaScript you write, which can make its own network calls.
- Network access happens only when you run an install, update or packaging command. Linux and Windows installers fetch release checksums and the release tarball from GitHub over HTTPS and verify SHA-256. If Node.js 18+ is missing, they fetch an official Node build from nodejs.org and verify its SHA-256 too. The signed macOS installer fetches release metadata and assets from GitHub, then verifies checksums, the Developer ID Installer signature and notarization.
- Installer version checks are anonymous: no account, token, license key or usage identifier is sent, and nothing is sent after installation. GitHub still sees ordinary HTTPS request metadata such as your IP address. To skip the "latest release" lookup, pin a version with `UTCU_VERSION` for the Linux/Windows installers, or supply an already downloaded package with `--local` to the signed macOS installer. A pinned version still downloads the pinned release files and their checksums.

## Installers and package tooling

- Installers run npm with `DO_NOT_TRACK=1` and with npm's update notifier, funding and audit messages disabled; release and publish tooling does the same. These settings are process-local and are restored after a Windows install.
- Linux installs under `~/.ultraterm-computer-use` (or `UTCU_HOME`) with the command shim in `~/.local/bin` (or `UTCU_BIN_DIR`); Windows installs under `%LOCALAPPDATA%\UltraTermComputerUse` with a shim in its `bin` folder. The signed macOS route installs `/Applications/UltraTerm Computer Use.app` and a shim under `~/.local/bin`.
- Re-running an installer is how you update; it keeps only the release folder the shim points at and never edits shell profiles. Uninstalling does not delete settings, captures or logs: remove those paths yourself (see the table).

## Local writes and lifetime

Directories are created 0700 and files 0600 unless a path is supplied by you. "Retained" means there is no automatic deletion because the file is user data; delete it when you no longer need it.

| Local write | Contents | Lifetime | Automatic cleanup / retention bound | Delete manually |
| --- | --- | --- | --- | --- |
| Settings: `~/.config/ultraterm-computer-use/config.json`, or `XDG_CONFIG_HOME` / `ULTRATERM_COMPUTER_USE_CONFIG_FILE` | Image and virtual-display settings only; no prompts, screenshots or network endpoints | Until you change or remove it | Retained by design; each `config set` writes a temporary file that is removed in a `finally` block after the atomic rename | Remove the config file |
| Screenshots from `--media-dir`, `inspect` or `call` | PNG/JPEG/WebP images you asked to save, in the directory you chose | Until you delete them | Retained by design; one file per saved result, no rolling upload or archive | Remove the chosen directory or its files |
| `preview --output-dir` | One `latest.jpg` and one `manifest.json` (status, dimensions, frame counters, timestamps) | Latest run's frame stays until you delete it | Overwritten atomically, so at most one frame plus one manifest remain; run length is capped at 3600 s | Remove the output directory |
| `record --output` | One MP4 of the chosen window | Successful recording stays until you delete it | Capped at 600 s and 300 MB; failed or over-cap output is deleted by the recorder | Remove the output file |
| macOS app-agent log: `~/Library/Logs/UltraTerm Computer Use/app-agent.log` | Timestamped lifecycle lines (pid, retire, self-exit, recovery); no prompts or screen contents | Current diagnostics only | Replaced with a fresh file once it exceeds 1 MiB | Remove the file or the log folder |
| Locked Use guardian logs: `~/Library/Logs/UltraTermComputerUse/LockedUse/*.jsonl` | Structured guardian diagnostics (event names, permission and session state) in broker mode | Up to seven days | Pruned by creation date when a new guardian lease starts; older files are not needed for a current unlock | Remove the `LockedUse` log folder |
| macOS agent socket and `<socket>.pid` | Unix socket plus owning pid and kernel start time | While the agent runs | Removed by the agent on clean exit; a launcher retires a stale owner and rebinds the path before starting a replacement | Only when no agent is running: remove the socket and its `.pid` file |
| Linux/Windows runtime temp folder (`runtime.py` / `runtime.ps1` plus one operation JSON) | Script and operation payload for one process | One process invocation | Created owner-only with a unique name and removed with `defer os.RemoveAll` when that process exits | No manual deletion needed |
| Installer temp folders and npm staging | Downloaded checksums, tarball, Node build, staged package | One installer run | Removed by an `EXIT` trap in `install.sh` and the signed macOS installer, and by a `finally` block in `install.ps1`; failed installs leave nothing staged | If an install was killed, remove stale `utcu-install.*`, `ultraterm-computer-use-install.*`, `.staging-*` or `task-verifier-checks.*` folders |
| Build output (`.build/`, `dist/`) and installed `release-*` folders | Compiler caches, staged apps/packages, the active installed release | Until replaced or removed by you | Release packaging clears its own output paths; installers delete old `release-*` folders. Locked Use verifier scratch folders are removed at build start and on exit | Remove `.build/` or `dist/` when you no longer need build artifacts |
| Test-only smoke observation file under the system temp directory | One JSON file with cursor observation state | Until the smoke run is replaced or the OS purges old temp files | Recreated at the start of the cursor smoke run; the OS temp cleaner bounds its age | Remove the `ultraterm-computer-use-smoke` temp folder |

To stop keeping local data: delete the config file, every capture/output path you chose, the two log folders above, and the install folder or app if you also want to remove the tool itself. Uninstalling alone does not delete data you created.

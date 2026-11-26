# CLI reference

```bash
ultraterm-computer-use --help
ultraterm-computer-use doctor
ultraterm-computer-use doctor --status-only
ultraterm-computer-use list-apps
ultraterm-computer-use targets --running-only --json
ultraterm-computer-use tools
ultraterm-computer-use help click
ultraterm-computer-use inspect TextEdit
ultraterm-computer-use snapshot TextEdit
ultraterm-computer-use get_app_state --app TextEdit --media-dir /tmp/shots
ultraterm-computer-use call get_app_state --args '{"app":"TextEdit"}'
ultraterm-computer-use preview --output-dir /tmp/preview TextEdit
ultraterm-computer-use record --output /tmp/textedit.mp4 TextEdit
ultraterm-computer-use mcp      # optional MCP server
ultraterm-computer-use update   # install a newer release; see updates.md
```

Capture fresh state before using an element index and pass its `state_id` with the action (`--state-id`). Prefer element actions over coordinates. `call --calls '<json-array>'` runs several steps in one process and stops at the first error. Design notes for each behaviour are in [`docs/`](ARCHITECTURE.md).

These commands, the tool flags, plain-text output, shared state and the structured errors and exit statuses below are in the macOS runtime. The Linux and Windows runtimes provide `mcp`, `doctor`, `list-apps`, `snapshot` and `call` (`--args` JSON, JSON output).

- `doctor` prints the live permission state and opens the onboarding app when a permission is missing. `doctor --status-only` only prints it and never launches the app or prompts; `doctor --json` prints the state as JSON, also without launching anything.
- `targets [--running-only] [--json]` lists apps an agent can target. It is read-only: it never launches, activates or prompts. Password managers are never listed.
- `call <tool> [--<argument> <value> ...] [--json] [--media-dir <dir>]` runs one tool; the tool name also works without `call` (`click --app TextEdit --element-index 3`). Arguments are flags generated from the tool's schema (`--element-index` or `--element_index`), and `--args '<json>'` / `--args-file` still work. Output is the tool's plain text; `--json` prints the result envelope, and `--media-dir` saves screenshots as files (`image: <path>`). `help <tool>` or `<tool> --help` lists a tool's flags. State from one call stays valid for the next (10 minutes idle).
- `tools [name] [--json]` prints the tool catalog, or one tool's description and input schema. It runs offline and needs no permissions.
- `inspect [--json] [--window <title>] [--media-dir <path>] <app>` prints the accessibility snapshot and a screenshot of an app that is already running. It never launches or activates the app and does not register state for actions. It needs Screen Recording permission for the screenshot. With `--media-dir`, the screenshot is written into that directory and the result points at the file instead of carrying base64 data.
- `preview [--output-dir <path>] [--duration <seconds>] [--fps <1-60>] [--max-width <px>] [--quality <0.05-1>] [--include-cursor] <app>` keeps a live JPEG of one window of a running app: `latest.jpg` is replaced atomically and `manifest.json` records size, timestamps and frame counters. `--output-dir` is required.
- `record [--output <path>] [--duration <seconds>] [--fps <1-60>] [--max-width <px>] [--bitrate <bps>] [--include-cursor] <app>` records one window of a running app to an H.264 MP4 with no audio. `--output` is required.
- For `inspect`, `snapshot` and `call`, an app target is a name, a bundle identifier, `pid:<pid>` or a bare pid. A pid addresses exactly one process, and an ambiguous name is refused with the candidates listed. `preview` and `record` take a name or a bundle identifier.

`preview` and `record` capture the screen, so they need Screen Recording permission; without it they stop with an error that points to `doctor`. They only capture an app that is already running, never launch, activate or unhide it, and never open a viewer. They are bounded:

| Limit | `preview` | `record` |
| --- | --- | --- |
| Duration | up to 3600 seconds (default 30) | up to 600 seconds (default 60); longer requests are cut to 600 |
| Frames per second | 1 to 60 (default 8) | 1 to 60 (default 15) |
| Width | 64 to 16384 px (default 960) | 64 to 16384 px (default 1920) |
| Other | JPEG quality 0.05 to 1 (default 0.8) | bitrate 100000 to 200000000 bps (default 4000000); output stops at 300 MB |

Both write only to the path you give: `preview` to `latest.jpg` and `manifest.json` inside `--output-dir` (created if missing), `record` to the `--output` file (an existing file there is replaced, and a partial file is removed on failure). They print a JSON summary, stop cleanly on Ctrl-C or SIGTERM, and never upload anything or contact any server. The system cursor is left out of frames unless you pass `--include-cursor`.

Failures from `call` print `error[code] (phase): message` with a `hint:` and `candidates:` on stderr (with `--json`, an `error` object with `code`, `phase`, `call_index`, `retryable`, `hint`, `candidates`, `message` next to the usual result text), and the process exits with a stable status: 0 success, 1 other failure, 2 usage or invalid arguments, 3 permission denied, 4 app not found, 5 ambiguous app, 6 state unavailable, 7 stale state. Arguments are checked against each tool's input schema before it runs, and a sequence is checked in full before its first call acts.


---
name: ultraterm-computer-use
description: Operate native desktop apps on macOS, Linux and Windows by running the ultraterm-computer-use CLI from the shell. Works in the background and needs no MCP server. Use when an agent must install, verify, troubleshoot or drive it, and no file, CLI, API or browser route can do the task.
---

# UltraTerm Computer Use

Drive desktop apps from the shell with `ultraterm-computer-use`. Screenshots, accessibility trees and input stay on the machine. No MCP server is needed, so no tool schemas load into your context: ask the CLI for help on the one tool you are about to use.

## When to use it

1. Prefer files, CLIs, APIs and app-specific automation.
2. Use browser automation for web pages.
3. Use UltraTerm Computer Use for a step that only a native app's interface can do.

## It works in the background

The person at the computer keeps working while you drive an app. By default the runtime does not activate apps, raise or unminimize windows, or move the real pointer.

- A hidden or minimized app is reported as unavailable instead of being brought forward. Say so, or ask the user to set `ULTRATERM_COMPUTER_USE_ALLOW_FOREGROUND=1` (macOS) when the task needs it.
- Actions that need the real pointer (a `drag` that moves a window, selects text by dragging or drops a file; `click_method: global`) are refused unless the user set `ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1`. On Linux this also covers coordinate clicks and keys sent to a window that is not active.
- Do not set either switch yourself. Do not overwrite the clipboard unless asked.

## Workflow

1. On macOS, check `sw_vers -productVersion` is 14.0 or later. If `ultraterm-computer-use --version` fails, read [references/installation.md](references/installation.md).
2. On macOS, run `ultraterm-computer-use doctor` once; the user approves Accessibility and Screen Recording. Opening System Settings is not a grant.
3. `ultraterm-computer-use list_apps`, then `ultraterm-computer-use get_app_state --app <name> --media-dir <dir>`. It prints the accessibility tree and a `State-ID:` line, and `image: <path>` for the screenshot (Read that file if you need to see it).
4. Act with an `element_index` from that state and its id: `ultraterm-computer-use click --app <name> --element-index 3 --state-id <id>`. The result is the new state with a new `State-ID`; use that one next.
5. A `stale_state` error (exit 7) means the app was captured again or the saved state expired. Nothing was sent: run `get_app_state` and retry.

Each call is a separate process, but on macOS the Computer Use app keeps the captured state between calls (10 minutes idle), so ids and indexes carry over. Without the app (`ULTRATERM_COMPUTER_USE_DISABLE_APP_AGENT_PROXY=1`) they do not: use `call --calls` there.

Linux and Windows: the flags, plain-text output, `--media-dir` and shared state below are macOS. Their `call <tool> --args '<json>'` prints the JSON envelope and keeps state only inside one process, so read-then-act flows use `call --calls`, or the optional MCP server (see [references/usage.md](references/usage.md)).

Tools on every platform: `list_apps`, `get_app_state`, `click`, `perform_secondary_action`, `scroll`, `drag`, `type_text`, `press_key`, `set_value`. macOS adds `query` (find a control by text or role without a screenshot or full tree) and `select_text`.

## The CLI

```sh
ultraterm-computer-use tools                      # tool names, one line each
ultraterm-computer-use help click                 # one tool's flags, from its schema
ultraterm-computer-use set_value --app TextEdit --element-index 1 --value "Draft" --state-id <id>
ultraterm-computer-use get_app_state --app TextEdit --include-screenshot false --text-limit 1000
ultraterm-computer-use query --app Notes --text Save --role button     # macOS; then click --element-index <index>
ultraterm-computer-use call get_app_state --args '{"app":"TextEdit"}'   # JSON arguments also work
ultraterm-computer-use call --calls '[{"tool":"press_key","args":{"app":"TextEdit","key":"Return"}}]'
```

- Flags are the tool's argument names (`--element-index` or `--element_index`). `call` before the tool name is optional.
- Output is plain text. `--json` prints the full result envelope instead. `--media-dir <dir>` saves screenshots as files.
- Errors go to stderr as `error[code] (phase): message`, with a `hint:` and `candidates:`. Exit status: 2 usage or invalid arguments, 3 permission denied, 4 app not found, 5 ambiguous app, 6 state unavailable, 7 stale state, 1 other. App targets can be `pid:<pid>`.
- `call --calls '<json-array>'` runs several steps in one process and stops at the first error.

## Spend fewer tokens

- `--include-screenshot false` when the tree is enough; `--include-ax false` when only the picture is needed. Turning the tree off invalidates element indexes.
- On macOS, `query` finds one control without reading the whole window.
- `--text-limit 1000` or `max` for long text; raise `--max-tree-nodes` or `--max-tree-depth` only when a list looks cut off.

## Rules

- This is the user's real session. Do not open password managers or unrelated private content.
- Ask before sending, deleting, purchasing, approving, uploading or any other change someone else will see.
- Prefer element actions and `set_value`; coordinates are the fallback. Never reuse an index from an older state.
- Password fields: values are never returned. Do not try to read them another way.
- On Linux and Windows, run inside the logged-in desktop session.

## Read-only and capture commands (macOS)

`doctor --status-only`, `targets --running-only --json`, `tools` and `inspect <app>` read only: they never launch or activate an app. `inspect` includes a screenshot and needs Screen Recording permission. `preview --output-dir <dir> <app>` and `record --output <file.mp4> <app>` capture one window of a running app. They need Screen Recording permission, are bounded (preview up to 3600 seconds; record up to 600 seconds and 300 MB), write only to the path given, and never upload. Ask the user before capturing windows that may show private content.

## References

- [references/usage.md](references/usage.md): the CLI in full, sequences, state ids, click and key methods, platform behaviour, and the optional MCP server and JavaScript mode.
- [references/installation.md](references/installation.md): install, permissions, installing this skill, and the optional MCP entries for hosts without a shell.
- [references/troubleshooting.md](references/troubleshooting.md): permission, session, discovery and action failures.

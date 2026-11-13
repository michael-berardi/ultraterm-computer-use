---
name: ultraterm-computer-use
description: Operate native desktop apps on macOS, Linux and Windows through UltraTerm Computer Use, a local CLI and stdio MCP server that works in the background. Use when an agent needs to install, verify, troubleshoot, configure or drive it, and no file, CLI, API or browser route can do the task.
---

# UltraTerm Computer Use

A local CLI and stdio MCP server for desktop apps. Screenshots, accessibility trees and input stay on the machine. It is not tied to one agent host.

## When to use it

1. Prefer files, CLIs, APIs and app-specific automation.
2. Use browser automation for web pages.
3. Use UltraTerm Computer Use for a step that only a native app's interface can do.

## It works in the background

The person at the computer keeps working while you drive an app. By default the runtime does not activate apps, raise or unminimize windows, or move the real pointer.

- A hidden or minimized app is reported as unavailable instead of being brought forward. Say so, or ask the user to set `ULTRATERM_COMPUTER_USE_ALLOW_FOREGROUND=1` (macOS) when the task needs it.
- Actions that need the real pointer (a `drag` that moves a window, selects text by dragging or drops a file; `click_method: "global"`) are refused unless the user set `ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1`. On Linux this also covers coordinate clicks and keys sent to a window that is not active.
- Do not set either switch yourself. Do not overwrite the clipboard unless asked.

## Workflow

1. On macOS, check `sw_vers -productVersion` is 14.0 or later; older versions cannot run the app, and permissions do not fix that.
2. `ultraterm-computer-use --version`. If it is missing, read [references/installation.md](references/installation.md).
3. On macOS, run `ultraterm-computer-use doctor` once; the user approves Accessibility and Screen Recording. Opening System Settings is not a grant.
4. `ultraterm-computer-use call list_apps`.
5. `get_app_state` for the app. Keep the `state_id` it returns.
6. Act on an `element_index` from that state and pass the `state_id`. If the app's state was captured again in between, the action fails with `stale_state` before anything is sent: call `get_app_state` and retry.
7. Read the action result (it is the new state, with a new `state_id`) to confirm the change.

Tools on every platform: `list_apps`, `get_app_state`, `click`, `perform_secondary_action`, `scroll`, `drag`, `type_text`, `press_key`, `set_value`. macOS adds `query` (find controls by text or role without a screenshot or full tree) and `select_text`.

## Spend fewer tokens

- `include_screenshot: false` when the tree is enough; `include_ax: false` when only the picture is needed. Turning the tree off invalidates element indexes.
- On macOS, `query` finds one control without reading the whole window.
- `text_limit: 1000` or `"max"` for long text; raise `max_tree_nodes` or `max_tree_depth` only when a list looks cut off.
- Several steps in one process: `ultraterm-computer-use call --calls '<json-array>'`. It stops at the first error.

## Rules

- This is the user's real session. Do not open password managers or unrelated private content.
- Ask before sending, deleting, purchasing, approving, uploading or any other change someone else will see.
- Prefer element actions and `set_value`; coordinates are the fallback. Never reuse an index from an older state.
- Password fields: values are never returned. Do not try to read them another way.
- On Linux and Windows, run inside the logged-in desktop session.

## Commands

```sh
ultraterm-computer-use --version
ultraterm-computer-use doctor
ultraterm-computer-use doctor --status-only
ultraterm-computer-use targets --running-only --json
ultraterm-computer-use tools click
ultraterm-computer-use inspect TextEdit
ultraterm-computer-use call list_apps
ultraterm-computer-use call get_app_state --args '{"app":"TextEdit"}'
ultraterm-computer-use call get_app_state --args '{"app":"TextEdit","include_screenshot":false,"text_limit":1000}'
ultraterm-computer-use call click --args '{"app":"TextEdit","element_index":"3","state_id":"<state_id>"}'
ultraterm-computer-use call --calls '[
  {"tool":"get_app_state","args":{"app":"TextEdit"}},
  {"tool":"press_key","args":{"app":"TextEdit","key":"Return"}}
]'
ultraterm-computer-use mcp
```

MCP configuration:

```json
{
  "mcpServers": {
    "ultraterm-computer-use": { "command": "ultraterm-computer-use", "args": ["mcp"] }
  }
}
```

## Read-only and capture commands (macOS)

- `doctor --status-only` prints permissions without launching onboarding. `targets`, `tools` and `inspect <app>` read only: they never launch or activate an app. `inspect` includes a screenshot and needs Screen Recording permission.
- `preview --output-dir <dir> <app>` and `record --output <file.mp4> <app>` capture one window of a running app. They need Screen Recording permission, are bounded (preview up to 3600 seconds; record up to 600 seconds and 300 MB), write only to the path given, and never upload. Ask the user before capturing windows that may show private content.
- A failed `call` adds an `error` object (`code`, `phase`, `retryable`, `hint`, `candidates`) and exits with 2 usage, 3 permission denied, 4 app not found, 5 ambiguous app, 6 state unavailable, or 7 stale state (1 for other failures). App targets can be `pid:<pid>`.

## References

- [references/installation.md](references/installation.md): install, MCP setup for common hosts, macOS permissions.
- [references/usage.md](references/usage.md): tool calls, sequences, the JavaScript mode and platform behaviour.
- [references/troubleshooting.md](references/troubleshooting.md): permission, session, discovery and action failures.

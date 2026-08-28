---
name: ultraterm-computer-use
description: Platform-neutral guidance for using UltraTerm Computer Use, the open-source Computer Use MCP server and CLI for macOS, Linux, and Windows. Use when an agent needs to install, verify, troubleshoot, configure, or operate UltraTerm Computer Use through its native CLI, stdio MCP server, or direct Computer Use tool calls.
---

# UltraTerm Computer Use

## Overview

UltraTerm Computer Use exposes Computer Use as a local CLI and stdio MCP server. It is not Codex.app-specific; adapt the commands and MCP config to the agent runtime you are operating in.

The macOS runtime requires macOS 14.0 or later. Windows and Linux use their own platform runtimes and are not subject to this macOS minimum.

It supports the same core tool surface across macOS, Linux, and Windows:
`list_apps`, `get_app_state`, `click`, `perform_secondary_action`, `scroll`,
`drag`, `type_text`, `press_key`, and `set_value`.

## Core Workflow

1. On macOS, run `sw_vers -productVersion` before invoking the CLI and require macOS 14.0 or later. On older versions, explain that the runtime cannot launch; do not recommend `doctor` or permission changes as a fix for binary incompatibility.
2. Check the CLI is installed with `ultraterm-computer-use --help`. If installation or setup is missing, read [references/installation.md](references/installation.md).
3. On supported macOS versions, run `ultraterm-computer-use doctor` before the first real GUI task. If permissions are missing, ask the user to approve Accessibility and Screen Recording in the onboarding UI.
4. Inspect available apps before acting: `ultraterm-computer-use call list_apps`.
5. Capture current UI state with `ultraterm-computer-use call get_app_state --args '{"app":"TextEdit"}'`. The default state is usually enough for UI operation.
6. When the task needs longer semantic text, such as chat history, email bodies, document text, or long form content, call `get_app_state` with `text_limit: 1000` or `text_limit: "max"`.
7. When visible long pages or lists appear incomplete even after scrolling, call `get_app_state` with a larger `max_tree_nodes` or `max_tree_depth`.
8. Prefer element-targeted actions using `element_index` from the latest `get_app_state` result.
9. For multi-step CLI work, use `ultraterm-computer-use call --calls '<json-array>'` so one process can reuse the latest element index mapping.
10. For agent runtimes that support local MCP servers, configure `ultraterm-computer-use mcp` and call the exposed Computer Use tools directly. Read [references/usage.md](references/usage.md).
11. If communication, permission, or desktop-session access fails, read [references/troubleshooting.md](references/troubleshooting.md).

## Operating Rules

- Treat the target desktop as the user's real session. Do not inspect password managers, unrelated private content, or sensitive apps unless the user explicitly asked for that task.
- Ask before sending, deleting, purchasing, approving, uploading, or making other externally visible changes.
- Do not assume a Codex.app plugin helper is available. Use the installed `ultraterm-computer-use` CLI or an explicit MCP config.
- Always run `get_app_state` before using `element_index`; do not guess indexes across sessions or after large UI changes.
- Prefer semantic actions and `set_value` for editable controls. Use coordinate `click`, `scroll`, and `drag` only when the element tree does not expose a safer target.
- On macOS, do not enable `ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` unless the user explicitly requested `click_method: "global"` or other diagnostic behavior that may move the real pointer.
- On Windows and Linux, confirm the command is running inside the logged-in desktop session before assuming GUI automation is available.

## Common CLI Actions

```sh
ultraterm-computer-use --help
ultraterm-computer-use doctor
ultraterm-computer-use call list_apps
ultraterm-computer-use call get_app_state --args '{"app":"TextEdit"}'
ultraterm-computer-use call get_app_state --args '{"app":"TextEdit","text_limit":1000}'
ultraterm-computer-use call get_app_state --args '{"app":"TextEdit","text_limit":"max"}'
ultraterm-computer-use call get_app_state --args '{"app":"Google Chrome","max_tree_nodes":3000,"max_tree_depth":96}'
ultraterm-computer-use call click --args '{"app":"TextEdit","element_index":"0"}'
ultraterm-computer-use call type_text --args '{"app":"TextEdit","text":"Hello from UltraTerm Computer Use"}'
```

For a short sequence that reuses state in one process:

```sh
ultraterm-computer-use call --calls '[
  {"tool":"get_app_state","args":{"app":"TextEdit"}},
  {"tool":"press_key","args":{"app":"TextEdit","key":"Return"}}
]'
```

## MCP Usage

For runtimes that can launch local MCP servers over stdio, use:

```toml
[mcp_servers.ultraterm_computer_use]
command = "ultraterm-computer-use"
args = ["mcp"]
```

Read [references/usage.md](references/usage.md) for JSON config examples, direct tool-call patterns, and platform notes.

## References

- [references/installation.md](references/installation.md): one-time CLI install, agent MCP install commands, and macOS permissions.
- [references/usage.md](references/usage.md): MCP config, direct CLI calls, sequencing, and platform behavior.
- [references/troubleshooting.md](references/troubleshooting.md): permission, desktop-session, app discovery, and action failures.

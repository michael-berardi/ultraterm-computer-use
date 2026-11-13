# UltraTerm Computer Use Troubleshooting

Read this reference when setup, permission checks, app discovery, snapshots, or actions fail.

## Unsupported macOS Version

The macOS runtime requires macOS 14.0 or later. Check the host version before troubleshooting permissions:

```sh
sw_vers -productVersion
```

On macOS versions earlier than 14.0, the binary cannot launch and may report a `dyld` or minimum-version incompatibility. `ultraterm-computer-use doctor`, Accessibility authorization, and Screen Recording authorization cannot resolve this error. Upgrade macOS or run UltraTerm Computer Use on a supported macOS, Windows, or Linux desktop.

## First Checks

Start with:

```sh
ultraterm-computer-use --help
ultraterm-computer-use doctor
ultraterm-computer-use call list_apps
```

On macOS 14.0 or later, `doctor` reports Accessibility and Screen Recording status. If either is missing, ask the user to approve the onboarding UI.

## App Not Found

If `get_app_state` cannot find an app:

1. Run `ultraterm-computer-use call list_apps`.
2. Use the app name or bundle identifier from that result.
3. Confirm the app is running and has a visible, non-minimized window.
4. On macOS, rerun `ultraterm-computer-use doctor`.

Do not silently switch to a different app when the requested target is not available.

## Empty Or Missing Snapshot

Common causes:

- The app has no visible window.
- The window is minimized, hidden, or on an unavailable desktop.
- macOS Screen Recording permission is missing.
- Windows or Linux commands are running outside the logged-in desktop session.
- Linux screenshot support is blocked by the compositor or desktop portal state.

Ask the user to bring the target app/window into a visible state when automation cannot do so safely.

On macOS, a hidden app, a minimized window or an app with no open window fails with `The app has no window that can be read in the background`. Nothing was changed. On a busy machine the app may simply not have answered in time, so call `get_app_state` again first. Fix if it keeps failing: ask the user to show the window, or, if they agree, set `ULTRATERM_COMPUTER_USE_ALLOW_FOREGROUND=1` in the server environment so the runtime may unhide, unminimize and raise it.

On Windows, `get_app_state` may intentionally return the accessibility tree without an image when the main window is hidden, minimized, DWM-cloaked, off-screen, or too small to be a trustworthy Computer Use screenshot. Do not synthesize, upscale, or pad an image. Use `element_index` actions when the returned tree is sufficient; screenshot-coordinate click and drag require a later state result that contains a usable image.

## Truncated Text

Snapshot text is limited to 500 characters by default. If a visible chat message, email body, document paragraph, or form value ends with `...`, do not assume the page itself is missing content.

Request a larger or unlimited text limit explicitly:

```sh
ultraterm-computer-use call get_app_state --args '{"app":"TextEdit","text_limit":1000}'
ultraterm-computer-use call get_app_state --args '{"app":"TextEdit","text_limit":"max"}'
ultraterm-computer-use snapshot --text-limit 1000 TextEdit
ultraterm-computer-use snapshot --text-limit max TextEdit
```

`text_limit: "max"` only disables the text character limit. It does not remove the default 1200 node count limit, 64 level tree depth limit, screenshot size, permission, or desktop-session protections.

## Incomplete Long Pages Or Lists

If the screenshot clearly shows more visible content than the accessibility tree returns, the snapshot may have hit its default 1200 node or 64 level tree budget. Do not treat that as proof that the page failed to load.

Request a larger tree budget explicitly:

```sh
ultraterm-computer-use call get_app_state --args '{"app":"Google Chrome","max_tree_nodes":3000,"max_tree_depth":96}'
ultraterm-computer-use snapshot --max-tree-nodes 3000 --max-tree-depth 96 "Google Chrome"
```

Increasing the tree budget does not change text truncation, screenshot limits, permissions, or desktop-session requirements.

## Element Action Fails

If an element-targeted action fails:

1. Re-run `get_app_state`.
2. Confirm the `element_index` still exists and refers to the intended UI element.
3. Prefer `set_value` for settable text/value controls.
4. Prefer `perform_secondary_action` only for actions exposed in the state result.
5. Use coordinate `click`, `scroll`, or `drag` only after the semantic route is unavailable.

## stale_state

An action that fails with `stale_state` was given a `state_id` that is no longer the latest for that app. Nothing was sent. Run `get_app_state`, read the new state, and retry with the new `state_id`. See `docs/state-id.md`.

## Linux Action Refused

On Linux, a coordinate click, a drag, `click_method=global`, and keys for a window that is not active are refused with a message that says nothing was sent. Use `element_index` and `set_value` where you can, or ask the user to make the window active. Only if the user agrees, set `ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` in the server environment. `ULTRATERM_COMPUTER_USE_ALLOW_FOREGROUND` has no effect on Linux.

## Desktop Session Issues

Windows UI Automation and Linux AT-SPI require a live user desktop. SSH sessions, CI jobs, launch daemons, or services often do not have access to the GUI session even when the CLI binary starts successfully.

If desktop access is missing, ask the user to run the command from the logged-in desktop session or start the target app visibly in that session.

## Linux Accessible Interface Errors

If a Linux release reports that `Accessible` has no `is_text` or `is_editable_text` attribute, upgrade to a release containing the AT-SPI interface-detection fix. Current source checks `Accessible.get_interfaces()` for `Text` and `EditableText`, which is compatible with the PyGObject bindings used by Ubuntu 24.04.

## Permission And Safety Issues

- Do not bypass macOS TCC prompts.
- Do not enable global pointer fallbacks unless the user asks for low-level diagnostic behavior.
- Do not interact with password managers or sensitive apps unless the user explicitly requests it.
- Pause before submitting, sending, deleting, purchasing, or approving anything externally visible.

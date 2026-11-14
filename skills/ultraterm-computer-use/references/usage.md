# UltraTerm Computer Use Usage

Read this reference when the task requires direct Computer Use tool calls, MCP configuration, or platform-specific behavior.

## CLI tool calls (the default route)

Every Computer Use tool is a CLI command. This section describes the macOS runtime. The Linux and Windows runtimes accept `call <tool> --args '<json>'` and `call --calls`, print the JSON envelope, exit 0 or 1, and keep state only inside one process; for read-then-act flows there use `call --calls`, or the optional MCP server below. Nothing needs an MCP server, so no tool schemas are loaded into the agent's context. Run `ultraterm-computer-use tools` for the list, and `ultraterm-computer-use help <tool>` (or `<tool> --help`) for one tool's arguments, which are generated from the same schema the MCP server lists.

```sh
ultraterm-computer-use call list_apps
ultraterm-computer-use call get_app_state --app TextEdit --media-dir /tmp/shots
ultraterm-computer-use click --app TextEdit --element-index 3 --state-id 3f9a1c07b2d4
ultraterm-computer-use set_value --app TextEdit --element-index 1 --value "Draft" --state-id 3f9a1c07b2d4
ultraterm-computer-use call get_app_state --args '{"app":"TextEdit","text_limit":1000}'
```

- A tool name works with or without `call`. Arguments are flags named after the schema properties (`--element-index` and `--element_index` both work, `--flag=value` too). A boolean flag alone means true. `--args '<json>'` and `--args-file <path>` still work, and flags win over `--args`.
- Output is the tool's plain text, ending with the `State-ID:` line. A screenshot is saved with `--media-dir <dir>` and printed as `image: <path>` (read that file to see it). Without `--media-dir` it is only noted, never printed as base64. `--json` prints the full result envelope (`content`, `isError`, `error`, `state_id`) as before.
- A failed call prints `error[code] (phase): message`, a `hint:` and `candidates:` on stderr and exits with a stable status: 2 usage or invalid arguments, 3 permission denied, 4 app not found, 5 ambiguous app, 6 state unavailable, 7 stale state, 1 anything else. With `--json` the same error is in the envelope on stdout.

### State across separate calls

The Computer Use app keeps the captured state, so the `state_id` and the element indexes from one `call` are valid in the next `call` (also `query` indexes, for their 120 seconds). The state is replaced when the app is captured again, and dropped after 10 minutes without a call. If the state is gone, the action is refused with `stale_state` (exit 7) before anything is sent: run `get_app_state` again.

Two clients driving the same app share that one saved state, so the older client sees `stale_state` and refreshes. With `ULTRATERM_COMPUTER_USE_DISABLE_APP_AGENT_PROXY=1` (no app), every call starts empty; use `call --calls` there, which keeps all steps in one process.

### Sequences

```sh
ultraterm-computer-use call --calls '[
  {"tool":"get_app_state","args":{"app":"TextEdit"}},
  {"tool":"click","args":{"app":"TextEdit","element_index":"1"}},
  {"tool":"type_text","args":{"app":"TextEdit","text":"Hello"}}
]'
ultraterm-computer-use call --calls-file examples/textedit-overlay-seq.json --sleep 0.5
```

Use a sequence for fixed steps you do not need to read in between. It checks every call's arguments first, stops at the first failure, and waits 0.2 seconds between successful steps (`--sleep <seconds>` changes that). Output is each step under a `== N. tool ==` line.

`set_value` verifies the actual value on macOS, Windows and Linux, including when full action read-back is disabled. Text is exact: whitespace, case and leading zeros matter; `""` clears the field. Verification polls for up to 0.6 seconds without repeating the write. If it fails, observe the control before deciding to retry: the write may already have changed it.

## Read-only commands and screen capture (macOS)

These commands are in the macOS runtime. The Linux and Windows runtimes do not have them.

```sh
ultraterm-computer-use doctor --status-only
ultraterm-computer-use targets --running-only --json
ultraterm-computer-use tools
ultraterm-computer-use tools click --json
ultraterm-computer-use inspect --json --media-dir /tmp/shots TextEdit
ultraterm-computer-use preview --output-dir /tmp/preview --duration 20 TextEdit
ultraterm-computer-use record --output /tmp/textedit.mp4 --duration 30 TextEdit
```

- `doctor --status-only` prints the permission state and never launches the onboarding app or prompts. `doctor --json` prints it as JSON, also without launching anything.
- `targets` lists targetable apps (`--running-only` keeps only running ones; JSON entries have `name`, `running`, `frontmost`, and `bundle_id` when known, plus `pid` with `--running-only`). `tools` prints the tool catalog or one tool's input schema. Neither launches, activates or prompts.
- `inspect <app>` prints the accessibility snapshot and a screenshot of a running app without launching or activating it, and it does not register state for later actions. The screenshot needs Screen Recording permission. `--window <title>` picks the window whose title contains the text. `--media-dir <path>` writes the screenshot into that directory and returns an `image_path` item with the file path instead of base64 data.
- `preview` and `record` capture the screen contents of one window of an already running app, so they need Screen Recording permission. They never launch, activate or unhide the app, never open a viewer, never upload anything, and write only to the path you give: `preview` to `latest.jpg` and `manifest.json` inside `--output-dir`, `record` to the `--output` file. Both are bounded: `preview` runs up to 3600 seconds (default 30) at 1 to 60 fps (default 8) with widths of 64 to 16384 px (default 960) and JPEG quality 0.05 to 1 (default 0.8). `record` is cut at 600 seconds (default 60) and 300 MB, at 1 to 60 fps (default 15), widths of 64 to 16384 px (default 1920) and 100000 to 200000000 bps (default 4000000), with no audio. The cursor is left out unless `--include-cursor` is given. Both print a JSON summary and stop cleanly on Ctrl-C or SIGTERM. They accept an app name or bundle identifier.
- App targets for `inspect`, `snapshot` and `call` can also be `pid:<pid>` or a bare pid, which addresses exactly one process. An ambiguous name is refused with its candidates.

### Errors and exit statuses

`call` checks every call's arguments against the tool's input schema before it runs. For `--calls`, all calls are checked first, so an invalid later call stops the run before any earlier call acts (an unknown tool name is reported when the sequence reaches it). A failed result keeps its text and adds an `error` object with `code`, `phase` (`parse`, `preflight`, `resolve` or `execute`), `call_index`, `retryable`, `hint`, `candidates` and `message`; the plain-text form prints the same fields (see above). Exit statuses: 0 success, 1 other failure, 2 usage or invalid arguments, 3 permission denied, 4 app not found, 5 ambiguous app, 6 state unavailable, 7 stale state.

`click` rejects a `mouse_button` other than `left`, `right` or `middle`, a `click_count` below 1, and JSON booleans where a number or element index is expected.

## Text Limits

Snapshot text is truncated to 500 characters by default and ends with `...` when truncation happens. This keeps normal UI state compact for agent planning and element-targeted actions.

Use a larger text limit when the task depends on longer semantic text, such as chat histories, email bodies, document text, or long form content. Use `max` only when complete text is required:

```sh
ultraterm-computer-use call get_app_state --args '{"app":"TextEdit","text_limit":1000}'
ultraterm-computer-use call get_app_state --args '{"app":"TextEdit","text_limit":"max"}'
ultraterm-computer-use snapshot --text-limit 1000 TextEdit
ultraterm-computer-use snapshot --text-limit max TextEdit
```

The same `text_limit` tool argument and `--text-limit` snapshot flag apply on macOS, Linux, and Windows. `text_limit` accepts a positive integer or the string `"max"`.

Action tools return refreshed app state with the default 500 character text limit. If longer text is still needed after an action, run `get_app_state` again with `text_limit: 1000` or `text_limit: "max"`.

## Larger Tree Budgets

Accessibility tree rendering defaults to 1200 nodes and 64 levels on macOS, Linux, and Windows. This keeps normal snapshots bounded while preserving most interactive UI.

Use a larger tree budget when a visible long page, list, table, or web app appears incomplete even after scrolling:

```sh
ultraterm-computer-use call get_app_state --args '{"app":"Google Chrome","max_tree_nodes":3000,"max_tree_depth":96}'
ultraterm-computer-use snapshot --max-tree-nodes 3000 --max-tree-depth 96 "Google Chrome"
```

`max_tree_nodes` and `max_tree_depth` must be positive integers. They only affect explicit `get_app_state` and `snapshot` calls; action tools still return refreshed state with the default tree budget.

## State ids

Every `get_app_state` result and every action result that includes a state carries a `state_id`. It is a `State-ID:` text line and a `state_id` field.

Pass it as `state_id` on `click`, `perform_secondary_action`, `scroll`, `drag`, `type_text`, `press_key`, `set_value` and `select_text`. If the app was captured again since, the call fails with `stale_state` and nothing is sent. Call `get_app_state` and retry with the new id.

`get_app_state` with `include_ax=false` returns no id and makes earlier ids stale. With `ULTRATERM_COMPUTER_USE_ACTION_READ_BACK=0` on macOS or Linux, actions return `ok` and no new id, so the old id stays valid. See [state ids](../../../docs/state-id.md).

## Background switches

By default the runtime works in the background. Two switches in the server environment relax that. Set them only when the user asks.

- `ULTRATERM_COMPUTER_USE_ALLOW_FOREGROUND=1` (macOS): the runtime may activate an app, raise a window, unminimize a window and unhide an app. Without it, a hidden or minimized app fails with `The app has no window that can be read in the background` and nothing is changed.
- `ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` (all platforms): the runtime may move the real pointer and send real keys.

On Linux, without the second switch these are refused with "Nothing was sent": coordinate clicks, `drag`, `click_method=global`, and keys (or `type_text` that cannot insert into a focused field) for a window that is not active. Prefer `element_index`. See [background operation](../../../docs/background-operation.md).

## Choosing Targets

- Prefer app names or bundle identifiers returned by `list_apps`.
- Run `get_app_state` immediately before element-targeted actions.
- Re-run `get_app_state` after navigation, modal changes, page reloads, or failed actions.
- Use coordinate actions only when the rendered tree does not expose the target as an element.
- On macOS, use `app.query` when you know the control's text or role. Bind with
  `await cua.getApp("Safari", { initialState: false })` to skip the initial snapshot.
  Query returns `{ matches, truncated, stop_reason, visited_nodes, window_id, limit, max_nodes }`.
  An empty result only means no matching exposed control was found when `truncated` is false.
  `exact: true` never retries substring matching. Query does not launch or activate the app.
- Query indexes last up to 120 seconds in the same native session (5000 retained handles).
  Separate CLI calls share these indexes through the app; `query` then `click --element-index <index>` works as two calls.
  Actions revalidate the process/window/control and current geometry. On failure, query again.
  See [targeted query](../../../docs/targeted-query.md) for options and examples.

## Choosing a Click Method

`click_method` is optional. Omitting it uses `auto`, which preserves the platform's existing semantic-first behavior. Explicit methods never fall back to a different implementation:

- `accessibility`: only invoke the element's accessibility action and require `element_index`.
- `app_post`: bypass accessibility and post a mouse event directly to the target app/window without moving the system pointer. Supported on macOS and Windows.
- `sky_click`: use the macOS private SkyLight background-window path with target-only synthetic focus and a Chromium primer click. It supports left single/double click on a current, on-screen window in the same Space and does not move the system pointer, deactivate the foreground app, change its key/first-responder state, or raise the target window. Its action-result snapshot refresh is read-only. Supported on macOS only.
- `global`: bypass accessibility and use the desktop's global pointer path. Supported on macOS, Windows and Linux, and requires `ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` because it may move the real pointer or change foreground focus.

Use `app_post` for an exact blank-area or overlay click that must not be redirected to an accessibility descendant:

```sh
ultraterm-computer-use call click --args '{"app":"Google Chrome","x":875,"y":375,"click_method":"app_post"}'
```

Use `sky_click` when Chromium ignores `app_post` and the current target window is covered by another window:

```sh
ultraterm-computer-use call get_app_state --args '{"app":"Google Chrome"}'
ultraterm-computer-use call click --args '{"app":"Google Chrome","x":875,"y":375,"click_method":"sky_click"}'
```

Run `get_app_state` again after the target window moves, closes, changes Space, becomes hidden, or is minimized. `sky_click` is an explicit private-SPI mode: unavailable symbols, a stale window id, unsupported button/count, or failed delivery return an error without falling back to another click implementation.

Use `global` only after explicitly enabling the process-level safety gate:

```sh
ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 ultraterm-computer-use call click --args '{"app":"Google Chrome","x":875,"y":375,"click_method":"global"}'
```

Keep the environment override scoped as narrowly as possible. While it remains enabled, the existing `auto` route may also choose the global pointer path after accessibility cannot handle a click.

Windows returns an unsupported error for `sky_click`; Linux returns an unsupported error for `app_post` and `sky_click`. An unsupported or failed explicit method does not fall back to `auto`.

## Choosing a Keyboard Method

`key_method` on `type_text` and `press_key` is optional. Omitting it uses `auto`, which keeps the existing accessibility-first typing and app-posted key events. Explicit methods never fall back:

- `sky_key`: use the macOS private SkyLight background-window path. It makes the current target window the key window inside its own app (without raising it, moving the pointer, switching Spaces, or deactivating the foreground app), delivers the keys, and releases that state again. Command chords such as `cmd+a`, `cmd+c` or `cmd+v` are performed through the target's own menu bar. Supported on macOS only.
- `global`: Windows press_key only. Requires `ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` and sends checked physical keys to the verified foreground target. Auto keys keep window-message delivery even when that flag is enabled. It does not apply to type_text.

Use `sky_key` when a Chromium or Electron window is covered by another window or lives on another Space and `auto` typing does not reach it:

```sh
ultraterm-computer-use call get_app_state --args '{"app":"Google Chrome"}'
ultraterm-computer-use call click --args '{"app":"Google Chrome","x":420,"y":260,"click_method":"sky_click"}'
ultraterm-computer-use call type_text --args '{"app":"Google Chrome","text":"hello","key_method":"sky_key"}'
ultraterm-computer-use call press_key --args '{"app":"Google Chrome","key":"cmd+a","key_method":"sky_key"}'
```

Covered windows and windows on other Spaces: `get_app_state` never activates or raises a window that is off-screen, and it pins the visibility of every window it captures while that window is unoccluded, so covering it or switching Spaces afterwards keeps Chromium/Electron content in the tree and screenshots live. If the tree ends with a note that the window is covered, the app had already hidden its content before the first snapshot. Either bring the window into view once and snapshot again, or park it on the agent's own invisible display:

```sh
ultraterm-computer-use call --calls '[
  {"tool":"get_app_state","args":{"app":"Google Chrome","window_placement":"agent_display"}},
  {"tool":"get_app_state","args":{"app":"Google Chrome","window_placement":"restore"}}
]'
```

Virtual displays are disabled by default. The host must explicitly set
`virtualDisplay.enabled=true` with `ultraterm-computer-use config`, or
`ULTRATERM_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED=true`, before using the examples above.
While disabled, MCP omits `window_placement`, JS guidance omits `windowPlacement`,
and stale `agent_display` calls fail before creating a display. The agent must not
enable this setting on the user's behalf without their request: it adds a system
monitor and can change the user's display arrangement. Existing `restore` and
turn/connection cleanup remain available when disabled.

`agent_display` moves the window's frame onto a virtual display the user never sees (macOS only): the app renders it, exposes its full tree and accepts `sky_click` / `sky_key`, while the user's Space, focus and pointer stay untouched. The window is gone from the user's desktop until `restore`, the assistant turn ends, the MCP/REPL connection closes, or the runtime exits, so treat it as a deliberate, temporary step. `restore` restores every window parked by the runtime for that app. Call `window_placement: restore` when done; the turn-ended hook and runtime exit also restore it. `sky_click` and `sky_key` accept covered and other-Space windows.

`sky_key` types into whatever element the target window has focused, so click or AX-focus the field first. It fails closed for hidden apps (`cmd+h`), stale window ids, and missing private symbols; Windows and Linux return an unsupported error.

## Drag Delivery

`drag` has no method parameter. On macOS the path it takes is decided by the same process-level gate that authorizes `click_method: "global"`:

- Gate unset (default): mouse move / down / dragged / up events are posted directly to the target process with `CGEvent.postToPid`. The system pointer does not move and foreground focus is unchanged. Because the events never pass through the window server, this path cannot start a window-server drag session: window moves, drag-selecting text, and Finder drag-and-drop return without error but have no visible effect.
- `ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` set for the server process: the drag uses the global pointer path, which drives window-server drag sessions but may move the real pointer and change foreground focus.

Every non-fixture `drag` result includes a text item that begins `Drag delivered via app_post` or `Drag delivered via global pointer path`, so a default drag that did nothing is legible instead of looking like success. The variable is read by the running Computer Use app, so set it where the user starts the app (or in an MCP server entry's `env`) and restart the app afterwards.

When the gate is not enabled, treat window-server drags as unavailable and reach the same outcome another way: copy or move files with a shell command instead of a Finder drag, use `set_value` or keyboard selection instead of drag-selecting text, and use the app's own window controls instead of dragging a title bar.

## Text Selection (macOS)

Use `await app.selectText(elementIndex, text, options?)` with a snapshot or `query`
index from the current session. The native CLI/MCP tool is `select_text`.

| Argument | Meaning |
| --- | --- |
| `elementIndex` | The text element's current index. |
| `text` | Exact target text, including whitespace and Unicode spelling. |
| `options.prefix` / `options.suffix` | Text immediately before / after the target, for repeated matches. |
| `options.selection` | `text` (default), `cursor_before` or `cursor_after`. |

Ambiguous or missing text, unsupported selection, text changes and unverified ranges
return errors. The action verifies the applied UTF-16 range even when full action
read-back is off; use `getAXState()` for the next UI observation. It does not activate
the app or fall back to keyboard/pointer input. Linux and Windows do not implement
`select_text` yet.

## Software Cursor

The software cursor keeps a window-relative anchor for its target point. During travel, settle, click
feedback and idle, it follows changes to the target window's frame. If the window moves during travel,
the visible tip lands at the new position immediately, without continuing toward the old position.

Window frames are read on a background worker at up to 30 Hz, with at most one read in flight. Rendering
uses the latest cached frame, so a slow Accessibility response does not block the cursor. The snapshot's
AX window element is preferred; `CGWindowListCopyWindowInfo` is used only when no AX element is available,
because it can report an old origin after a move. A failed read keeps the last usable frame. Tracking is
released when the cursor is cleared or its idle timeout expires.

This follows the window's position, not layout changes inside it. Refresh app state after a layout change
before choosing another target. Input delivery continues to use the existing action paths.

## Platform Notes

### macOS

The macOS runtime uses Accessibility, ScreenCaptureKit, app-posted input events, and explicit private-SkyLight `sky_click` / `sky_key` routes. It normally avoids moving the user's real pointer. The visual cursor overlay is a drawn window, never the real pointer. A move takes at most 0.18 seconds by default (`ULTRATERM_COMPUTER_USE_VISUAL_CURSOR_MOVE_DURATION`, in seconds), and `ULTRATERM_COMPUTER_USE_VISUAL_CURSOR=0` turns it off. The runtime never activates an app, raises a window or unhides an app unless `ULTRATERM_COMPUTER_USE_ALLOW_FOREGROUND=1` is set. Private SkyLight symbols and raw event fields are not API-stable; re-validate `sky_click` after macOS upgrades.

### Windows

The Windows runtime uses UI Automation and Win32 message fallbacks. It must run in a logged-in desktop session. A detached SSH or service context may start the CLI but fail to see top-level windows.

With `ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1`, Windows also supports
explicit global clicks, auto click/scroll fallbacks and physical drags. Real
keyboard input additionally requires an explicit call such as
`await app.pressKey("ctrl+a", {keyMethod:"global"})`; auto key delivery stays on
window messages. Explicit app_post/accessibility clicks keep their selected path.
Global input can move the pointer and activate the target. Stale window geometry,
occluded points and foreground failures are refused; observe again or make the
target visible. The runtime does not synthesize Alt to force activation.


### Linux

The Linux runtime uses AT-SPI2 through the desktop session bus. It must run in a logged-in graphical session with usable accessibility services. Wayland screenshot and coordinate input support is compositor-dependent and best-effort. Coordinate clicks, drags and keys for a window that is not active are refused unless `ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1`. A click on a field with no click action focuses it through accessibility.

## Optional: MCP server and JavaScript mode

The CLI above covers every tool, so use it by default. The MCP server is kept for hosts that can only use MCP tools:

```json
{
  "mcpServers": {
    "ultraterm-computer-use": { "command": "ultraterm-computer-use", "args": ["mcp"] }
  }
}
```

It serves the same tools as the CLI over stdio, with the state held for the session. `ultraterm-computer-use help mcp` has the details; the Codex plugin ships it as an opt-in file (see the README).

The npm launcher also has a code-first JavaScript mode (`ultraterm-computer-use js`, `repl`, `capabilities`) that binds an app once and composes actions in one session:

```js
var app = await cua.getApp("TextEdit");
await app.typeText("Hello");
await app.getAXState();
```

### Selective observation (opt-in)

The native `get_app_state` tool on macOS, Windows and Linux accepts `include_ax` and
`include_screenshot`. Both default to `true`; at least one must remain true.
The REPL forwards the corresponding optional `includeAX` / `includeScreenshot`
booleans:

```js
var editor = await cua.getApp("gedit", { initialState: false });
await editor.getScreenshot({ includeAX: false }); // no AX, focus or selection walk
await editor.click([100, 100]);                   // window-relative coordinates
await editor.getAXState({ includeScreenshot: false }); // no capture or PNG encoding
// Use newly observed element indexes only after inspecting the AX result.
```

Screenshot-only observation invalidates prior element indexes and cached query
aliases for that app, even if the window title is unchanged. Its result explicitly
reports this. Coordinate actions use the newly observed window bounds; element
actions require a fresh AX observation. Existing calls without these options keep
their full native observation behavior. These flags are implemented on all three native platforms; action read-back is unchanged.

These options select collection, not image deduplication. An unchanged screenshot
is still returned when requested. macOS/Linux JS actions already disable automatic
read-back, and getAXState does not emit images; includeScreenshot:false additionally skips
native capture on all three platforms. See `docs/selective-observation.md` for real GTK
and Worker JS validation.

The code-first surface also forwards macOS background-operation options:

```js
var chrome = await cua.getApp("Google Chrome");
await chrome.getAXState({ windowPlacement: "agent_display" });
await chrome.typeText("hello", { keyMethod: "sky_key" });
await chrome.pressKey("cmd+a", { keyMethod: "sky_key" });
await chrome.getAXState({ windowPlacement: "restore" });
```

Bindings persist across `js` calls until `js_reset`. Run
`ultraterm-computer-use help js` for the full API.

The npm CLI can use the same code-first runtime without an MCP host:

```sh
ultraterm-computer-use capabilities
ultraterm-computer-use js 'var apps = await cua.listApps({ emit: false }); nodeRepl.write(apps)'
printf '%s' 'nodeRepl.write(6 * 7)' | ultraterm-computer-use js -
ultraterm-computer-use js --file ./automation.mjs
ultraterm-computer-use repl
```

`ultraterm-computer-use js` owns one short-lived Worker/native MCP session. `ultraterm-computer-use repl` keeps the
session and top-level bindings for the current terminal until `.exit`, Ctrl-D,
or termination; `.editor` / `.end` accepts multiline input and `.reset`
discards JavaScript bindings. Use `nodeRepl.write(value)` for explicit output.
The native `ultraterm-computer-use mcp` surface exposes the same tools as `call` (`query` and `select_text` on macOS only). Run
`ultraterm-computer-use capabilities --json` to inspect component availability instead of
inferring support from a command being present in help.

## Safety

Pause and ask the user before actions that affect external systems or sensitive local state, including sending messages, submitting forms, deleting files, approving prompts, uploading files, or interacting with password managers.

## Persisted screenshot settings

Use `ultraterm-computer-use config` to inspect effective values and their sources. `ultraterm-computer-use config set image.format jpg` or `ultraterm-computer-use config set image.maxLongEdgePixels 1024` persists macOS screenshot preferences in the user config file. ENV overrides take precedence; `ultraterm-computer-use config reset KEY` removes a saved preference. Windows/Linux screenshot behavior is unchanged.

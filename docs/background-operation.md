# Background operation

## The rule

UltraTerm Computer Use works in the background. It does not disturb the person using the computer unless they opt in.

By default it does not move the real pointer. It does not take keyboard focus. It does not bring an app or a window to the front.

Each way of breaking that rule is behind a switch. The switch is an environment variable in the server process. The tool arguments cannot turn it on.

| Switch | Platforms | What it allows |
| --- | --- | --- |
| `ULTRATERM_COMPUTER_USE_ALLOW_FOREGROUND=1` | macOS | Activate an app, raise a window, unminimize a window, unhide an app. |
| `ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` | macOS, Linux, Windows | Move the real pointer and send real keys. |

Both switches accept `1`, `true`, `yes` or `on`. Anything else leaves them off.

On Windows two older switches also exist. `ULTRATERM_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH=1` lets the runtime start an app. `ULTRATERM_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1` allows the `SetFocus` secondary action.

## macOS

| Tool | Default | Refused or limited | Switch |
| --- | --- | --- | --- |
| `list_apps` | Reads the list of apps. | Nothing. | None. |
| `get_app_state` | Reads the accessibility tree and a window capture. Covered windows and windows on other Spaces can be read, and so can a hidden app when it still exposes its window. | When no window can be read (a minimized window, an app with no open window, some hidden apps) it fails with "The app has no window that can be read in the background". Nothing is changed. | `ALLOW_FOREGROUND=1` lets it unhide, unminimize and raise the app, then read it. |
| `query` | Reads the accessibility tree. | Same as `get_app_state`. | `ALLOW_FOREGROUND=1`. |
| `click` with `element_index` (auto) | Tries accessibility actions on the element, its children and the element under it. If none works, posts mouse events to the app process. The real pointer does not move. | A disabled control is refused. A window or sheet index is not raised. The click goes on to the posted mouse events. | `ALLOW_FOREGROUND=1` allows raise, main and focus on that window. `ALLOW_GLOBAL_POINTER_FALLBACKS=1` sends the click through the real pointer after raising the window and activating the app. |
| `click` with `x` and `y` (auto) | Looks for an accessibility element at the point. Otherwise posts mouse events to the app process. | Nothing is sent through the real pointer. | `ALLOW_GLOBAL_POINTER_FALLBACKS=1`. |
| `click_method=accessibility` | Runs accessibility actions only. | Needs `element_index`. Fails if no action works. | `ALLOW_FOREGROUND=1` for the window raise path. |
| `click_method=app_post` | Posts mouse events to the app process. | None extra. | None. |
| `click_method=sky_click` | Delivers a left click or double click to a window without making the app active. | Refused for other buttons or more than two clicks. Refused if the app is hidden or the window is gone. | None. |
| `click_method=global` | Not available by default. | Refused with a message that names the switch. | `ALLOW_GLOBAL_POINTER_FALLBACKS=1`. It raises the window and activates the app first. |
| `perform_secondary_action` | Runs an accessibility action the element offers. | `Raise` is refused, because it brings a window forward. Fails if the element does not offer the action. A disabled control is refused. | `ALLOW_FOREGROUND=1` allows `Raise`. |
| `scroll` | Runs the element's scroll-by-page action when it has one. Otherwise posts a scroll event to the app process. | Nothing is sent through the real pointer. | `ALLOW_GLOBAL_POINTER_FALLBACKS=1` scrolls with the real pointer after raising the window and activating the app. |
| `drag` | Posts the drag events to the app process. The result says so. This cannot drive window moves, text selection by drag, or Finder drag and drop. | The real pointer is not used. | `ALLOW_GLOBAL_POINTER_FALLBACKS=1` drags with the real pointer after raising the window and activating the app. |
| `type_text` | Inserts the text through accessibility into the focused field. If that is not possible, posts key events to the app process. | Fails when the focused element is not an editable text element. | None. |
| `type_text` with `key_method=sky_key` | Delivers keys to a window without making the app active. | The window must still exist and belong to the app. | None. |
| `press_key` | Posts key events to the app process. | None extra. | None. |
| `press_key` with `key_method=sky_key` | Same as `type_text` with `sky_key`. A command key chord is run as a menu item. | Same as above. | None. |
| `set_value` | Writes the value through accessibility and reads it back. | Fails on a control that is not settable. A password field is written but not read back. | None. |
| `select_text` | Selects text through accessibility. | Fails if the text is not found. | None. |

Launching an app: when the requested app is not running, the runtime opens it. The launch asks not to activate the app. Without `ALLOW_FOREGROUND=1` it does not take the keyboard.

The `sky_key` path starts a short key-window state inside the target app. The app that is in front keeps its active state. The window is not raised. The pointer does not move.

## Linux

| Tool | Default | Refused or limited | Switch |
| --- | --- | --- | --- |
| `list_apps`, `get_app_state` | Reads through AT-SPI. | Nothing. | None. |
| `click` with `element_index` (auto) | Runs the element's accessibility action. If the element has none, focuses it through accessibility. | A GTK 3 text field is not clicked through its `activate` action, because that action submits the field. A multi-click or non-left click on an element with no action needs the real pointer. | `ALLOW_GLOBAL_POINTER_FALLBACKS=1`. |
| `click` with `x` and `y` | Not available by default. | Refused with "Nothing was sent". | `ALLOW_GLOBAL_POINTER_FALLBACKS=1`. |
| `click_method=accessibility` | Runs the accessibility action. | Needs `element_index`. | None. |
| `click_method=global` | Not available by default. | Refused. | `ALLOW_GLOBAL_POINTER_FALLBACKS=1`. |
| `click_method=app_post`, `sky_click` | Not supported. | Return an error. | None. |
| `perform_secondary_action` | Runs an accessibility action. | Fails if the action is not offered. | None. |
| `scroll` | Sends a Page Up, Page Down, Left or Right key. | Keys go to the focused window, so it is refused unless the target window is active. | `ALLOW_GLOBAL_POINTER_FALLBACKS=1`. |
| `drag` | Not available by default. | Refused. | `ALLOW_GLOBAL_POINTER_FALLBACKS=1`. |
| `type_text` | Inserts at the caret in the focused editable field only. Whitespace and newlines are kept. | If there is no such field, the text would be sent as keys. That is refused unless the target window is active. | `ALLOW_GLOBAL_POINTER_FALLBACKS=1`. |
| `press_key` | A plain Return on a focused GTK 3 text field runs its `activate` action. | Any other key goes to the focused window, so it is refused unless the target window is active. Unknown modifiers are rejected. Locked modifiers are always released. | `ALLOW_GLOBAL_POINTER_FALLBACKS=1`. |
| `set_value` | Writes through accessibility and reads it back. | A read-only field is refused. | None. |

`ALLOW_FOREGROUND` has no effect on Linux.

## Windows

| Tool | Default | Refused or limited | Switch |
| --- | --- | --- | --- |
| `list_apps`, `get_app_state` | Reads through UI Automation. A covered window is captured with `PrintWindow`. | Hidden, minimized or cloaked windows may return only the tree. | None. |
| `click` (auto) | Uses UI Automation patterns on the element. Otherwise posts window messages to the window. | A posted click to a hosted app frame is refused. | `ALLOW_GLOBAL_POINTER_FALLBACKS=1` uses the real pointer for the fallback click. |
| `click_method=app_post` | Posts window messages. | Same as above. | None. |
| `click_method=global` | Not available by default. | Refused with a message that names the switch. | `ALLOW_GLOBAL_POINTER_FALLBACKS=1`. Tries to bring the window to the front, and refuses if it does not become the foreground window. |
| `perform_secondary_action` | Runs a UI Automation action. | `SetFocus` is refused. | `ULTRATERM_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1`. |
| `scroll` | Uses the scroll pattern, or posts a wheel message. | A hosted app frame without a scroll pattern is refused. | `ALLOW_GLOBAL_POINTER_FALLBACKS=1` scrolls with the real pointer. |
| `drag` | Posts mouse messages to the window. | Needs usable window bounds. A minimized or off-screen window is refused. | `ALLOW_GLOBAL_POINTER_FALLBACKS=1` drags with the real pointer. |
| `type_text` | Sends the literal text to the edit control that has keyboard focus, as a window message. | A read-only field, a focused control that is not a text field, and a hosted app frame are refused. The UI Automation text fallback is off. | `ULTRATERM_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK=1`. |
| `press_key` | Posts the key as a window message to the control that has keyboard focus. | A key combination is refused, because window messages cannot carry modifier keys. | `key_method=global` together with `ALLOW_GLOBAL_POINTER_FALLBACKS=1`. |
| `set_value` | Writes through the value pattern and reads it back. | A control that is not settable is refused. | None. |

Before every action tool the Windows runtime also checks the target. It refuses a window that is hung, so that input does not wait in its queue. It refuses an app that runs at a higher integrity level (elevated), because the input would be blocked. It refuses a window that changed since the last `get_app_state`. Nothing is sent in these cases.

Windows has no visual cursor. The Windows runtime does not start an app unless `ULTRATERM_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH=1` is set.

## Visual cursor

On macOS the runtime draws a cursor overlay on screen while it acts. It is a drawn window. It is never the real pointer. It does not take input.

`ULTRATERM_COMPUTER_USE_VISUAL_CURSOR=0` turns it off. `false`, `no` and `off` also work.

A move takes at most 0.18 seconds by default. `ULTRATERM_COMPUTER_USE_VISUAL_CURSOR_MOVE_DURATION` sets it in seconds. The value is limited to 0 to 2. `0` jumps to the target. The idle animation runs at 20 Hz.

Linux and Windows have no overlay.

## What can still be visible

- The overlay cursor on macOS, unless it is turned off.
- A window of an app that was launched for the task. It appears, but without focus.
- Changes the app itself makes in response to the action, such as a dialog opening.
- With a switch on: the real pointer moving, a window being raised, and keys going to the front window.

See also [state ids](state-id.md) and [reliability](RELIABILITY.md).

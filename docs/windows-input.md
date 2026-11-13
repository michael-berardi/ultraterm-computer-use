# Windows input

By default, it uses UI Automation and window messages. The scroll fallback keeps the window bounds and passes screen coordinates as required by wheel messages. The DPI bridge uses physical pixels. To use real mouse or keyboard input, set the following in the environment of the process that starts UltraTerm Computer Use:

```powershell
$env:ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS="1"
```

| Call | Default | After enabling the environment switch |
| --- | --- | --- |
| `app.click(index)` / `auto` | UIA first, then window messages | UIA first, then real pointer |
| `app.click([x,y], {clickMethod:"global"})` | Refused | Real pointer |
| `clickMethod:"app_post"` / `"accessibility"` | The delivery path specified | Keeps the specified path |
| `app.drag(...)` | Window messages | Real pointer |
| `app.scroll(index, direction, pages)` | ScrollPattern first, then window messages | ScrollPattern first, then real pointer |
| `app.pressKey(key)` | Window messages (key combinations refused) | Window messages (key combinations refused) |
| `app.pressKey(key, {keyMethod:"global"})` | Refused | Real key press |

The native MCP / CLI parameters are `click_method` and `key_method`. `type_text` has no global method. `sky_click` / `sky_key` are macOS features.

Keys and characters sent as window messages go to the control in the target window's thread that has keyboard focus and lies inside the target window (`GetGUIThreadInfo`). If the thread reports no such control, they go to the window itself, as before. Applications read Ctrl / Shift / Alt from the keyboard state, and posting a message does not change the keyboard state. So a combination such as `ctrl+a` sent as a window message arrives as a plain `a`. The auto method refuses it directly. When a combination is needed, use `key_method=global`. `type_text` first writes to the focused Edit / RichEdit control (refused if it is read-only). If the focus is unknown, only a single text box in the window is selected. If there are several, it is refused and does not write to the first one.

Real input moves the system pointer and may bring the target to the foreground. Before sending, check the observed process / window, current geometry, foreground window and that the coordinates hit the window. Physical input by index also checks the UIA runtime ID and the current element position, and refuses an element that has disappeared, been replaced or moved. An error is returned when the window moves, is covered by another window, or cannot be brought to the foreground. In that case, observe again or make the target visible. It does not simulate Alt to force the foreground, and it does not switch to real input when a specified app_post / accessibility delivery fails.

Keyboard and mouse input use SendInput, and the code checks whether the events were inserted. Real mouse input supports left, middle and right buttons and 1–3 clicks, and refuses invalid buttons and click counts that are too large. Key combinations are fully validated before anything is pressed. If an error occurs, the keys or buttons pressed by this call are released. When the target process runs as administrator with a higher integrity level than UltraTerm Computer Use, Windows (UIPI) drops the window messages and SendInput sent to it. SendInput does not report whether UIPI blocked it, so all actions are refused before sending. The read-only `get_app_state` is not affected. Input is also refused when the integrity level cannot be read. Forced process termination also cannot guarantee that `finally` blocks run.

## Verification

```powershell
go -C apps/UltraTermComputerUseWindows test ./...
go -C apps/UltraTermComputerUseWindows build -o "$env:TEMP/utcu-input.exe" .
powershell.exe -NoProfile -File scripts/tests/windows-input.test.ps1 -RuntimePath apps/UltraTermComputerUseWindows/runtime.ps1
pwsh -File scripts/tests/windows-input-smoke.ps1 -NativePath "$env:TEMP/utcu-input.exe"
```

The desktop tests need a signed-in Windows session, Windows PowerShell, pwsh and Node.js. They only operate on their own temporary windows. They verify the default window-message scroll fallback, four-direction wheel, screenshot-coordinate click, drag, key combinations, input release, move / occlusion refusal, capture at the right side of the screen, and Worker JS. The fixture customizes WM_MOUSEWHEEL / WM_MOUSEHWHEEL handling and updates the real ScrollViewer offset. The result is confirmed by a separate state file. It does not mean that all GUI toolkits respond to window messages.

The script records the actual window DPI and compares the screenshot size with an independent physical window rectangle. A pass at normal DPI does not replace testing at 125% / 150% or on multiple monitors. The existing normal, 1×1, minimized and cloaked screenshot checks are also run.

Implementation references: [wheel message screen coordinates](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousewheel), [horizontal wheel direction](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousehwheel), [SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput), [SetForegroundWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow), [thread DPI context](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setthreaddpiawarenesscontext).

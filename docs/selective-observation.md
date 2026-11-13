# On-demand observation

`get_app_state` on macOS, Windows and Linux can read AX, a screenshot, or both. The native parameters `include_ax` / `include_screenshot` map to the JS options `includeAX` / `includeScreenshot`. Both default to `true`, and they cannot both be set to `false`.

| Need | JS call | What is collected |
| --- | --- | --- |
| Only controls and selection | `await app.getAXState({includeScreenshot: false})` | AX, focus, selection; no screenshot, no encoding |
| Only the picture | `await app.getScreenshot({includeAX: false})` | Screenshot; no AX traversal, no focus or selection lookup |
| Both | `await app.getAXStateAndScreenshot()` | Full AX and screenshot |

```js
var app = await cua.getApp("gedit", {initialState: false});
await app.getAXState({includeScreenshot: false});
```

After taking only a screenshot, old element indexes and query aliases become invalid, including indexes from before an app restart. Coordinate actions can still use the window position from this observation. Element actions must read AX again first. A matching window title does not mean an old index is still valid.

Calls with no arguments keep the original behavior. After AX only, element actions can continue, but screenshot-coordinate clicks and drags require a new screenshot first. After a screenshot only, element indexes require a new AX read. On macOS, query indexes are also invalidated by a screenshot-only observation.

## CLI and MCP

The JS `ultraterm-computer-use js` / `ultraterm-computer-use repl` and the MCP `js` tool use the calls above. When calling the native CLI / MCP directly, use snake_case:

```sh
ultraterm-computer-use call get_app_state --args '{"app":"TextEdit","include_screenshot":false}'
ultraterm-computer-use snapshot --include-screenshot false TextEdit
ultraterm-computer-use snapshot --include-ax false TextEdit
```

The native MCP `get_app_state` accepts the same `include_ax` / `include_screenshot` booleans. `snapshot` accepts `true` / `false` for both, but not both disabled. `snapshot` always prints text only. Use JS or `call` / MCP when you need image content.

These two options only control this explicit observation. They do not change action read-back.

## Relation to repeated screenshots

On macOS and Linux, JS actions already have automatic read-back turned off by default. `getAXState()` itself does not return an image to the model, but by default it still captures the image in the native layer and discards it. `includeScreenshot: false` skips this capture and encoding on all three platforms. When using the native MCP directly, it also omits the returned image block.

No screenshot comparison is done here. If a screenshot is requested, it is returned even when the picture is unchanged. Omitting the image when the screen has not changed needs a separate implementation. It usually still takes a screenshot first and then compares, mainly reducing transfer and model input. A later version could store exact image fingerprints per session, app and window, return an image on the first observation and after state resets, and offer a way to force an image. Unchanged AX alone must not be taken as proof that the screen is unchanged.

## Tests

```sh
swift test
python3 apps/UltraTermComputerUseLinux/runtime_test.py
(cd apps/UltraTermComputerUseLinux && go test ./...)
(cd apps/UltraTermComputerUseWindows && go test ./...)
node --test scripts/node-repl/*.test.mjs
```

The real GTK tests reuse the [private D-Bus / Xvfb environment](linux-action-read-back.md) and also need Node.js:

```sh
(cd apps/UltraTermComputerUseLinux && go build -o /tmp/utcu-observation-test .)
bash scripts/run-linux-read-back-smoke.sh /tmp/utcu-observation-test --observation-checks
```

The script wraps the real production capture functions and confirms that disabled channels are not called. It then checks PNG output, selection, rejection of old indexes, coordinate actions and AX recovery through the native MCP and Worker JS. A standalone GTK export confirms action results. This is an X11 / GTK / AT-SPI test. It does not cover Wayland or full-task performance.

On macOS, use a normally signed, authorized UltraTerm Computer Use executable to verify real AppKit windows. No admission configuration changes are needed:

```sh
node scripts/tests/macos-observation-smoke.mjs "/path/to/UltraTerm Computer Use.app/Contents/MacOS/UltraTermComputerUse"
```

It verifies the three capture modes, PNG output, snapshot and query index invalidation, coordinate rejection and element recovery through real AX, native MCP, CLI and Worker JS. It uses the existing timing logs to confirm that skipped capture branches did not run. The window is not allowed to become the key or main window. The script does not send input to personal apps.

The Windows PowerShell capture branch can be verified on its own with this command:

```powershell
pwsh -NoProfile -File scripts/tests/windows-observation.test.ps1 -RuntimePath apps/UltraTermComputerUseWindows/runtime.ps1
```

This test parses the production script, runs its observation functions, and uses counting UIA / screenshot dependencies to verify the branches. It is not a test on a real Windows desktop.

The Windows desktop test needs a signed-in interactive session, Windows PowerShell and Node.js:

```powershell
go -C apps/UltraTermComputerUseWindows build -o "$env:TEMP/utcu-observation.exe" .
pwsh -File scripts/tests/windows-observation-smoke.ps1 -NativePath "$env:TEMP/utcu-observation.exe"
```

The script creates its own WPF window. Through real UIA, native MCP, CLI and Worker JS, it checks channel selection, rejection of old indexes, AX recovery, Unicode value setting and rejection of screenshot coordinates. It then uses a small Win32 window in the same process to verify the physical 1×1 boundary. It checks that minimized and cloaked WPF windows return no image, and that PNG is returned again after restore. A pass on WPF does not mean all WinForms / WinUI / Electron controls support the same UIA pattern.

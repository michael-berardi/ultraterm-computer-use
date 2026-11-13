# Reliability and Operability

## Current minimum verification baseline

- Build: `swift build`
- Unit tests: `swift test`
- JS REPL and CLI: `node --test scripts/node-repl/*.test.mjs`
- End-to-end smoke: `./scripts/run-tool-smoke-tests.sh`
- macOS SkyLight live regression: `ULTRATERM_COMPUTER_USE_RUN_SKY_CLICK_LIVE_TEST=1 swift test --filter SkyClickLiveTests`
- macOS SkyLight background keyboard live regression: `ULTRATERM_COMPUTER_USE_RUN_SKY_KEY_LIVE_TEST=1 swift test --filter SkyKeyboardLiveTests`
- macOS occluded-window keep-alive live regression: `ULTRATERM_COMPUTER_USE_RUN_OCCLUSION_LIVE_TEST=1 swift test --filter OcclusionKeepAliveLiveTests`
- macOS multi-app scan (runs a read-only snapshot of every running GUI app and types then deletes a marker in an empty text field. It sends input to real apps, so run it only when nobody is using the machine): `ULTRATERM_COMPUTER_USE_RUN_APP_MATRIX=1 swift test --filter AppMatrixLiveTests`. Adding `ULTRATERM_COMPUTER_USE_APP_MATRIX_PARK=1` parks each non-fullscreen window on the agent display, does the same thing, and then moves it back to its original position.
- macOS background input benchmark (25 rounds of `sky_click` + `sky_key`, prints the success count and p50 / p95 / max): `ULTRATERM_COMPUTER_USE_RUN_BACKGROUND_BENCH=1 ULTRATERM_COMPUTER_USE_BENCH_CYCLES=25 swift test --filter BackgroundInputBenchmarkLiveTests`
- Input defaults favor reliability across versions. The type chunk and press-key settle for normal `auto` stay at 20 / 100 ms, and the key-window and release settle for `sky_key` are 10 / 10 ms. All six timing knobs can be overridden explicitly with the matching `ULTRATERM_COMPUTER_USE_*` environment variables.
- Per-stage timing: prefix any command with `ULTRATERM_COMPUTER_USE_DEBUG_TIMING=1`. stderr prints `[ultraterm-computer-use] timing <stage> <ms>ms` (`sky_key.*`, `sky_click.total`, `snapshot.window_capture`, `snapshot.tree_walk`, `agent_display.*`).
- Do not type on or click with the mouse on this Mac while running live regressions. The live tests that need the foreground briefly bring the target window forward, so the user's keystrokes would land in it, and the foreground fixture would lose active state because of the user's actions.
- macOS agent display live regression (briefly creates and destroys a virtual display): `ULTRATERM_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED=true ULTRATERM_COMPUTER_USE_RUN_AGENT_DISPLAY_LIVE_TEST=1 swift test --filter AgentDisplayLiveTests`
- macOS other Desktop live regression (requires a second Desktop; the test briefly switches Spaces to launch the target): `ULTRATERM_COMPUTER_USE_RUN_CROSS_SPACE_LIVE_TEST=1 swift test --filter CrossSpaceLiveTests`
- Linux runtime: `(cd apps/UltraTermComputerUseLinux && go test ./...)`, `./scripts/build-ultraterm-computer-use-linux.sh --arch arm64`
- Linux hidden-control live test: `bash scripts/run-linux-read-back-smoke.sh /path/to/linux/ultraterm-computer-use --hidden-checks`. It verifies real GTK hidden state, attribute reads, indexes and page switching in a private D-Bus / Xvfb session. Dependencies and scope are in [test notes](linux-hidden-details.md).
- Linux on-demand observation live test: `bash scripts/run-linux-read-back-smoke.sh /path/to/linux/ultraterm-computer-use --observation-checks`. It verifies the real GTK capture channel, native MCP and Worker JS output, and the rejection and recovery of old indexes. It also requires Node.js. See [test notes](selective-observation.md).
- Windows runtime: `(cd apps/UltraTermComputerUseWindows && go test ./...)`, `./scripts/build-ultraterm-computer-use-windows.sh --arch amd64`. Changes related to screenshots must also be verified on an interactive Windows desktop: normal windows must have an image, and 1x1, minimized or cloaked windows must have no image.
- Windows input live test: `pwsh -File scripts/tests/windows-input-smoke.ps1 -NativePath /path/to/ultraterm-computer-use.exe`. It verifies the real default scroll fallback, four-direction physical wheel, click at screenshot coordinates, drag, key combinations, move and occlusion rejection, and Worker JS. Record the actual DPI. See [notes](windows-input.md).
- Windows observation live test: `pwsh -File scripts/tests/windows-observation-smoke.ps1 -NativePath /path/to/ultraterm-computer-use.exe`. It uses a separate WPF window through the real UIA / native MCP path to verify the capture switch, indexes and screenshot boundaries.
- Local diagnostics:
  - `ultraterm-computer-use doctor`
  - `ultraterm-computer-use snapshot <app>`

## Background operation

- By default the runtime never takes the screen or the keyboard from the person using the computer. The rules and the switches are in [background operation](background-operation.md).

- Calls from one `call --calls` run wait 0.2 seconds between successful steps. `--sleep <seconds>` changes it.

- A visual cursor move takes at most 0.18 seconds by default. Set `ULTRATERM_COMPUTER_USE_VISUAL_CURSOR_MOVE_DURATION` to change it, or `ULTRATERM_COMPUTER_USE_VISUAL_CURSOR=0` to turn the overlay off.

- `state_id` protects an action from acting on an out-of-date view of the app. See [state ids](state-id.md).

## Known critical dependencies

- On macOS, `UltraTerm Computer Use.app` must be granted `Accessibility` and `Screen Recording`. The terminal itself should no longer be a required grantee.
- The Codex plugin's code-first surface requires an executable `node`. The REPL adapter keeps a separate child lifecycle for native MCP, while the JavaScript kernel runs in a Worker. A script timeout discards all bindings of that Worker, and the next call uses a new kernel.
- The npm CLI itself is also started by Node. `ultraterm-computer-use js` keeps the Worker and native MCP children only for the duration of one execution. `ultraterm-computer-use repl` keeps them for the current terminal session. `ultraterm-computer-use mcp` follows the stdio connection. The macOS hidden app agent is a separate permission identity and may stay resident after these foreground commands exit.
- `ultraterm-computer-use --help` always shows `js` / `repl`. `ultraterm-computer-use capabilities --json` checks Node, the adapter, the kernel and the native artifact without starting native MCP. The current npm shebang still requires the shell to start Node from PATH, so "no Node at all" must be solved in an outer layer with a native bootstrap.
- macOS `click_method=sky_click` additionally depends on the SkyLight / ApplicationServices private symbols `SLEventPostToPid`, `SLEventSetIntegerValueField`, `CGEventSetWindowLocation`, `SLPSPostEventRecordTo` and `GetProcessForPID`. The main screenshot path depends on the optional `SLSHWCaptureWindowList`, and window binding depends on the optional `_AXUIElementGetWindow`. When they are missing, the runtime falls back to ScreenCaptureKit and a title heuristic, respectively. The runtime probes these dynamically and fails closed, but changes in macOS updates, signing, or the target app's input policy can still break background delivery. A controlled live regression must verify, besides the DOM, the foreground PID, the mouse and the z-order, the foreground AppKit active state, the key window, the first responder, and the resign and key-loss counts. `key_method=sky_key` reuses the same symbols. The live regression must also confirm that a text field in an occluded Chrome window receives text, that the `cmd+a` menu shortcut takes effect, and that the Chrome page blurs again after delivery ends.
- The agent display depends on the private `CGVirtualDisplay` class, KVC keys and selectors. The shim catches Objective-C exceptions and turns a creation failure into capability unavailable. Private API drift must not terminate the host process. An explicit `restore` restores all windows the runtime parked for that app PID. Turn-ended and MCP/REPL connection close also release the occlusion keep-alive, restore windows and destroy idle displays.
- The smoke suite depends on a local GUI session. Do not treat it as a headless environment command.
- The `get_app_state` result for ordinary apps depends on the AX tree and window screenshots, and output differs on complex apps. Electron and WebView app AX trees are usually deep, so the runtime currently compresses empty wrappers and relaxes the traversal depth to keep actionable text, buttons and input fields first.
- The Linux runtime depends on a logged-in desktop user session. When `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS` or the display environment is missing, it tries to discover the current user's session environment from `/run/user/<uid>` and common desktop processes. A pure SSH tty still cannot access the AT-SPI GUI tree directly if no desktop session is found.
- GNOME Wayland screenshots may be restricted by the compositor. The current Linux bridge treats a black image as an invalid screenshot and omits the image block.

## Current troubleshooting order

1. Run `ultraterm-computer-use doctor` first to confirm the permission status. If permissions are missing, the command opens the permission onboarding window through the `.app` app agent. If all permissions are granted, it only prints the status and exits.
2. Run `ultraterm-computer-use list-apps` to confirm the target app is discovered.
3. Run `ultraterm-computer-use snapshot <app>` to tell whether the problem is in the transport or in the snapshot / action.
4. If `sky_key` input does not reach the target, first confirm the window still belongs to the same PID.

   For Chromium targets, you can observe `document.hasFocus()` in the page. It should be true during delivery.

   Do not type in other windows during live regressions, or the foreground fixture will lose active state because of the user's own actions.
5. If the tree of an occluded or other-Space Chromium / Electron window has no web content, check whether the end of the tree contains a "window is covered" note. That means the window was already occluded the first time the agent saw it. Bring the window into view once and call `get_app_state` again; later occlusion will then keep the content. Alternatively, in the same session, call `get_app_state` explicitly with `window_placement=agent_display` to park the window on the agent display, and use `restore` when finished. If the session has already ended, the runtime restores the window automatically, and no extra `restore` connection is needed.
6. If only `sky_click` fails, first run `get_app_state` again to confirm the window still belongs to the same process. `sky_click` refuses a hidden app and does not unhide it.

   If the error contains `missing SkyLight symbols`, do not switch to an implicit fallback. Re-verify the private SPI for the current macOS version.

   If an occluded Chromium page still shows no effect, use a controlled page to tell a renderer policy change apart from a coordinate or window-local mapping problem.
7. If `get_app_state` fails with `The app has no window that can be read in the background`, the app is hidden, minimized or has no open window. Nothing was changed. Show the window yourself, or set `ULTRATERM_COMPUTER_USE_ALLOW_FOREGROUND=1` in the server environment to let the runtime unhide, unminimize and raise it. See [background operation](background-operation.md).
8. If an action fails with `stale_state`, the app was captured again after the `state_id` was issued. Nothing was sent. Call `get_app_state` and retry with the new id. See [state ids](state-id.md).
9. If you only want to verify the repository baseline, run the fixture and smoke tests directly. Do not start troubleshooting on complex third-party apps.
10. When troubleshooting the Linux runtime, first confirm the target command is run by the desktop user. Then use `ultraterm-computer-use call list_apps` and `ultraterm-computer-use snapshot <app>` to separate session or environment problems from AT-SPI tree or action problems. If it is Codex MCP, run `ultraterm-computer-use install-codex-mcp` again, restart Codex, and confirm the config still points to `ultraterm-computer-use mcp`.
11. On Linux, a coordinate click, a drag, or keys for a window that is not active are refused, and the error says nothing was sent. Make the window active yourself, or set `ULTRATERM_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` in the server environment. Prefer `element_index` over coordinates.
12. When a Windows snapshot returns an accessibility tree but no image, first confirm the window is visible, not minimized, not cloaked, inside the virtual screen, and not a degenerate tiny window. Without an image, do not call coordinate click or drag. Prefer `element_index`.
13. When troubleshooting `ultraterm-computer-use js` or `ultraterm-computer-use repl`, first run `ultraterm-computer-use capabilities --json`. If the adapter, kernel or native artifact is missing, reinstall the npm package. If the shell reports `node: command not found`, the npm launcher itself has not started, so install Node first or wait for a future native bootstrap approach.

## Future improvements

- Add structured logging and failure-reason classification.
- Keep adding failure context for screenshot capture and AX traversal, and regression samples from ordinary apps.
- Add regression samples from ordinary apps, not only fixture coverage.

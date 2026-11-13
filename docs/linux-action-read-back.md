# Linux action read-back

On Linux, by default an action waits 120 ms before returning the full snapshot. `ULTRATERM_COMPUTER_USE_ACTION_READ_BACK=0` skips this step, and a successful action returns only `ok`. `false`, `no` and `off` also work, ignoring case and surrounding whitespace. The JS REPL sets this variable automatically.

With read-back turned off, actions keep the index cache from the last observation. After the interface changes, update the state with `get_app_state` / `getAXState()` before choosing a target. Explicit observations still return snapshots, and action errors are still returned. `ok` means the call completed. It does not replace verifying the result on screen.

## Tests

Linux regression tests:

```sh
(cd apps/UltraTermComputerUseLinux && go test ./...)
python3 apps/UltraTermComputerUseLinux/runtime_test.py
node --test scripts/node-repl/*.test.mjs
```

Real control tests use a private D-Bus session and an Xvfb display, and do not touch the existing desktop. Debian / Ubuntu need `python3-gi`, `gir1.2-gtk-3.0`, `gir1.2-atspi-2.0`, `at-spi2-core`, `dbus-x11`, `xvfb` and `xauth`.

Build the native binary on Linux, then run:

```sh
(cd apps/UltraTermComputerUseLinux && go build -o /tmp/utcu-read-back-test .)
bash scripts/run-linux-read-back-smoke.sh /tmp/utcu-read-back-test
```

The script creates its own GTK window. Through the native MCP it performs a click, a secondary action, a value set, CJK / emoji text input and Return, and checks the actual control state. It also verifies the short response with read-back off, sequential action indexes, error propagation, explicit observation and the default snapshot. When it finishes, it cleans up test processes, sessions, displays and temporary files.

This test covers X11 / GTK / AT-SPI. It does not represent GNOME Wayland, other applications, or performance testing of complete tasks.

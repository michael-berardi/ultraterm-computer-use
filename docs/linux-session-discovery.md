# Linux desktop session discovery

When UltraTerm Computer Use lacks environment variables such as DISPLAY, XAUTHORITY or the session bus, it fills them in from the current user's desktop processes. Processes marked with `FLATPAK_ID` or `container` are not used as a source of the host environment. Desktop processes are identified only by process name and argv[0], and file paths in the arguments are not matched.

`AT_SPI_BUS_ADDRESS` is not copied from other processes. It may point to a socket that exists only inside a sandbox. Even if an address is visible on the host, that does not mean it belongs to the current desktop. When it is not set explicitly, libatspi finds the accessibility service through `org.a11y.Bus.GetAddress` on the current session bus.

An `AT_SPI_BUS_ADDRESS` set by the caller is kept as is, including custom sockets or other D-Bus address formats. If the caller inherited a wrong address, unset the variable or set the correct address. Automatic discovery does not override the caller's choice.

## Regression

On a Linux environment with GTK 3, AT-SPI, Python GI, Xvfb and D-Bus, build the binaries from before and after the fix, then run:

```sh
GTK_A11Y=atspi NO_AT_BRIDGE=0 xvfb-run -a dbus-run-session -- \
  python3 scripts/tests/linux-session-discovery-smoke.py \
  --baseline /path/to/baseline --native /path/to/patched
```

The script creates a private GTK window and a test process marked with a sandbox environment. Through the real `/proc` discovery path, it verifies that the old version works normally but, after this process is added, cannot connect to `/run/flatpak/at-spi-bus`. It also verifies that the new version can still observe, modify controls and read back, and that an explicit accessibility address works. When it finishes, it cleans up all test child processes.

This is an engineering reproduction of the sandbox environment contamination mechanism, using real GTK/AT-SPI/D-Bus. It is not equivalent to verifying a fully installed Flatpak app or a GNOME Wayland desktop.

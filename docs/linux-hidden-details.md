# Linux hidden control details

By default, full details are read. After setting `ULTRATERM_COMPUTER_USE_LINUX_LIGHTWEIGHT_HIDDEN=1`, controls that AT-SPI explicitly marks as not `SHOWING` omit position, value, actions, toolkit and automation ID, and the line shows `[hidden details omitted]`.

```sh
ULTRATERM_COMPUTER_USE_LINUX_LIGHTWEIGHT_HIDDEN=1 ultraterm-computer-use js \
  'var app = await cua.getApp("gedit"); await app.getAXState();'
```

Node, index, path, role and name are still kept, and children are not skipped just because a parent is hidden. If reading the state fails or is unknown, full details are still read. Negative coordinates and positions outside the window are not used as evidence of hidden state. When a control is shown again, the next observation restores its details.

When enabled, each node reads the `SHOWING` state one extra time. It suits interfaces with many hidden nodes, but it does not guarantee that every interface gets faster. It does not change focus lookup, screenshots or action delivery, and it does not open anything automatically.

## Tests

```sh
python3 apps/UltraTermComputerUseLinux/runtime_test.py
(cd apps/UltraTermComputerUseLinux && go test ./...)
```

The real GTK test reuses the [private D-Bus / Xvfb environment](linux-action-read-back.md) and needs no full desktop or virtual machine:

```sh
(cd apps/UltraTermComputerUseLinux && go build -o /tmp/utcu-hidden-test .)
bash scripts/run-linux-read-back-smoke.sh /tmp/utcu-hidden-test --hidden-checks
```

The script creates a GTK window with two tabs. It compares the full tree, indexes, paths and attribute helper call counts with the switch on and off. Then, through the native MCP, it switches pages, reads the restored details, and verifies click, input and action read-back. The counted attribute calls still go through the real AT-SPI interfaces. Unit tests also cover state errors and visible children under a hidden parent.

In the measured X11 / GTK 3 / AT-SPI run, there were 12 nodes and 3 hidden nodes. The four attribute helper functions were called 48 → 36 times in total. This is not a D-Bus message count or a timing benchmark, and it does not represent the speed on Wayland, other toolkits or complete tasks.

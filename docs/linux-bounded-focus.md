# Linux focus lookup

The snapshot reuses the window that has already been chosen. It looks up focus only once, then reads the focus summary and selected text from the same element. This avoids repeated app / window enumeration and tree traversal.

Focus lookup separately observes the `max_tree_nodes` / `max_tree_depth` limits of `get_app_state`, by default 1200 nodes and 64 levels. Once the depth limit is reached, it no longer reads the next level of children. If the budget runs out before focus is found, it returns:

```text
[Focus search incomplete: node/depth budget reached.]
```

This means the lookup did not finish. If needed, raise the budget and try again. The full AX tree, indexes and screenshots still use the original path. The traversal budget also cannot interrupt a single blocked AT-SPI call. The outer bridge still has a timeout.

Selection uses the standard AT-SPI `get_n_selections` / `get_selection` / `get_text` interfaces. It reads by character offset, supports CJK text and emoji, and respects `text_limit`. If there is no selection or selection reading fails, the focus summary can still be returned.

## Tests

Regression test:

```sh
python3 apps/UltraTermComputerUseLinux/runtime_test.py
```

After building on Linux, you can reuse the [GTK smoke environment](linux-action-read-back.md) to verify real focus and selection:

```sh
(cd apps/UltraTermComputerUseLinux && go build -o /tmp/utcu-focus-test .)
bash scripts/run-linux-read-back-smoke.sh /tmp/utcu-focus-test --focus-checks
```

The script creates its own window in a private D-Bus / Xvfb session. It verifies the node / depth budget message, selection after raising the budget, CJK text and emoji, text truncation, and the focus summary after the selection is cleared. It covers X11 / GTK / AT-SPI. It does not cover Wayland or performance testing of other applications.

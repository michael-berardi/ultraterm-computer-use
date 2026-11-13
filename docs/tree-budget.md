# Control tree budget

`get_app_state`, the CLI `snapshot`, and JS `app.getAXState()` share the snapshot traversal on each platform. The defaults are still 1200 nodes and 64 levels, and no new configuration is needed.

A large list should not make window actions such as "Cancel" or "Open" disappear. Controls are now selected from a bounded set of candidates first, then output in the original tree order. Visible action controls and ordinary interface regions take priority over list content, and content that is clearly off-screen is handled last. Ancestor paths, element bindings and sequential numbering are all kept. After a refresh, use the numbers from the new snapshot.

| Platform | Visibility source |
| --- | --- |
| macOS | The AXVisibleChildren of the collection, plus element geometry inside the window or scroll area |
| Windows | UIA IsOffscreen; list, tree and table branches are deferred |
| Linux | AT-SPI SHOWING and scroll area geometry; GTK table off-screen coordinates can correct an inaccurate SHOWING |

Windows caches UIA properties in bulk within a single snapshot and fetches them again on the next observation. Actions still locate the real element again. The implementation uses [UIA CacheRequest](https://learn.microsoft.com/en-us/dotnet/framework/ui-automation/caching-in-ui-automation-clients).

Unknown or failed visibility information does not remove a control directly. Also, a control is not judged hidden because another application covers the target window.

Output nodes are still limited by `max_tree_nodes`. For priority sorting, candidate discovery has a separate limit: `max(64, min(max_tree_nodes, 2500) × 4)`, which is 4800 by default and at most 10000. When the range is not enough, `[Accessibility tree truncated: ...]` is output. Duplicate and invalid references also count against the candidate budget. The depth budget still applies. Very small budgets and very large providers do not guarantee that all controls are included. The macOS collection summary now shows the number of items actually included, and no longer describes a truncated subset as a continuous range starting at row 0.

The candidate limit bounds how many items are checked in this pass. It is not a hard timeout for the system accessibility API. On macOS and Windows, the child item arrays are still supplied by the application, so the time for a single call depends on the target application.

## Real-app regression tests

- macOS: `node scripts/tests/macos-tree-budget-smoke.mjs <signed-executable>`, with a 2000-file NSOpenPanel. Under 1200 / 40 node budgets, it checks the buttons and actually clicks Cancel. It uses the current normal authorization.
- Linux: run `python3 scripts/tests/linux-tree-budget-smoke.py --native <native-executable>` in a private Xvfb / D-Bus session. It checks a real GTK list of 2000 rows, the bottom button and the last row after scrolling. For dependencies and environment, see [Linux action read-back](linux-action-read-back.md).
- Windows: `scripts/tests/windows-tree-budget-smoke.ps1 -NativePath <native-executable>`, with a real WPF/UIA list of 2000 rows and buttons.

These tests use their own windows and directories. GTK verification covers X11 / AT-SPI. It does not represent Wayland or all toolkits.

# Write verification

`app.setValue(index, value)`, the CLI, and the MCP `set_value` read back the actual value after writing on macOS, Windows and Linux. If the control ignores the write or changes the content to a different value, an error is returned.

```js
await app.setValue(index, " 0015 "); // keep spaces and leading zeros
await app.setValue(index, "");       // clear
```

| Type returned by the control | Comparison |
| --- | --- |
| Text (including Windows UIA ValuePattern, Linux EditableText) | Exact comparison of raw characters; no trimming, no case folding, no Unicode normalization |
| Native number (macOS AX, Linux AT-SPI Value) | Compared as numbers, e.g. 15 and 15.0; `0015` in a text box is not treated as 15 |
| Native boolean (macOS AX) | true/1 and false/0 map to boolean values |

If the value does not match yet, it polls for up to 0.6 seconds, rereading only and never writing again. Turning off full action read-back (`ULTRATERM_COMPUTER_USE_ACTION_READ_BACK=0`) still verifies, and macOS also checks the session before reading and returning. Time blocked inside a single system API call is not counted against the polling budget.

On Linux, read-only fields are rejected before anything is written: the AT-SPI state includes `READ_ONLY`, or a text field (role `text` / `entry` / `password text`) lacks `EDITABLE`. A read-only Qt 6 `QLineEdit` reports both `READ_ONLY` and `EDITABLE` and still accepts `SetTextContents`. The read-back matches the write, so verification alone cannot detect it. A GTK 3 entry with editing turned off simply lacks `EDITABLE`. A Qt 6 spin box lacks `EDITABLE`, so a spin button is checked only for `READ_ONLY`.

A failed verification does not mean the control did not change at all. Observe again before deciding whether to retry. UltraTerm Computer Use does not automatically switch to the keyboard or another input path. Verification only confirms the value at the time it was read. It does not guarantee that the application will not change it again later.

## Windows state-type actions

On Windows, Toggle, Select, Expand and Collapse in `perform_secondary_action`, and `click` when it lands on a SelectionItem / Toggle pattern (checkboxes, radio buttons, list items), also read back the control state. Toggle requires the state to change. Select requires the item to be selected. Expand requires Expanded or PartiallyExpanded (LeafNode is not accepted). Collapse requires Collapsed. It polls for up to 0.6 seconds and never sends the action again. If the expected state is not read back, it returns an error and asks for a new observation first, because the action may take effect later and a blind retry would toggle the control back. For ScrollPattern paging, if an exception occurs after the pattern has been called, it reports how many page calls completed and that the result is uncertain, and it does not fall back to the mouse wheel. Even if the first page throws, scrolling may already have happened. The original fallback is kept only when there is no ScrollPattern.

## Regression tests

- macOS: `node scripts/tests/macos-set-value-smoke.mjs <signed-native-executable>`, using real AppKit text controls. It covers normal, ignored, rewritten, delayed, cleared, whitespace and Unicode writes, and checks full read-back both off and on, plus JS error propagation.
- Linux: run `python3 scripts/tests/linux-set-value-smoke.py --native <native-executable>` in a private Xvfb / D-Bus session, with real GTK / AT-SPI. It covers normal, ignored, length-limited, delayed and read-only cases. It does not represent all Wayland or toolkit behavior.
- Windows: `scripts/tests/windows-set-value-smoke.ps1 -NativePath <native-executable>`, using a real WPF custom ValuePattern. Normal and ignored writes on real WPF state-type providers, independent call counts and state checks are run by the Windows Go test `TestRealPatternActionsVerifyStateWithoutResending`. The decision logic for state-type actions is in `scripts/tests/windows-pattern-readback.test.ps1` (pattern stand-ins; runs under any pwsh).

The tests use their own windows and data and do not modify personal apps.

Exception for macOS password fields that are marked as such: only confirms that the AX write was accepted, and does not verify the secret by reading it back. Success does not mean the content was verified. Ordinary controls still use the read-back verification above. For password observation and platform differences, see [Password fields](password-fields.md).

Qt 6 read-only regression: in a private Xvfb/D-Bus session with PyQt6 installed, run `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 python3 scripts/tests/linux-qt-readonly-smoke.py --native /path/to/binary`. For a pre-fix binary, add `--expect-baseline-write` to verify the incorrect write. The script only operates on controls it creates, and it also checks an ordinary text box and a spin box.

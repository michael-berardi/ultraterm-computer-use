# Password fields

Password fields still show their name, role and position. Observation results do not return the field value or selected text. On macOS, `AXSecureTextField` is used: snapshot and query read the role information first, then decide whether to read the value. Selection is filtered the same way. On Linux, the AT-SPI `password text` marker is used. On Windows, UIA `IsPassword` is used, and if that marker cannot be read, neither the value nor the selection is read. The Windows bulk snapshot does not prefetch `ValuePattern.Value`. Ordinary controls are read after they are confirmed not to be passwords.

This depends on the application correctly marking its password controls. Names are not used to guess. In GTK 4, a plain GtkEntry with visibility turned off may still report `text`. Such an unmarked control cannot be reliably identified. Screenshots are drawn by the application, and this rule does not hide plain text that the application displays on purpose.

Linux `set_value` keeps its internal verification for now. The read value is not placed in the response. If a password control only provides dots or an empty value, it reports that verification is not possible, and the caller should observe again rather than retry directly. On macOS, `type_text` in a password field uses keyboard delivery to keep existing content and the cursor. `set_value` only confirms that the AX write was accepted. It does not read back the password for verification, so a successful return must not be treated as verified password content. `select_text` does not support locating by password content.

## Regression

Uses a fixed fake password and does not read user apps:

```sh
python3 apps/UltraTermComputerUseLinux/runtime_test.py
# Linux, with GTK 3/4, AT-SPI, Xvfb and D-Bus installed
GTK_A11Y=atspi NO_AT_BRIDGE=0 xvfb-run -a dbus-run-session -- \
  python3 scripts/tests/linux-password-smoke.py
```

`--runtime <baseline-runtime.py> --expect-leak` is used as the pre-fix comparison for GTK 4. The test checks that ordinary fields remain readable in the full snapshot and that password values do not appear in the results. The existing Linux native MCP action smoke test is run separately.

The Windows observation test checks that forbidden reads and cache requests are not made. A real WPF fixture adds a PasswordBox and checks the native MCP responses for a normal, focused and selected password.

On macOS, run `node scripts/tests/macos-text-input-smoke.mjs <signed-executable>`, then run it again with `ULTRATERM_COMPUTER_USE_DISABLE_AX_READ_CACHE=1`. The test covers append and overwrite input in a real NSSecureTextField, and a provider that deliberately exposes the password value: snapshot, selection and query must not request that value. When Locked Use is installed, the test bundle must use an approved signing identity. Existing authorization must not be changed to force a pass.

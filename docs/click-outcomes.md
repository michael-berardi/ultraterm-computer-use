# macOS click outcomes and retries

An accessibility call timeout does not mean the application did not act. If button handling exceeds the AX timeout, the original action may still be running. Switching to another click method at that point would repeat the operation.

When the click chain hits an uncertain result such as `cannotComplete` or `failure`, it stops and does not try AXConfirm, nearby controls or mouse clicks. The returned message says the action may already have taken effect, so observe again first and do not retry directly.

An action that is explicitly refused can still continue with the existing fallback. If part of a multi-click has already been delivered, the whole group is not resent, even if later clicks are explicitly refused. The existing compatibility behavior for AXOpen / attributeUnsupported is kept, but it does not open again.

## Reproduction and regression

```sh
node scripts/tests/macos-click-outcome-smoke.mjs <signed-baseline-executable> --expect-repeat
node scripts/tests/macos-click-outcome-smoke.mjs <signed-patched-executable>
```

The script only operates on a separate AppKit fixture. The slow button pauses for 2 seconds on each execution, and a separate state file records the number of actions. A fast button verifies a normal single click and an intentional double click. It uses the real native MCP and the default app_post path, does not enable the global pointer, and does not change system permissions.

Sequence unit tests also cover first-attempt refusal, first-attempt timeout, refusal or timeout after partial success, and AXOpen. Regular geometry, descendant control selection and file panel regressions continue to use `macos-hit-test-smoke.mjs` (including `--descendant-guards`) and `macos-sheet-smoke.mjs`.

This does not guarantee that any third-party provider reports action results accurately. It also does not change the input policy on Windows or Linux.

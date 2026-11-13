# macOS snapshot geometry

When part of a window is moved off screen, the hardware screenshot may contain only the on-screen area. If click coordinates are still converted using the full window size, the click lands in the wrong place. #154 switches to whole-window capture with ScreenCaptureKit in this case.

A window that lies entirely within one display still prefers the hardware screenshot. The fallback is used only when the window is off screen, spans displays, display information is unavailable, or the hardware result has an abnormal aspect ratio. If the whole-window result still has the wrong aspect ratio, no image is returned. The aspect ratio check is only a safeguard. Size alone cannot prove that the picture is complete.

When AX returns a frame that is NaN, infinite, has a negative size, or overflows during calculation, the control information is kept and the geometry is omitted. Snapshot, query and click re-read share this validation. Text rendering has a separate integer conversion guard. Window candidate area and ScreenCaptureKit output size also use integer conversions that can fail.

## Reproduce and verify

On a Mac with Accessibility and Screen Recording authorized, run the signed executable inside the app:

```sh
node scripts/tests/macos-snapshot-geometry-smoke.mjs \
  'dist/UltraTerm Computer Use.app/Contents/MacOS/UltraTermComputerUse'

# Use the old version as a negative control: a normal window must pass, and the off-screen cropping and invalid AX crash must reproduce.
node scripts/tests/macos-snapshot-geometry-smoke.mjs \
  '<old-app>/Contents/MacOS/UltraTermComputerUse' --expect-regression

swift test
```

The script only operates on the AppKit window it creates. When it finishes, it closes the fixture and the MCP. Screenshots, text and results stay in the temporary output directory. It uses a temporary configuration, tests both original size and a 300 px maximum edge output, and does not change the user's configuration.

Measured on 2026-11-07 with the signed native MCP on this machine:

| Case | v1.1.4 | After fix |
| --- | --- | --- |
| Normal 600×432 point window | 1200×864; scaled to 300×216, click passed | Also passed |
| Half of the window off screen on each side | 600×864; scaled to 208×300, wrong aspect ratio | 1200×864 / 300×216; all three color blocks complete, on-screen button hit by screenshot-coordinate click |
| Identified control returns NaN position | MCP exits with SIGTRAP | Read succeeds; query omits bounds; later reads and clicks work normally |
| Identified control returns NaN size | MCP exits with SIGTRAP | Same as above |

Full Swift run: 442 items, 9 skipped, 0 failed. The existing `macos-hit-test-smoke.mjs --descendant-guards --allow-desktop-activity` also passes. It covers Retina / scaled-down image, AX-only index clicks, blank areas and window root index protection. That option does not verify desktop foreground or physical pointer stability.

This reproduction used a separate test window and did not modify Contacts data. Cross-display path selection, missing display information, screenshot failures and abnormal geometry have separate unit tests. This does not claim coverage of all mixed-DPI setups, other Spaces, or Locked Use states. Whole-window capture is slower than the hardware path, so it is used only when needed.

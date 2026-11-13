# Configuration


The config file defaults to `~/.config/ultraterm-computer-use/config.json`. You can edit it directly, or create it if it doesn't exist. Here are the defaults:

```json
{
  "virtualDisplay": {
    "enabled": false
  },
  "image": {
    "format": "png",
    "jpegQuality": 0.8,
    "maxLongEdgePixels": 1280,
    "scaleDownAfterMaxSize": true,
    "discardBelowPixelCount": 64,
    "captureTimeout": 5
  }
}
```

These settings apply to macOS screenshots and virtual displays. Changes take effect on the next capture or tools/list; reconnect MCP clients to refresh cached schemas. Environment variables are also supported, with precedence: ENV > config file > defaults.

## Configure from the command line

You can also use `ultraterm-computer-use config`. Changes are saved to the file above:

```bash
# View settings
ultraterm-computer-use config

# Switch to JPG
ultraterm-computer-use config set image.format jpg

# Read one setting
ultraterm-computer-use config get image.format

# Restore the default (ENV overrides still take priority)
ultraterm-computer-use config reset image.format

# Show the config file path
ultraterm-computer-use config path
```

## Settings

| Setting | Default | Description | Example command |
| --- | --- | --- | --- |
| `image.format` | `png` | Output format: `png`, `jpg` or `webp`. WebP is lossless. | `ultraterm-computer-use config set image.format webp` |
| `image.jpegQuality` | `0.8` | JPG quality, from `0` to `1`. Only affects JPG. | `ultraterm-computer-use config set image.jpegQuality 0.9` |
| `image.maxLongEdgePixels` | `1280` | Maximum long edge in pixels. Integer `1–16384`; `null` disables the limit. | `ultraterm-computer-use config set image.maxLongEdgePixels 1920` |
| `image.scaleDownAfterMaxSize` | `true` | If the long edge exceeds the limit, `true` resizes proportionally and `false` omits the screenshot. | `ultraterm-computer-use config set image.scaleDownAfterMaxSize false` |
| `image.discardBelowPixelCount` | `64` | Omit when width × height is below this value; equality is retained. Integer `0–268435456`; `0` disables filtering. For example, `4096` is the area of `64×64`. Resized images are checked too. | `ultraterm-computer-use config set image.discardBelowPixelCount 4096` |
| `image.captureTimeout` | `5` | ScreenCaptureKit fallback capture timeout, in seconds. Range `0.01–300`. | `ultraterm-computer-use config set image.captureTimeout 10` |


## Virtual displays (macOS, opt-in)

`virtualDisplay.enabled` defaults to `false`. While disabled, `get_app_state` omits
`window_placement` from its MCP schema, JS guidance omits `windowPlacement`, and
covered-window hints do not recommend parking windows. Stale explicit
`agent_display` calls fail before app lookup or virtual display creation.

Enable deliberately with `ultraterm-computer-use config set virtualDisplay.enabled true`, or set
`ULTRATERM_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED=true` in the caller's environment.
Only literal `true`/`false` environment values are accepted; invalid values disable
creation. The config file requires a JSON boolean. Environment overrides take
priority over the file and defaults. Windows/Linux never advertise this parameter.

Virtual displays add a monitor to the system arrangement and can affect existing
monitor layouts. To disable, use `ultraterm-computer-use config set virtualDisplay.enabled false` and
remove any enabling environment override. Reconnect clients to refresh their tool
schema. Existing parked windows can still be restored using an explicit `restore`
call or `turn-ended`/connection cleanup; disabling does not destroy a display while
it still holds windows. Old running binaries must be restarted after upgrading.

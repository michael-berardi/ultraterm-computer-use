# macOS SkyLight 后台点击参考

## 用途

这份笔记记录 `click_method=sky_click` 所依赖的外部研究、固定源码版本和 OCU 采用的边界。SkyLight 是 macOS 私有 SPI；这里描述的是经过源码交叉验证的兼容实现，不是 Apple 承诺稳定的公开 API。

## 参考来源

- Cua 文章：[Inside macOS Window Internals](https://cua.ai/blog/inside-macos-window-internals)
  - 解释普通 HID 命中测试、PID 定向投递和 SkyLight 投递的差异。
  - 说明 Chromium 后台输入、focus-without-raise 和 AX remote observer 等问题域。
- Cua Driver：[trycua/cua](https://github.com/trycua/cua/tree/b8a0f32a06c75225ba24ebb5ab14f6507fa90d15/libs/cua-driver)
  - 本实现对照 commit `b8a0f32a06c75225ba24ebb5ab14f6507fa90d15`。
  - 事件序列基线来自 `rust/crates/platform-macos/src/input/mouse.rs` 的 `click_at_xy_chromium`。
  - 动态符号和私有函数签名基线来自 `rust/crates/platform-macos/src/input/skylight.rs`。
- yabai：[asmvik/yabai](https://github.com/asmvik/yabai/tree/dd845723416f5fe92af49fad5ebab00369e07edd)
  - 用于交叉检查 SkyLight 动态加载和私有窗口 API 的工程实践；OCU 没有复制 yabai 代码。

## OCU 采用的事件序列

`sky_click` 使用当前 snapshot 的 PID、`CGWindowID`、窗口内坐标和屏幕坐标，按以下顺序投递：

1. 保存当前前台 PSN/window id，向原前台发送 defocus record，再向目标发送 focus record；两次 `SLPSPostEventRecordTo` 只切 AppKit-active 状态，不调用会 raise / 切 Space 的 `SLPSSetFrontProcessWithOptions`。
2. 目标点 `mouseMoved`，gesture phase `2`。
3. `(-1, -1)` 的 off-window primer `mouseDown` / `mouseUp`，phase `1` / `2`。
4. 等待 `100ms`，把真实目标 `mouseDown` / `mouseUp` 以 phase `3` 投递。
5. 双击时等待 `80ms` 后发送第二对事件，并把 click state 从 `1` 递增到 `2`。
6. 等待 renderer 消费异步 mouse-up，再向目标发送 defocus、向原前台发送 focus record，恢复 AppKit-active 状态。

每个事件带相同 click-group id，并设置 PID、窗口 id、window-under-pointer 和 window-local location。每一步同时走 `SLEventPostToPid` 与公开 `CGEvent.postToPid`：前者覆盖 Chromium/Catalyst，后者保留 AppKit 兼容性。这是一个固定 dispatch policy，不是失败后的 retry。

## OCU 明确没有采用的部分

- 不调用 `SLPSSetFrontProcessWithOptions`，也不使用 `NSRunningApplication.activate` 操作目标 app。focus-without-raise 只切换并恢复 AppKit event routing state，WindowServer frontmost 与窗口 z-order 必须保持不变。
- 不把 `sky_click` 放进 `auto`，也不从失败的 `sky_click` 回退到 `global`。
- 不支持右键、中键、三击、跨 Space、隐藏或最小化窗口。
- 不承诺 Canvas、Unity、Blender 或其他拒绝 PID 定向事件的 surface 可用。

## 兼容性检查

运行时通过 `dlopen` / `dlsym` 探测以下符号，任一缺失都会在投递前 fail closed：

- `SLEventPostToPid`
- `SLEventSetIntegerValueField`
- `CGEventSetWindowLocation`
- `SLPSPostEventRecordTo`
- `_SLPSGetFrontProcess`
- `GetProcessForPID`

投递前还必须确认 snapshot 的 `CGWindowID` 仍由同一 PID 所有且仍为 on-screen。macOS 更新后应重新验证符号、事件字段、签名 app 制品和被完全遮挡的 Chromium 页面。

## 许可

Cua 代码使用 MIT License。本仓库对衍生事件 recipe 的归属与许可文本见根目录 `THIRD_PARTY_NOTICES.md`。

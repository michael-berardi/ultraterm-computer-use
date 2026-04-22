## [2026-04-22 17:05] | Task: fix targeted mouse coordinate space

### 🤖 Execution Context
* **Agent ID**: `unknown`
* **Base Model**: `GPT-5 Codex`
* **Runtime**: `Codex CLI`

### 📥 User Query
> if mcp click with x,y like `click({"app":"Calendar","x":1060,"y":790})`, it will trigger the "About Mac" page, why? fix this

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit`, `docs/ARCHITECTURE.md`, `docs/histories/`

**Key Actions:**
- **[Coordinate-space fix]**: 抽出共享的 screen-state -> AppKit 全局坐标转换，并把 `click` / `scroll` / `drag` 的 pid-targeted 鼠标事件统一走这条转换路径。
- **[Regression coverage]**: 增加针对 targeted mouse 坐标转换的单测，覆盖单屏 y 反转和带 display offset 的多屏场景。
- **[Behavior docs]**: 更新架构文档，明确 pid-targeted mouse / scroll 回放前会先做 screenshot 坐标到 AppKit 全局坐标的映射。

### 🧠 Design Intent (Why)
`get_app_state` 暴露给工具的是 screenshot 像素坐标，属于窗口截图/CG window capture 的 y-down 坐标系；而 pid-targeted 鼠标事件最终会被目标 app 按 AppKit-compatible 全局坐标解释。之前直接把 screenshot 坐标喂给 `CGEvent.postToPid`，真实 app 会在错误位置收到点击，表现成点 Calendar 却触发了别的系统 UI。修复的关键不是改 `x/y` 语义，而是在 targeted event replay 前把坐标系补齐。

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/InputSimulation.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `docs/ARCHITECTURE.md`
- `docs/histories/2026-04/20260422-1705-fix-targeted-mouse-coordinate-space.md`

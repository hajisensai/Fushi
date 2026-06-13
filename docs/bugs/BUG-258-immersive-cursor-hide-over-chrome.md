## BUG-258 · 沉浸/锁屏鼠标放字幕/面板上不隐藏
- **报告**：2026-06-14（用户：TODO-318 沉浸/锁屏模式下鼠标放到字幕或面板上光标不会自动隐藏）
- **真实性**：✅ 真 bug。OS 鼠标自动隐藏由 media_kit 的 `MouseRegion`（`cursor: none`，`material_desktop.dart`，`hideMouseOnControlsRemoval && !mount`）拥有；但 hibiki 把 overlay chrome（锁按钮 rail / 字幕跳转面板 等的 click cursor）叠在 media_kit 之上 → 胜出 cursor 解析（最上层 MouseRegion 决定光标）→ 鼠标重现；锁模式下 `IgnorePointer`（`hibiki/lib/src/pages/implementations/video_hibiki_page.dart:5143`）又剥了 media_kit 的 region，光标更无人隐藏。
- **[x] ① 已修复** — 引入单一真相源 `_cursorHidden`（`ValueNotifier<bool>`，镜像 controls 隐藏 / 沉浸锁态，随 `_videoControlsVisible` + `_immersiveLocked` 联动）：当应隐藏（controls 淡出 且/或 沉浸锁）时，在 controls 子树最外层（`_videoControlsHoverWrap` 内、`_buildVideoControlsInner` 外）包一个 `MouseRegion(cursor: SystemMouseCursors.none)` 盖过所有 chrome 统一胜出；真实鼠标移动经 `_handleVideoControlsHover` 自然唤回（置 `_cursorHidden=false`）。不 per-overlay 加 opaque MouseRegion（避免回归 BUG-198 hover 穿透）。提交哈希见末行。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/video_immersive_cursor_hide_guard_test.dart` 源码守卫：存在 `_cursorHidden` 单一真相源；controls 子树最外层有顶层 `MouseRegion(cursor: none)` 由 `_cursorHidden` 驱动；未 per-overlay 加 opaque MouseRegion。
- **备注**：与 integration/wave-1 ff 基线对照零新增回归。真机验证待用户（桌面光标隐藏需真实窗口环境）。

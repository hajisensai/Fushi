## BUG-215 · 连按快进时控件自动隐藏计时器不刷新
- **报告**：2026-06-12（用户：）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/video_hibiki_page.dart:1391` 的 `_pokeControlsVisible()`——桌面控制条可见性归 media_kit 的 `controlsHoverDuration:2s`，media_kit 仅在 `MouseRegion.onHover/onEnter` 重置其隐藏 `Timer`；本页唯一重置手段是向控制条 RenderBox **固定中心点** `renderObject.size.center` 派发合成 `PointerHoverEvent`。Flutter `MouseTracker` 对「同一合成设备落在同一坐标」的连续 hover 去重 → 连按快进/跳句时第二次起 media_kit `onHover` 不再触发、计时不续命，控制条仍只活 2 秒就消失。
- **[x] ① 已修复** — `_pokeControlsVisible` 每次翻转新增字段 `_pokeParity`，把合成 hover 的 x 坐标 ±1px 抖动（`pokePosition = Offset(center.dx ± 1, center.dy)`），使坐标始终变化、强制 MouseTracker 每次都回调 onHover 续命。1px 抖动仍稳落控制条命中区；移动端 `_isDesktopVideoControls` 门控不受影响。提交见 git log（TODO-148）。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/video_controls_poke_dedup_guard_test.dart`（源码守卫：断言 `_pokeParity` 字段、每次翻转并 ±1px 偏移、派发用抖动后的 `pokePosition` 而非固定 `center`）。media_kit headless 无 native player / 无 MouseTracker 去重管线，故在源码层钉死契约。
- **备注**：needsDevice——MouseTracker 同坐标去重只在真实视频控制条子树复现，源码守卫断言抖动逻辑就位，真机由用户验证。

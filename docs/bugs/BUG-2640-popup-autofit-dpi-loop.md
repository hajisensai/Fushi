## BUG-2640 · 125% 缩放下视频查词热槽弹窗尺寸 1px 振荡致 WGC 帧池持续重建
- **报告**：2026-09-23（用户：Windows 125% 缩放下窗口模式播放视频明显卡顿；切全屏后
  界面与鼠标卡住、声音照放、点任务栏切不回。`wgc_capture.log` 里 surface 在 626x164 /
  626x165（逻辑高约 164.967 / 165.967，scale=1.250）间反复跳，捕获项 782x205 / 782x206，
  持续 `start-skip-running` + `needs_update=1`。改回 100% 缩放后跳变消失、全屏只调整一次）
- **真实性**：✅ 真 bug。视频页唯一的 WebView 是常驻的查词热槽（隐藏时也在树上）。
  自适应高度闭环：外壳高变 → fork `setSize` → WebView2 `resize` → popup.js
  `scheduleMasonryAll` → `_reportPopupHeight()` 上报 `(内容高, innerHeight)` →
  `dictionary_page_mixin.dart` `onContentMetrics` 用 `resolveAutoFitPopupHeight`
  （`当前外壳高 + 内容高 − 视口高`）重设外壳高 → 又一次 `setSize`。
  根因在 `fushi/lib/src/pages/implementations/dictionary_popup_webview.dart`
  `resolvePopupViewportHeight`：优先取 JS `innerHeight`，而它是量化过的整数——
  `packages/flutter_inappwebview_windows/windows/custom_platform_view/custom_platform_view.cc`
  的 setSize 先把逻辑尺寸 `static_cast<size_t>` 截成整数（164.967→164、165.967→165，
  ×1.25 = 205 / 206.25→206，正是日志里的 782x205/206），125% 下 CSS 视口还是小数
  （206/1.25 = 164.8）。外壳高是带小数的 Flutter 布局值，减一个整数视口后差值恒为
  整数 ±1，正好越过宿主 `<1` 去抖门，于是永不收敛：每一轮都 `needs_update_=true` →
  重建 WGC 帧池。100% 下截断与量化恰好对齐，所以只在分数缩放出现。
- **[x] ① 已修复** — `resolvePopupViewportHeight` 改为优先用 Flutter 布局高度（外壳高
  与之同源，递推变成幂等的 `顶栏高 + 内容高`，亚像素残差由既有 `<1` 门吸收）；JS
  `innerHeight` 只在布局不可用时兜底（保留 BUG-1651 macOS 离屏报 0 的回退语义）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/dictionary_popup_webview_test.dart`：
  优先级断言 + 「分数 DPR 闭环」组（按 截断逻辑 → 截断物理 → 整数 innerHeight 建模，
  钉住仅 JS 视口时 ±1 px 永久翻转、用布局视口一次写入即收敛到 `顶栏 + 内容`）。
- **备注**：用户日志里的精确数值未能在纯模型中逐字重放（真实 innerHeight 取整与内容
  随视口的变化取决于 Chromium），测试钉的是同一形态；尚未在 125% 真机复测，待用户
  确认视频窗口模式流畅、全屏切换不再卡死。native 逻辑尺寸先截断整数导致 WebView2
  最多比 Flutter 盒小 1 逻辑 px 的问题本次未动（不是振荡根因）。

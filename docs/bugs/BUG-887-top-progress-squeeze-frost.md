## BUG-887 · 挤压模式顶部进度不应有毛玻璃且不应压住正文首行
- **报告**：2026-07-18（用户：竖排、横线起笔字如「一」「ー」，顶部信息条模糊略盖正文首行；且未开悬浮顶部进度，本不该有背后模糊）
- **真实性**：✅ 真 bug，根因 `hibiki/lib/src/pages/implementations/reader_hibiki/chrome.part.dart:1665`（`_buildTopProgressBar` 无条件套 `ClipRRect > BackdropFilter(ImageFilter.blur) > 半透明 Container` 毛玻璃）
- **[x] ① 已修复** — 毛玻璃改为仅悬浮态绘制。单一真相源 `topProgressUsesFrostedGlass(floating:)`（`hibiki/lib/src/reader/reader_chrome_floating.dart`），挤压态返回 `false`：strip 已预留自身高度、正文被推到其下方，pill 落在预留区（正文空白顶边距 = 主题背景）之上，背后并无正文，毛玻璃既无意义又显出一块贴住正文首行的模糊矩形。挤压态改为纯文字（`Padding > Text`，无背景无模糊）；悬浮态维持毛玻璃提升可读性。提交：<pending>
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_top_progress_reserve_test.dart` 新增 group「BUG-887 顶部进度毛玻璃只在悬浮态出现」：`topProgressUsesFrostedGlass(floating:false)` 必 `false`、`floating:true` 必 `true`；一旦有人把毛玻璃改回无条件绘制即失败。
- **备注**：与 BUG-843/BUG-547（预留高漏计 pill 内边距导致压住首行，已由 `kTopProgressStripHeight = font×1.5 + 2×padding = 24` 修复）同族但正交——843 修「预留 < pill 实高」的布局越界，886 修「挤压态根本不该有毛玻璃」的视觉噪声。两者叠加后挤压态既不越界也不显模糊。

## BUG-210 · 阅读器翻页跳回章节开头
- **报告**：2026-06-12（用户：Windows 桌面版 hibiki-windows-0d1798d2a — 「翻页有可能回到章节开头，这翻页好怪，怎么回事，修一下」，TODO-146）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:1402`（修复前 `_syncPageSize` 里 `final bool widthChanged = _lastSyncedWidth > 0 && w != _lastSyncedWidth;`）。
- **[x] ① 已修复** — commit 见「修复提交」。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/reader_viewport_repaginate_test.dart`（纯函数行为）+ `hibiki/test/pages/reader_paging_width_tolerance_guard_static_test.dart`（源码守卫）。
- **备注**：见下。

### 复现/定位（沿真实代码路径，已排除 JS 路径）
桌面滚轮/键盘翻页链路：WebView `wheel`/`keydown` → `onSwipe` → Dart `_paginate(dir)` → JS `window.hoshiReader.paginate(dir)`。

**先排除 JS `paginate`**：用无头 Chromium（与 Windows WebView2 同引擎）注入**真实抽取的**分页脚本（`reader_pagination_scripts.dart` 的 `_sharedJs` + 分页 shell），构造横排多页章节（含首页大标题块、minScroll>0 等场景），经 CDP 驱动「初始恢复 → 连续 forward/backward 翻页」。结果：逐页步进 drift=0，无任何跳回章节开头；BUG-169 的 `floor(cur/pitch)+1` / `ceil(cur/pitch)-1` 步进在引擎里稳健。`registerSnapScroll` 的 snap 监听器、`buildPaginationMetrics`（不同 currentScroll 下 minScroll/maxScroll 一致）、stale-metrics、transient-scroll-reset 等场景也都不回章首。**JS 分页不是根因。**

**根因在 Dart 端 `_syncPageSize`**（`reader_hibiki_page.dart`）。该方法由 `didChangeMetrics()`（视口度量变化）触发，比较当前 MediaQuery 宽高与上次已分页基线 `_lastSyncedWidth/Height`：
- 宽变走 `widthChanged` 分支 → `_navigateToChapter(_currentChapter, progress: _displayedProgress)`：**整章重载 WebView** + 用**粗粒度 progress** 恢复（`restoreProgress` → `scrollToProgressPaged`）。
- 高变走 `heightChanged` 分支 → JS `updatePageSize`：**原地重排** + 精确字符偏移重锚。

问题是两个度量的判定**不对称**：
```
final bool widthChanged = _lastSyncedWidth > 0 && w != _lastSyncedWidth;  // 零容差精确浮点不等
final bool heightChanged = (h - _lastSyncedHeight).abs() >= 1;            // 1px 容差
```
Windows 桌面用 fork 的 `flutter_inappwebview_windows` 渲染 EPUB，翻页/重绘时常报 **sub-pixel 视口宽抖动**（DPI 缩放、滚动条出现消失、布局回报抖动）。零容差让任意 0.x px 宽差都判 `widthChanged`：
1. `progress = calculateProgress()`：若用户在章节第 1 页或 metrics 尚未 settle / `_reanchorPending` 期读到瞬态 scroll 0 → `progress <= 0` → `scrollToProgressPaged(progress<=0)` 直接落 `contentFirstPageScroll` = **章节开头**；
2. 即便 `progress > 0`，整章重载 + 粗粒度 progress（分辨率 = 已读字符/总字符）恢复 → `alignToPage` 取整落到错误的、通常**更靠前**的页。

两种都表现为用户感知的「翻页跳回章节开头（附近）+ 整章重载闪烁 = 翻页好怪」，且「有时」取决于度量是否抖动 + 当前页是否靠前。这与 BUG-109/162 早已识别的「粗粒度 progress 恢复丢精度」是同一类问题，只是 `_syncPageSize` 的宽变分支没用上字符偏移修复，且零容差让它被误触发。

### 修复（根因，非补丁）
让宽、高用**同一个 1px 容差**判定，消除「宽零容差」这个特例（Linus：消除特殊情况优于加分支）。新增纯函数：
```dart
({bool width, bool height}) readerViewportNeedsRepaginate({
  required double width, required double height,
  required double lastWidth, required double lastHeight,
  double tolerancePx = 1.0,
}) {
  final bool widthChanged = lastWidth > 0 && (width - lastWidth).abs() >= tolerancePx;
  final bool heightChanged = (height - lastHeight).abs() >= tolerancePx;
  return (width: widthChanged, height: heightChanged);
}
```
`_syncPageSize` 改用它判宽/高变化。真正的旋转 / 窗口 resize 宽度大变（远 > 1px）仍照常走整章重载，零破坏；只把 sub-pixel 抖动误触发的整章重载 + 粗粒度恢复消除掉。`_lastSyncedWidth > 0` 首帧门控保留。

### 测试
- `test/pages/reader_viewport_repaginate_test.dart`：核心回归断言 = 0.4px 宽抖动**不**触发 widthChanged（撤回修复改回 `width != lastWidth` 零容差 → 此用例红，已实测）；>= 1px 宽变（resize/旋转）仍触发；首帧 lastWidth==0 不误判；高度容差不变。
- `test/pages/reader_paging_width_tolerance_guard_static_test.dart`：源码守卫，锁死 `_syncPageSize` 函数体不再含零容差 `w != _lastSyncedWidth`、必经 `readerViewportNeedsRepaginate`、宽高用同一 `abs() >= tolerancePx`。
- 复测 BUG-111 既有守卫 `reader_init_page_width_guard_static_test.dart` 绿（未破坏 `_paginatedWidth` 基线逻辑）。
- `flutter test test/reader/ test/pages/`：982 绿。`flutter analyze`（改动文件 scope）：0。

### 残留风险（需真机）
- 宽度**真大变**（旋转 / 窗口 resize）仍走 `_navigateToChapter` 整章重载 + 粗粒度 progress 恢复，那条路径本身的「丢精度落相邻页」是既有行为（移动端旋转语义），不在本 bug 范围；如要彻底改成字符偏移精确恢复需另开 todo 改 `_navigateToChapter`，风险更大。
- 本轮为纯函数 + 源码守卫 + analyze/test 全绿；**Windows 桌面真机复测**（滚轮快速连翻、缩放层 settle、窗口边缘像素级拖动 resize 时翻页不再弹回章首）待用户/集成环节。

### 修复提交
- 6bc1472bc fix(reader): symmetric 1px tolerance for viewport repaginate (TODO-146, BUG-210)

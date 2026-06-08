## BUG-136 · 翻页(手势/滚轮)后 ESC 不退出书籍
- **报告**：2026-06-08（用户：翻页以后，esc 不会退出书籍了）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`（焦点丢失，详见下）
- **[x] ① 已修复** — 提交 `dc634a2aa`
- **[x] ② 已加自动化测试** — `hibiki/test/pages/reader_esc_focus_reclaim_static_test.dart`（纯谓词单测 4 例 + 源码守卫 6 例，10 绿）
- **备注**：

### 根因
退出书籍依赖 Flutter 阅读器 `_focusNode`（挂 `Focus(onKeyEvent: _handleKeyEvent)`，`reader_hibiki_page.dart:1213-1216`）持有键盘焦点：
ESC → `_handleKeyEvent` 解析 `readerDismissDict`（无弹窗时）→ `Navigator.maybePop()`（`:3972`）→ `PopScope.onPopInvokedWithResult` → `onWillPop()`（`base_source_page.dart:104`，**恒返回 true**）→ 退出。

进书时 `Focus(autofocus: true)` 给了 `_focusNode` 焦点，所以**刚进书 ESC 能退**。但用**指针手势翻页**——滑动 / 鼠标滚轮（JS `wheel` 也 `callHandler('onSwipe')`，`:1741-1749`）/ 边界翻章（`onBoundarySwipe`）——手势先落在原生 `InAppWebView` 上，WebView 抢走 OS 键盘焦点，**没有任何代码把焦点还给 `_focusNode`**（对比 popup 路径的 `onAllPopupsDismissed` 明确 `_focusNode.requestFocus()` 并注释「否则关弹窗后阅读器收不到任何按键」，`:3241-3244`）。
此后 ESC 进了原生 WebView 被吞，到不了 `_handleKeyEvent` → 翻页后退不出书。键盘/手柄/caret 翻页经 `_handleKeyEvent`→`_paginate`、不经这些 JS 手势回调、**不丢焦点**，所以 bug 只在触摸/鼠标翻页后出现，与「翻页以后」完全吻合。`onWillPop` 恒 true 排除了「ESC 到了 handler 但 pop 被拦」的另一种可能。

### 修复（根因修复，非绕过）
所有手势翻页都经纯指针 JS 回调（`onSwipe` 滑动+滚轮 / `onBoundarySwipe` 翻章），键盘/手柄/caret 翻页不经这些回调。在这些手势回调里**夺回阅读器焦点**，与 `onAllPopupsDismissed` 同范式：
- 新增纯谓词 `shouldReclaimReaderFocusAfterGesture({popupVisible, chromeHasFocus})`（`reader_hibiki_page.dart` 顶部）：弹窗可见或底栏持焦点时返回 false，避免把焦点从它们抢走（不破坏查词弹窗 / 手柄底栏导航）。
- 新增 `_reclaimReaderFocusAfterGesture()`：经该谓词把关后 `_focusNode.requestFocus()`。对键盘翻页是无害 no-op（不经手势回调；即便经过，焦点已在 `_focusNode`）。
- 接入 `onSwipe` / `onBoundarySwipe`（修报告本身）+ `onTap` 切栏/无选区分支 + `onTapEmpty`（相邻：点击切底栏后 ESC 同样失效，同一根因）。`onTap` 选区分支不夺（→ 查词弹窗自持焦点）。

### 待验
真机/桌面复测原始失败路径：进书 → 滑动/滚轮翻几页 → 按 ESC 应退出书架；点击切底栏后 ESC 同样应退出；查词弹窗打开时手势不抢焦点。

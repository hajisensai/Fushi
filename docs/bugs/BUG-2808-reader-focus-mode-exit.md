## BUG-2808 · 专注模式下触屏拿不到退出通道
- **报告**：2026-09-30（用户：PR #1790 合并后审查）
- **真实性**：✅ 真 bug。专注模式在触屏上唯一的退出通道是 `onTapEmpty` 弹出的「退出专注模式」提示条（iOS 没有系统返回键，`canPop: false` 又关掉了侧滑，悬浮球阅读器场景的出厂按钮也不含专注模式键）。但有两条没被别的动作消费的正文点击到不了 `onTapEmpty`：
  - VN 模式开了点击推进：JS 把空白点送进 `onVnBlankTap`，`_handleVnBlankTap` 在专注模式下直接 `_paginate` 就 return，不提示（develop `bb0a18be88` `fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart:1306-1309`）；
  - 关了「点击查词」（highlightOnTap=false）：JS 门控 `lookup=false`，点击（含空白）一律走 `onTap`，其 `!highlightOnTap` 分支静默 return（`fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart:2160`）。

  同批低危问题：`_setFocusMode` 无 mounted 守卫、页面 dispose 不关提示条（`chrome.part.dart:1101`、`reader_fushi_page.dart:3097`）；面板「退出」与重导入后退出直接写 `_chrome.focusMode = false` 绕过 `_setFocusMode`，提示条跟到书架页、退场动画里挤压栏重画而 JS inset 未同步（`chrome.part.dart:2251`、`audiobook.part.dart:2215`）；源审查横幅「返回」与未载入页返回键先被 PopScope 截成「退出专注模式」，要按两次（`reader_fushi_page.dart:3518`、`:3654`）。
- **[x] ① 已修复** — `e2d1449c21`：VN 决策表新增 `advanceAndOfferFocusModeExit`（专注模式照常推进并附带提示，页面不再另开短路分支）；`onTap` 的点词关闭分支在专注模式下弹提示；`_setFocusMode` 守 mounted、dispose 关提示条；四个明确退书入口统一走 `_exitBookPastFocusMode()`（关提示条，只在这一次 maybePop 期间让 PopScope 跳过「先退专注模式」那一级，不翻 `focusMode`，所以退场时栏不会重画）。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_focus_mode_guard_test.dart`（决策表 / 生产分派器行为测试 + 按函数体切片的源码守卫：onTap 点词关闭分支、`_handleVnBlankTap` 接线、mounted / dispose、退书助手与四个入口、PopScope 判据）；`fushi/test/pages/reader_exit_maybepop_guard_test.dart` 认可经助手的 maybePop（助手体逐字校验）；`fushi/test/reader/vn_blank_tap_chrome_reveal_bug1195_test.dart` 补齐新必填参数。11 处变异逐一实测均变红。
- **备注**：悬浮球阅读器场景的出厂按钮**未**加专注模式键：提示条已是覆盖所有正文点击的退出通道；出厂按钮对「从没设过按钮」的存量用户同样生效，加了会让他们的球上凭空多出一颗键，需所有者拍板。

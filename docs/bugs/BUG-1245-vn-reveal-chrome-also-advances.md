## BUG-1245 · VN唤出悬浮底栏时误同时推进
- **报告**：2026-07-29（用户）
- **真实性**：✅ 真 bug。`readerVnBlankTapAction()` 在悬浮态完全不读 `_chromeTransientVisible`，无论底栏是否已自动收起都返回 `advanceAndRevealChrome`，所以用户点空白唤出底栏时当前句也同时被跳过。
- **[x] ① 已修复** — 分派新增 `transientVisible`：悬浮底栏隐藏时返回 `revealChrome`（只唤栏），已经可见时才推进并续期；挤压态原行为不变。
- **[x] ② 已加自动化测试** — `vn_blank_tap_chrome_reveal_bug1195_test.dart` 更新真值表并新增隐藏悬浮分支源码守卫，明确该 case 包含唤栏且不含 `_paginate`。
- **备注**：滑动和键盘翻屏不经此空白点击分派，仍可直接推进。

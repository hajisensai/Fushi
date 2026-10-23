## BUG-3703 · 应用外查词窗基础层不显示「制卡目标」切换按钮
- **报告**：2026-10-23（来源：任务 P 真机验证 BUG-3683 时发现；Android 模拟器 API 34 + AnkiDroid 2.25.3，PROCESS_TEXT 拉起 `:popup` 查「猫」）
- **现象**：BUG-3683 的修复说「应用外查词窗打开『制卡目标』切换按钮」，实际 PROCESS_TEXT 弹出的查词窗顶部只有 关闭 / 粘贴 / 搜索，没有切换配置 / 牌组的按钮（uiautomator 节点里也没有 `Switch profile or deck`），用户在应用外仍无法切牌组。
- **真实性**：✅ 真 bug。根因：`popup_dictionary_page.dart` 只把 `showMiningTargetSwitch` 交给 `DictionaryPopupLayer`，按钮画在层顶栏里（`fushi/lib/src/pages/implementations/dictionary_popup_layer.dart:1858`）；而层顶栏在 `headerWidget / onClose / onBack / historyNav` 全为 null 时整条不画（同文件 `:1764` `_buildTopBar` 返回 null）。应用外查词窗的**基础层**这四个恰好全是 null（`popup_dictionary_page.dart:815` `onClose: isBase ? null : ...`，关闭 / 粘贴 / 搜索在页面自己的搜索条上），所以最常见的那一层永远没有这颗按钮，只有点词叠出来的嵌套子层才有。BUG-3683 的单测只断言了参数传进去，没断言按钮真的上屏。
- **[x] ① 已修复** — 待提交（分支 claude/srs-feedback-triage-846294）：「制卡目标」按钮改挂在 popup 页自己的搜索条上（MD3 胶囊、Apple 旧版行、无搜索框的关闭行三种形态都挂，在横滑区之外），基础层与嵌套层共用一颗；层上的 `showMiningTargetSwitch` 改为 false，子层顶栏不再重复。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_dictionary_m3e_top_bar_test.dart`（MD3 / Apple 下 popup 页恰好一颗 `popup_mining_target`、MD3 下在搜索胶囊内）；其余 popup 页测试补了 `popupMiningTargetTestOverrides()`（按钮现在真的挂载）。
- **备注**：Windows 原生 `popup.html` 的切换 UI 仍未做（BUG-3683 备注里已列）。

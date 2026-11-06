## BUG-4193 · 后台任务弹层行贴边 / 复习页窄屏统计卡并排挤压
- **报告**：2026-11-06（用户：「这个后台任务排版是不是有点问题，窄屏也是」+「srs 这两个不要放在同一行在窄屏的时候」，附桌面对话框 / 窄窗底部 sheet / 412 宽复习页三张截图）
- **真实性**：✅ 真 bug。① `fushi/lib/src/sync/background_tasks_indicator.dart:186` `showBackgroundTasksSheet` 用 `FushiModalSheetFrame` 却没给 `bodyPadding`，而框架 body 默认零内边距（`fushi_material_components.dart` `_buildBody`）：任务行贴着弹层左右边缘、波浪进度条画出圆角、末行压底边，对话框与底部 sheet 都中。② `fushi/lib/src/pages/implementations/srs/srs_deck_home.dart` `_SrsHomeStatsPair` 在内容宽 ≥360 时把热力图与未来 7 天并排，手机（412 宽）上热力图只剩三个月、到期图横轴挤掉一半星期。
- **[x] ① 已修复** — 弹层正文给 `EdgeInsets.fromLTRB(24, 0, 24, 16)`（左右对齐 MD3 标题 24）；手机树下两张卡一律上下排，删掉 `_kSrsHomeStatsSideBySideMin`（宽屏双栏 / 三栏的排法不变）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/background_tasks_indicator_test.dart`「明细弹层的任务行与弹层边缘留白」（1280 / 360 宽各一遍，钉左右 ≥24、底 ≥16）；`fushi/test/srs/srs_pages_test.dart`「复习首页（手机）」412 宽断言到期卡在热力图下方且同宽。
- **备注**：未在真 app 上截图复验，靠 widget 测试几何断言。

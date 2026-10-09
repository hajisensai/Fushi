## BUG-3076 · 有声书面板打开时滚离顶部且底部进场过冲
- **报告**：2026-10-07（用户录屏，经 CC 交接任务 3）
- **真实性**：✅ 真 bug。原 `fushi/lib/src/reader/reader_audiobook_panel.dart:1187` 在章节列表 build 时自动定位，`:1144` 经 `FushiFocusScroll.ensureVisible` 连带滚动外层视口，首屏对齐 / 转录入口被推走；原 `fushi/lib/src/reader/reader_desktop_chrome.dart:822` 给底部 sheet 使用欠阻尼弹簧，越过停靠位后回落。
- **[x] ① 已修复** — 打开章节页保持顶部；章节分组提供显式定位按钮，仅滚动自身 ScrollPosition，同章可以重复定位，主动调度后续布局帧。底部进场复用 FushiMotion.enter，侧板继续使用原 M3E 弹簧。修复提交 `055a06bff4`。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_audiobook_panel_open_top_test.dart` 覆盖曲线、逐帧顶边、开顶与外层滚动隔离、真实控制器；`fushi/test/reader/round7_audiobook_motion_test.dart` 覆盖大字长标题手动定位、重复定位及页签快速反切 / 减弱动效 / 墨水屏。
- **备注**：设备原始阅读器路径的肉眼复测待补；widget 像素预览仅证明生产面板组件布局，不等同 Android 真 app 验收。测试退出码与执行数、截图路径详见交接输出报告。
- **跟进（2026-10-09，所有者拍板「条件跟随」）**：首版修复删掉了挂载时的自动定位，连带让播放跨章时章节列表也不再跟随当前章。根因（`FushiFocusScroll.ensureVisible` 连带滚外层）已由「只滚章节列表自身」修掉，故恢复跟随但加条件：`_AudiobookChapterListState.didUpdateWidget` 在当前章变化、且旧当前章行此刻与视口有交集（用户正看章节列表）时才 `_scheduleReveal()`；打开面板不定位，停在顶部资源区时跨章不拉走。测试 `fushi/test/reader/reader_audiobook_panel_open_top_test.dart`「播放跨章：…跟到新章」「…不把列表拉走」（变异实测：去掉跟随即红）。

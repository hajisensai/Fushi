## BUG-3301 · 有声书面板矮视口外层滚动套固定高度内层章节列表，滚不到底
- **报告**：2026-10-11（反馈 k2ykdRRxC3，iOS：有声书抽屉顶部有空隙、无法滚到底显示全部章节；BUG-3076 相邻）
- **真实性**：✅ 真 bug。竖屏 sheet 去掉标题后可用高度 < `kReaderAudiobookPanelPinnedMinHeight`(660) 走「整块面板一起滚」分支：原 `reader_audiobook_panel.dart` 的 `SingleChildScrollView` 里放「正在播放」卡 + 固定高度 `max(320, 0.8×maxHeight)` 的章节 `ListView`。手指落在列表区只滚内层，外层只有按在顶部卡片上才滚，章节列表区永远只能露出一小截（表现为卡片与列表之间的空隙、滚不到底）。
- **[x] ① 已修复** — 矮视口改为单一 `CustomScrollView`：「正在播放」卡作首个 `SliverToBoxAdapter`，章节 `SliverList.builder` 同滚，共用章节控制器（定位逻辑不变）；高度够的钉住分支不变。提交 3806878b74。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_audiobook_panel_test.dart`「矮视口（整块面板单滚动）…」（单竖向 Scrollable + 手指落在列表区拖到底末章完整可见）；`reader_audiobook_panel_open_top_test.dart` 隔离用例去掉对外层滚动存在的断言。
- **备注**：iOS 真机未复测；该反馈的截图附件未下载到，按反馈文字与 BUG-3076 路径推断。

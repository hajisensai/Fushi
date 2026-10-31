## BUG-3915 · subtitle-search-sheet-header-scrolls-away
- **报告**：2026-10-31（用户：合并第三方 PR #2668 前的审查）
- **真实性**：✅ 真 bug（PR #2668 引入）。`fushi/lib/src/pages/implementations/video_remote/video_remote_subtitle_search_sheet.dart` 的 `build` 把整个弹层正文换成 `ListView(shrinkWrap: true)`，结果列表是其中 `shrinkWrap` + `NeverScrollableScrollPhysics` 的内层 `ListView.builder`：任何尺寸下滚结果都会把搜索行一起滚走，且内层列表拿到无界高度、所有结果行一次性全建，懒构建失效。
- **[x] ① 已修复** — 结果改成 `CustomScrollView` 里的懒 `SliverList`；正文高度 ≥ `kVideoRemoteSubtitleSearchPinMinHeight`（200dp）时搜索行固定在结果视口之上，更矮（横屏 + 软键盘）时搜索行并进视口当第一个 sliver 一起滚。两种排法共用一个 `GlobalKey`，键盘弹起触发切换时输入框原样搬家、焦点不丢。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_remote/video_remote_subtitle_search_keyboard_test.dart`（横屏键盘不溢出、高视口滚 60 条结果搜索行原地不动且末行未构建、键盘切换后同一 `EditableTextState` 仍持焦点）。
- **备注**：没用 `PinnedHeaderSliver` 叠在结果上方，因为要给搜索行垫一层与弹层同色的不透明底（MD3 / Apple 玻璃 / 墨水屏三种底不同，玻璃半透明）。

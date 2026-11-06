## BUG-4103 · 卡片来源回跳落点不高亮且回看横幅下正文底部被挡
- **报告**：2026-11-05（用户：开发者本人，应用内反馈 i9n2zSMKgT「跳转回去没高亮 / 而且底下文字看不见」，Android OnePlus CPH2747，截图为小说阅读器竖排分页的「正在回看卡片来源」页）
- **真实性**：✅ 真 bug，两处根因：
  1. 落点不高亮：句子跳转（卡片来源 `fushi://source`、收藏页 / 制卡历史，`Bookmark.charAnchor + charAnchorLength`）在 `fushi/lib/src/pages/implementations/reader_fushi_page.dart` 开书书签分支（`_setOpenResumePoint(... source: 'bookmark preserveSavedPosition=...')`，修前约 :3341）只把句首 / 句尾偏移交给 `restoreToCharOffset` 滚动定位，整条链路上没有任何东西给目标句画标记；回看时用户只能在满屏文字里自己找那一句。
  2. 底部文字看不见：回看横幅挂成 `Scaffold.appBar`（修前 `reader_fushi_page.dart:4313` `appBar: _sourceReviewSession == null ? null : PreferredSize(100, SourceReviewBanner)`），WebView 被压矮「状态栏 + 100」；而分页几何仍取阅读器 State 上下文的全窗 `MediaQuery.size`（`reader_fushi/webview.part.dart:769` `dartPageHeight: screenSize.height`，`_syncPageSize` 同源）与全量系统顶 inset，JS 按全窗高度排版——页底那一条（底部预留 + 末行）落到 WebView 之外，顶部还多留一条状态栏高的空带。
- **[x] ① 已修复** —
  - 新增 `fushi/lib/src/reader/reader_located_range_script.dart`：`window.__fushiMarkLocatedRange(start, end)` 把章内学习单位区间画成 `fushi-search` CSS Highlight（与搜索命中 / 按文本回退的收藏跳转同一种落点标记、同一层窄条）。分页 / 连续按整章走查累加 `countChars`，VN 按当前屏 `nodeStartOffsets`（屏克隆坐标），句子跨屏只标本屏那段。
  - 开书书签分支有句长时记 `_jumpTargetSpan`；`_onRestoreComplete` 落定收尾里与收藏高亮同时机 `_applyJumpTargetMark()`（首开、换样式重分页、宽变重导都会重画）；`_beginNavigation` 去别的章即作废。
  - 回看横幅改为正文 Stack 顶层浮层（高 `_topChromeInset` = 系统顶 inset + 100），`_contentTopInset` / 顶栏 / 悬浮顶栏 / 进度 pill / `popupTopReserve` / 未加载返回键统一排在横幅下沿；WebView 回到全窗，与 `dartPageWidth/Height` 一致。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_located_range_test.dart` + `.js`：真 Chrome 跑生产 JS 12 例（分页/连续整章坐标、跨元素与 ruby、西文按词、节点边界句尾、越界 / 空区间 / 无 CSS Highlight 不画、VN 屏坐标与跨屏截断、重标替换）；源码守卫钉住开书记落点、落定重画、离章作废、横幅不再挂 appBar 且计入顶部预留。
- **备注**：iOS 17.2 前 / 旧 Blink（<120）无 CSS Custom Highlight 时不画落点标记（与搜索命中同一取舍，跳转照常）。VN 换屏后标记随屏 DOM 一起消失，翻回该屏不重画。真机 / 模拟器复测（paginated / continuous / vn 三种 view mode 原始回看路径）本轮未做，待补。

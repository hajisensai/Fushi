## BUG-854 · 移动端选区菜单缺少收藏项
- **报告**：2026-07-16（用户：截图 手机长按选区，弹出菜单只有「搜索 / 复制」，缺「收藏」）
- **真实性**：✅ 真 bug（功能缺口）。选区菜单构建点 `hibiki/lib/src/pages/implementations/reader_hibiki/chrome.part.dart` `_handleSelectionMenu`（移动端自绘拖选）与 `_showReaderTextContextMenu`（桌面原生选区右键）都只出「查词 / 复制 /（有音频时）导出片段」三项，从未接入 app 早有的收藏句子能力（`_toggleFavoriteSentence`，只在阅读器底栏 / 查词弹窗顶栏可达）。
- **[x] ① 已修复** — 两条选区入口各补「收藏」菜单项（`value: 'favorite'` + 复用既有 i18n key `t.action_favorite`，图标 `Icons.star_border` 与底栏收藏按钮一致），并按选区类型正确填「查词状态」后复用同一后端 `_toggleFavoriteSentence`：移动端自绘选区经 `_fillLookupStateFromSelectionData(data, extractNativeImages: false)`（无原生选区）；桌面右键经 `_fillLookupStateFromNativeSelection()`（解析失败退回选中文本满足 currentSentence 非空契约）。提交：`c8253eed9`。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_selection_favorite_menu_guard_test.dart`（源码扫描守卫，钉死两处菜单含 favorite 项 + switch 分支各自填状态后走 `_toggleFavoriteSentence`，且查词/复制老出口零回归；触屏 WebView 手势菜单只能真机跑，故与既有 `reader_mobile_selection_export_menu_guard` 同法用 Dart 源码扫描）。
- **备注**：另一处用户反馈「手机没办法左右选择」（拖选区两端手柄拖不动）经查已在 develop `PR#150`（版本 1.2.0+780，`reader_selection_scripts.dart` `getCaretRange` 补 TEXT_NODE 快路守卫）修复；用户实机需更新到 ≥+780 才生效，非本 bug。若已 ≥+780 仍拖不动，另开真机诊断 bug。

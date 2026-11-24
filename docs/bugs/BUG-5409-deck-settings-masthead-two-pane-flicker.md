## BUG-5409 · 牌组设置页宽窗滚动时页头在大字和小字之间来回切换
- **报告**：2026-11-24（应用内反馈 ONNjqh7wxs，Windows：牌组设置页滚动时页头大字 / 小字来回切换，看起来像突然放大）
- **真实性**：✅ 真 bug。牌组设置页（`fushi/lib/src/pages/implementations/srs/srs_deck_settings_page.dart` 的 `_buildScaffold`，`FushiPageScaffold(masthead: true)`）宽窗走 `SrsAdaptiveSections`（`fushi/lib/src/pages/implementations/srs/srs_ui.dart` 的两栏分支），左右两个 `ListView` 在同一通知深度上各自滚动。页头大字内核 `_FushiMastheadFrameState._onNotification`（`fushi/lib/src/utils/components/fushi_masthead_scaffold.dart`）把**最后一条**竖向 `ScrollUpdateNotification` / 主深度 `ScrollMetricsNotification` 的 `extentBefore` 当成页头偏移：一栏已滚动、另一栏在顶部（或另一栏因展开「高级」、懒加载出新项发版面修正）时，偏移在两栏位置之间来回跳，页头随之收起 / 展开。`FushiPinnedPageChromeScope` 只钉住了「随滚动收起」的浮动页头，没管页头大字的折叠。
- **[x] ① 已修复** — 页头大字内核按滚动区（通知 context）分别记主深度上各竖向滚动区的偏移，页头偏移取其中最大值：任一栏有内容压在页头下就收起，两栏都回到顶才展开；比主深度更深的嵌套竖向列表、已卸载的滚动区不计（`FushiScrollOwnerDepth` 新增 `depth` getter）。单滚动区页面行为不变。改在共享内核，所有用两栏 / 多栏正文的二级页（笔记编辑、笔记类型编辑、模板编辑、字段信息等）一并修好。
- **[x] ② 已加自动化测试** — `fushi/test/utils/components/fushi_masthead_scaffold_test.dart`「并排两栏各自滚动：页头按滚得最远的一栏收起，不在两栏之间来回跳」：左栏滚下去后右栏轻动 / 回顶 / 滚下、左栏回顶，页头都保持收起，两栏都回顶才展开。修复前该测试在右栏轻动那一步红（progress 1.0 → 0.03）。
- **备注**：未在真机上复测（Windows 桌面需要宽窗两栏，组件层测试已覆盖原始失败路径）。

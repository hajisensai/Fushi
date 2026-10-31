## BUG-3892 · 顶栏禁用按钮外观与可用态相同
- **报告**：2026-10-29（用户：薄墨，QQ 群经 fushi-bot 代提，反馈 5JA3m7P9BP；SRS 同步冲突页右上角「全部确认」在只有重复笔记时被禁用，但看不出来）
- **真实性**：✅ 真 bug。`fushi/lib/src/utils/components/fushi_floating_toolbar.dart:340`（基线 896d45a9b2）`FushiToolbarButton.build` 的前景色只看 `item.selected`，三种按钮形态（纯图标 `FushiIconButtonControl` / 带标签格 / 横排胶囊）都把它显式传给 `FushiIcon(color: fg)` 与文字样式；显式色盖掉 IconButton / InkWell 自带的禁用前景，`onPressed == null` 时与可用态像素级相同。共享组件，全应用浮动顶栏 / 工具栏的禁用按钮都受影响（`srs_conflicts_page.dart` 的 `_confirmAllItem` 只是触发点）。
- **[x] ① 已修复** — 036f3c66d8：新增 `fushiToolbarItemForeground`（选中 / 普通前景上，禁用时叠 `kFushiToolbarDisabledForegroundOpacity` = 0.38，MD3 禁用内容不透明度），三种形态统一取它。SRS 冲突页「全部确认」只处理设置冲突、不批量合并重复笔记属于需求（wish），本条不做。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_floating_toolbar_test.dart`（纯图标 / 带标签两种形态下禁用项图标 alpha = 可用项 × 0.38；选中 + 禁用取选中色降透明度）。
- **备注**：widget 测试层验证；未真机截图。

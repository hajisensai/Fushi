## BUG-3783 · srs-two-pane-header-back-lost
- **报告**：2026-10-26（用户：笔记类型编辑页「左上角的回退消失了」，宽窗截图里页头整条不见）
- **真实性**：✅ 真 bug。宽窗两栏表单页（`SrsAdaptiveSections`，`fushi/lib/src/pages/implementations/srs/srs_ui.dart` 两栏分支；模板编辑页 / 字段说明页各自的两栏 Row）两栏各是独立 ListView，滚动通知都冒泡到 `FushiPageScaffold` 的 `FushiScrollAwayController.handleNotification`（`fushi/lib/src/utils/components/fushi_floating_page_chrome.dart`）。长的字段栏往下滚就把页头（含返回键）收起；短的左栏停在顶部、无从「往回滚」，页头再也叫不回来。
- **[x] ① 已修复** — 新增 `FushiPinnedPageChromeScope`：作用域内的滚动区不驱动页头收起（`handleNotification` 按 `notification.context` 判断），三处两栏布局都套上。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_pinned_page_chrome_scope_test.dart`（作用域内滚动不收起 / 作用域外对照组收起）。
- **备注**：窄窗单列不受影响，仍是 M3E「往下滚收起、往回滚出现」。

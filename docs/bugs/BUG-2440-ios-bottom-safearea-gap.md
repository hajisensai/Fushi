## BUG-2440 · iOS 页面底部安全区留下一条不可用空白，滚动内容被硬切
- **报告**：2026-09-10（用户录屏：设置 › 查词 详情页，iPhone）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/components/fushi_material_components.dart:2277`（`FushiPageScaffold` 的 `body: SafeArea(...)` 默认 `bottom: true`）与 `:2374`（`FushiToolScaffold` 同款）——行号为修复前 `develop` 上的位置。
  - 现象：iPhone（home indicator 34pt）上页面底部有一条纯背景色空白，滚动内容在这条线被硬切——卡片边框、文字被切一半，且怎么滚都进不去。
  - 机制：`SafeArea` 把 body 的 viewport 下界硬切在 home indicator 之上，同时通过 `MediaQuery.removePadding` 把 `padding.bottom` 清零；于是
    `settings/material_settings_renderer.dart:94`、`:163`、`settings/settings_home_page.dart:232`、`settings/cupertino_settings_renderer.dart:153`、`utils/components/settings_shared.dart:87` 这几处**已经写好的** `mediaPadding.bottom` 全部恒为 0（死代码）——本来就打算让滚动内容滚过安全区、由内容 padding 兜底，被外层 `SafeArea` 掐掉了。
  - 复现（widget 测试，无需真机）：`size 402×874` + `padding.bottom: 34` 下渲染 `FushiPageScaffold(body: ListView)`，list 底边 = 840 而非 874。
  - 与本仓既有范式一致：BUG-383 / BUG-1783 都把 `SafeArea` 拿掉、改走显式 inset，理由同样是「SafeArea 与内容自己的 inset 重复/打架」。
- **[x] ① 已修复** — 两处脚手架 body 的 `SafeArea` 改 `bottom: false`，底部 inset 交给 body 自己消费，并新增 `bottomSafeInsetOf` / `withBottomSafeInset` 两个 helper。消费侧只补真需要的：显式传 padding 的滚动视图包 helper；`padding == null` 的不动（`BoxScrollView` 自动取 `MediaQuery.padding`）；统计三页尾部 sliver 抽成共用 `buildStatTailSliver`；`Column` 尾部有固定动作条的（mihon 预览、mokuro 嵌入、onboarding）动作条自补安全区、同 `Column` 的滚动视图 `removeBottom`，避免各补一次多顶 34pt；传了 `bottomNavigationBar` 的页面一律不补——`Scaffold` 已把 body 的 `padding.bottom` 清零（`scaffold.dart` 的 `removeBottomPadding`），补了是加 0。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_page_scaffold_bottom_inset_test.dart`：注入 34pt 底部安全区，断言 ① body 铺满到屏幕底（把脚手架改回 `bottom: true` 这条立刻红）② 滚动到底时最后一项完整可见、不被手势条压住 ③ helper 是相加而非取 max ④ 无安全区的桌面形态下是空操作。
- **备注**：桌面 / 无手势条设备上 `padding.bottom == 0`，整套改动为空操作。未在 iOS 真机复测（提交者无 iOS 设备），证据为 widget 层注入安全区的真实渲染像素。

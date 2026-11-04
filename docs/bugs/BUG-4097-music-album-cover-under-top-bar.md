## BUG-4097 · MD3 专辑页 / 单曲详情页首项被悬浮顶栏盖住
- **报告**：2026-11-04（用户：应用内反馈 yglXWr9DTq，Windows，专辑页左上角顶栏挡住封面）
- **真实性**：✅ 真 bug。`FushiPageScaffold` 默认 `extendBodyBehindHeader = true`（`fushi/lib/src/utils/components/fushi_material_components.dart:5013`），MD3 下 `_buildBodyBehindHeader`（`:5296`）把正文铺到悬浮页头底下，页头高度经正文的 `MediaQuery.padding.top` 传下来；`fushi/lib/src/pages/implementations/music/music_album_page.dart:374-383`（修复前） 的 ListView 顶部 padding 写死 `tokens.spacing.gap`，没让出页头。`music_track_detail_page.dart:400` 同样写法、同一问题。另外两页的 padding 用的是脚手架**外层**的 build context，即使加了 `MediaQuery.paddingOf(context)` 也读不到页头高度。
- **[x] ① 已修复** — 两页的 ListView 包 `Builder`（读脚手架给正文的 MediaQuery），顶部 padding 改 `MediaQuery.paddingOf(context).top + tokens.spacing.gap`，与同目录 `musicBrowsePagePadding` 等同一约定。
- **[x] ② 已加自动化测试** — `fushi/test/pages/music_library_page_test.dart`「专辑页 MD3：封面不被悬浮顶栏盖住」：断言首项封面 top ≥ 顶栏 bottom。
- **备注**：真机未复测（本轮不做）。

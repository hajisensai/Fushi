## BUG-5171 · 整理记录页首个分组头与第一行被页头大字盖住
- **报告**：2026-11-21（用户：应用内反馈 SPRCuY_gVh）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/library_organize_history_page.dart:144`（`build`）把 State 自己的 context（在 `FushiPageScaffold` 之上）传给 `_buildList`，`_buildList` 里 `ListView.padding.top = 8 + MediaQuery.paddingOf(context).top`（原 :156）只量到状态栏 / 标题栏。页头大字外壳只在正文子树里把页头高度注入 `MediaQuery` 顶部 padding（`fushi_masthead_scaffold.dart` 的 `FushiMastheadFrame`），所以首个分组头（日期 · 自动 · N 处 + 「撤销本次」）与第一行压在「整理记录」大字下面。与 BUG-4919（音乐二级页）同一机制。
- **[x] ① 已修复** — 正文改为 `Builder(builder: _buildList)`，`_buildList` 拿到的 context 在脚手架正文子树之内，读得到页头让位。
- **[x] ② 已加自动化测试** — `fushi/test/pages/library_organize_history_page_test.dart`「首个分组头与第一行都排在页头下沿之下」（MD3 / Apple 各一遍）：真页面 + 内存库一次整理，断言「撤销本次」所在分组头与第一行改动的 top ≥ `FushiMastheadHeader` 下沿；把 `Builder` 改回 `_buildList(context)` 时两遍都红。
- **备注**：`FushiPageScaffold.body` 仍是现成 `Widget`，调用方在脚手架之上量留白的写法在别的页面可能还有；BUG-4919 当时只把 `musicBrowseScaffold` 改成了构建器。全仓把 `FushiPageScaffold.body` 改成构建器是几百个调用点的改动，本次没做。

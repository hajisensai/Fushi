## BUG-5456 · AI 操作记录页首个会话头与前几行被页头大字盖住
- **报告**：2026-11-25（用户截图：「AI action log」大字压在列表顶部几行上）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/ai_agent_history_page.dart:146`（`build`）把 State 自己的 context（在 `FushiPageScaffold` 之上）传给 `_buildList`，`ListView.padding.top = 8 + MediaQuery.paddingOf(context).top` 只量到状态栏 / 标题栏，读不到页头大字外壳（`FushiMastheadFrame`）只注入正文子树的让位。与 BUG-5171（整理记录页）、BUG-4919 同一机制。
- **[x] ① 已修复** — 正文改为 `Builder(builder: _buildList)`，`_buildList` 拿到的 context 在脚手架正文子树之内。
- **[x] ② 已加自动化测试** — `fushi/test/pages/ai_agent_history_page_test.dart`「首个会话头与第一行都排在页头下沿之下」（MD3 / Apple 各一遍）：真页面 + 内存库一条可撤销记录，断言「全部撤销」所在会话头与第一行的 top ≥ 页头下沿（M3E 量 `FushiMastheadHeader`，Apple 量 `FushiPageHeader` 导航栏行）；把 `Builder` 改回 `_buildList(context)` 时 M3E 那遍红（Apple 二级页走导航栏、不叠放正文，那遍本就绿，留作防回归）。
- **备注**：BUG-5171 备注里的结构性隐患仍在（`FushiPageScaffold.body` 是现成 Widget，调用方在脚手架之上量留白的页面可能还有）。

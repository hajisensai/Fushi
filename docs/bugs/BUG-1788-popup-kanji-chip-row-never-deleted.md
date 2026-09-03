## BUG-1788 · 查词弹窗词头下方的单字 chip 行仍在渲染：删除提交从未合并进 develop
- **报告**：2026-08-23（用户：截图查「理論」，词头下方仍有「理」「論」两个灰方块 chip，「我记得这两个字我删掉了来着」）
- **真实性**：✅ 真 bug。根因不在代码逻辑，而在**交付链路**：删除工作早已完成但从未落地 develop。
  - 仍在渲染的实现：`fushi/assets/popup/popup.js:2690`（`createKanjiBreakdown`）+ `:3538` 调用点（插在 `createEntryHeader` 之后、词条正文之前，正是截图里那一排）
  - 外观：`fushi/assets/popup/popup.css:283` / `:290`（`.kanji-breakdown` / `.kanji-tag`，`min-width:28px; height:28px; 灰底`）
  - 三份镜像（`fushi/assets/popup/`、`fushi/assets/browser_extension/vendor/`、`tools/browser-extension/vendor/`）**行号完全相同、sha256 全同** —— 不是「删一份漏两份」的漂移，是三份都还是旧的。
  - 真正的根因：删除提交 **`851d6089ff`**（2026-08-15，`feat(popup): 词头汉字内联可点替代 kanji-breakdown chip 行 + 压缩顶栏与词头间距`）改了 9 个文件、三镜像同步全到位，但 `git merge-base --is-ancestor 851d6089ff develop` = **NO**：它只活在分支 `worktree-popup-inline-kanji-compact-header` 上，`gh pr list --head` 查不到任何 PR —— **从没开过 PR，也从没合并**。于是旧 UI 在 develop 上原封不动继续跑了 8 天。
- **[x] ① 已修复** — `851d6089ff` cherry-pick 到当前 develop 基底（干净落地零冲突），三件事整体恢复：
  1. 删除 `createKanjiBreakdown` chip 行；
  2. 词头里每个汉字自身成为跳转目标（`wrapExpressionInlineKanji` + `.kanji-inline` 淡点线 affordance），包裹 pass 挂在 `postProcessRuby` 尾部，幂等、只切 `.expression` 文本节点，不触碰 ruby-unit/rt 锚定与选区活文本；
  3. 顶栏贴近词头：无 header 顶栏 40→36（贴住 36×36 的 `_topActionConstraints`，命中区零缩水）、首词条 `padding-top` 8→0。

  落地后复核：三镜像 popup.js / popup.css sha256 各自全同；`content.css` 重跑 `generate-content-css.mjs` 输出**逐字节相同**（不是陈旧生成物）；`wrapExpressionInlineKanji(container)` 确认落在 `postProcessRuby` 函数体末尾（21 个提交的漂移没挪歪插入点）；`_topActionConstraints` 确认仍是 36×36（顶栏 36 的前提成立）。`flutter analyze` 零问题。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/popup_inline_kanji_guard_test.dart`（16 个断言，提交 `d797776e60`）
  - 禁止型：三份 popup.js 不得再有 `createKanjiBreakdown`；三份 popup.css + 两份 content.css 不得再有 `.kanji-tag` / `.kanji-breakdown` 规则。
  - 要求型：`wrapExpressionInlineKanji` 必须已定义，且调用必须落在 `postProcessRuby` **函数体内**（`methodBody` 锚定，`SourceLexicon.js`）—— 挂到别的函数上会让延迟渲染的尾部词条静默失去可点性，而文件级 `contains` 照样绿。
  - 全部断言跑在**掩码后**的语料上（`maskCssComments` / `containsIdentifier`）：三份文件的注释里至今写着 `kanji-breakdown` 与 `kanji-tag` 用来说明这段历史，裸 `contains` 会被注释喂成假红。
  - 变异实测（每次还原后 sha256 逐字节校验）：① `.kanji-inline` → `.kanji-tag`：只有被改的那份镜像红、另两份保持绿（逐镜像精度）；② 调用移出 `postProcessRuby` 但仍留在文件里：文件级断言绿、体内断言红（证明 `methodBody` 锚定在干活）；③ 注释里塞入 `.kanji-tag` / `.kanji-breakdown`：保持绿（掩码生效，无假红）。
- **备注**：这条的教训不是代码层面的。三镜像彼此一致（都是旧的），定向测试按功能域挑也挑不到一个「本该不存在」的函数 —— 代码层面**没有任何东西**能发现「删除从未落地」。真正的缺口是「改完 → 开 PR → 合并」这条链断在第二步且无人告警。守卫测试补上的是「chip 行已死」这个不变式，但它只在删除**已经落地之后**才能防复活；防不住「下一个删除又停在孤儿分支上」。同批扫描发现的其它未落地分支另行处置。

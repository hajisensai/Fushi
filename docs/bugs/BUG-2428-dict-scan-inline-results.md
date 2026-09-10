## BUG-2428 · 查词页源文本条点字压嵌套浮层，没有换下方的查词结果
- **报告**：2026-09-10（用户：源文本条的 Yomitan 式点选查词「还是选中往后扫描、在此基础上嵌套查词，实际上要做的是改变下面的词典查询结果而不是嵌套查」）
- **真实性**：✅ 真 bug。两个宿主各错一半，合起来正好是「扫描没落到那份结果上」：
  - 首页词典 tab：`home_dictionary_page.dart` 的 `_lookupFromSourceStrip` 走
    `_pushNestedPopup(query, screenRect, reuseWarmSlot: true)`——点一个字压一张**浮在
    那个字上的查词卡**。页面本体那份结果（`DictionaryPopupWebView(result: _result!)`）
    与弹窗栈是两棵独立子树，卡片起来了，下方那份结果仍停在上一个词上：同一次查词
    裂成两个可见面，条上的高亮指着 A、页面下半屏还写着 B。
  - Android 独立查词窗：`popup_dictionary_page.dart` 的 `_pushSearch` 每次都
    `_sourceLookupText = trimmed` / `_searchController.text = trimmed`，把条上与框里的
    整句换成「被点字起的后缀」。在「と言いつつ」上点「つ」，条上只剩「つつ」——被点字
    左边的上下文当场消失，用户再想点回「言」已经没得点。Yomitan 的扫描是整句不动、
    只挪高亮。
- **[x] ① 已修复** — 源文本条点字改走**主查词管线**：条上的整句与搜索框里的整句都不动，
  换的是下方那份结果 + 条上的高亮跨度。
  - `home_dictionary_page.dart`：`_search` 新增 `scanAnchor`（`SourceLookupScan`），
    它同时表示「本次不接管搜索框/源文本条」与「高亮锚在哪个字素簇」；`_pushNestedPopup`
    从源文本条这条入口摘除（结果 WebView 内部选词/点链仍走弹窗栈，未动）。
  - 顺带三处根因，都是这次改动才暴露出来的既有耦合：
    - `_searchWithGeneration` 的过期守卫原本比 `trimmed != _controller.text`，对
      「查询串恒等于输入框」的老路径成立，对扫描查词（框里整句、查询串后缀）恒不成立，
      会把自己的结果全丢掉 → 改比**派发那一刻**的输入框内容（`inputTextAtDispatch`）。
    - 朗读原本写在 `if (writeHistory)` 里，等于拿「要不要记历史」代答「要不要读」。
      扫描查词要读、又不该把用户点过的每个字灌进历史 → 拆成独立的 `autoReadResult`。
    - `_loadMore` 原本拿 `_controller.text` 去加载更多，扫描查词后那是整句而非眼下这份
      结果的查询串，滚到底会把结果**掉包**成另一个词的 → 改用当前查询串。
  - `popup_dictionary_page.dart`：`_pushSearch` 新增 `scan` 参数，非空时不接管条与框，
    高亮锚改成被点的那个字素簇（此前恒 0）。
  - `clipboard_lookup_text_panel.dart`：新增 `SourceLookupScan`（查询串 + 高亮锚的绑定）
    与 `SourceLookupScan.fromSuffix`（把串首空白折进锚——查词管线一律 `trim`，锚不右移
    就会框在空白上）。
  - 提交见本分支 `pr/dict-scan-inline-results`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_dictionary_source_scan_test.dart`
  （4 条：点字后引擎吃后缀而条与框留整句、栈深恒 0；扫描后「加载更多」不掉包；点回条首；
  源码守卫钉住 onLookup 不再压浮层）+ `fushi/test/pages/popup_dictionary_page_test.dart`
  的「点第 3 个字后条与搜索框仍是 `abcdef`、高亮锚 = 2」+
  `fushi/test/widgets/clipboard_lookup_text_panel_test.dart` 的
  `SourceLookupScan.fromSuffix` 4 条纯逻辑。
- **备注**：与 BUG-1478（查词是「从被点字到串尾」的后缀交给引擎最长匹配）同一条链路的
  下游；那条决定「查什么」，这条决定「查出来的落在哪」。

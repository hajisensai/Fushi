## BUG-2555 · 在线漫画查词前串行等待制卡页物化
- **报告**：2026-09-15（用户：「查词弹窗反应很慢」；同批还报了 BUG-2553，用户感知的「慢」大概率叠加了「第一次点只关栈、第二次才查」）
- **真实性**：✅ 真 bug（在线章节可复现的额外延迟；本地卷不受影响）。点字到弹窗的链路与小说页一致（JS 命中 → `onTextSelected` → `processMangaSelection` → `dispatchMangaSelection` → `searchDictionaryResult` → 热槽弹窗），没有重建 WebView、没有重解析 OCR JSON、没有 debounce。漫画特有的一段：`dispatchMangaSelection` 在查词**之前** `await selectPageForMining(...)`（原 `fushi/lib/src/media/manga/reader/manga_fushi_page.dart:273`）；本地导入是同步路径，但在线章节里 `_selectPageForMining` 会 `await session.localFile(pageIndex)` + `file.exists()`（`:3753-3760`，Mihon/Aidoku provider 的 `_validatedFile`）——这是点「+」制卡才需要的信息，却把词典查询整个串在磁盘/缓存往返后面。
- **[x] ① 已修复** — `dispatchMangaSelection`（`manga_fushi_page.dart:277`）改成先发起制卡页物化、立即设句并查词、返回前再等物化收尾：查词不再被它挡住，调用方「返回即两者都落地」的语义不变；页面侧既有 `_miningPageGeneration` 代次守卫保证慢的旧物化不会覆盖新点击。提交：`44a9937c03`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/manga_selection_dispatch_test.dart`「BUG-2555：查词不等制卡页物化」：用 Completer 卡住物化，断言 `search` 在物化完成前就被调用、dispatch 在物化完成前不返回。
- **备注**：词典 FFI `FushiDicts.instance.lookup` 在 UI isolate 同步跑（`app_model.dart:5619-5622`）是全应用共性，不在本条范围。若用户复测仍觉得慢，请对比小说阅读器同一词的弹窗延迟——一致则是共性问题，另立项。

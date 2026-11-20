## BUG-4906 · web-novel-tail-chapter-snapshot-desync
- **报告**：2026-11-20（路线图 #3722 gap-novelmisc-3，c25）
- **真实性**：✅ 真 bug。网页小说书阅读器取末尾「下一章」占位时，`WebNovelChapterLoader.loadChapter`（`fushi/lib/src/media/novel/web/web_novel_library.dart`）先 `writeAtomically` 正文文件、再 `reparseExtractedBook` + `updateEpubBookMihonState` 写快照；两步之间失败 / 被杀，文件已是正文而书行快照仍停在旧章数、`tailNext` 仍指这一章。旧判据 `if (!file.readAsString().contains(kLnReaderPendingChapterAttribute)) return null` 只看文件，于是这章永远短路不再取页，快照永远补不齐；开书时 `ensureTrailingPlaceholder` 又因 `row.chapterCount > snapshot.chapters.length` 不补新占位——这本书再也追不了更。
- **[x] ① 已修复** — 「已取过」改以快照为准：文件非占位、但章号恰等于快照章数且快照有 `tailNext`（快照落后于文件）时按占位处理，重新取页 → Rust 并章 → 补写快照与 spine 字数表。快照里已有的章仍直接短路，不多取。
- **[x] ② 已加自动化测试** — `fushi/test/media/novel/web/web_novel_library_test.dart`「BUG-4906：…」：真 Rust 会话 + 真页面快照，取章成功后把书行回滚到取章前（复现中断后的落盘状态），断言下一次请求会重新取页、快照补到 2 章、开书补出新占位（修复前不取页、快照停在 1 章、补占位返回 false）；另加「已取过且快照里有的章：不取页」钉住不多取。
- **备注**：取页失败时阅读器照常下发已在盘上的正文，并按现有逻辑提示取章失败；下次进这一章再试。

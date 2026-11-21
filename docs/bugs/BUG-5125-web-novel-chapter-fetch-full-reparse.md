## BUG-5125 · web-novel-chapter-fetch-full-reparse
- **报告**：2026-11-22（外部审计 HBK-AUDIT-040，Codex 2026-11-21 PR 审查，涉及 PR #3805）
- **真实性**：✅ 真 bug（基线 cbdc2a45ed）。阅读器每追回一章，`web_novel_library.dart:663` 都调 `EpubImporter.reparseExtractedBook`：`epub_importer.dart` 的 `_reparseExtractedInIsolate` → `_computeCharacterCounts` 逐章读全部正文、原生重扫字数，再整表编码 / 解码 `chaptersJson`。单次代价随书长线性增长，连续追 N 章累计 O(N²) 章读。实测（`packages/fushi_engine`，每章约 4000 字，5 次平均）：整本重解析 N=100 / 200 / 400 章 = 97.6 / 179.8 / 329.0 ms；只重数改过的章 = 17.4 / 20.6 / 30.8 ms。
- **[x] ① 已修复** — eb04d36a7f（`EpubImporter.reindexExtractedBook`）+ 784eb9c35b（追章改用它）：只重读 OPF（章节正文本就是懒读），字数只对本次写过的章（`changedHrefs`）以及旧 `chaptersJson` 里没有（新续挂的占位）/ 口径版本不是 `kChapterCharCountCaliber` 的章重算，其余按 href 沿用书行里的；章节 id / href / mediaType 仍以本次 OPF 为准。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/epub/epub_reindex_extracted_test.dart`（沿用 / 重数 / 口径过期 / 坏 JSON 全部重数，与整本重解析逐项对照）；`fushi/test/media/novel/web/web_novel_library_test.dart`「HBK-AUDIT-040：追章只重数这一章与新占位的字数…」（第 1 章文件被改大而书行沿用旧字数 = 没有重读）。变异实测：追章改回 `reparseExtractedBook` 后该条变红。
- **备注**：`chaptersJson` 整列 JSON 编解码仍是 O(N)（每章一条小记录，不读正文），要再省得改 schema，收益不值；浏览器并章 / 开书补占位仍整本就地重建（每次用户操作一次，不是追章热路径）。

## BUG-492 · 收藏/制卡写错 sectionIndex 致跳错章看不到收藏句
- **报告**：2026-07-01（用户：）
- **真实性**：✅ 真 bug。写入端 provenance 错误。收藏/制卡写入时 section 取自
  `_lookupSectionIndex`（`audiobook.part.dart:742-749` 返裸 `_currentChapter`「当前渲染章」）；
  有声书连续推进 / 跨章滚动在「选中该句」与「点收藏/制卡」之间异步改写 `_currentChapter`
  （`audiobook.part.dart:411/433/456`）→ 把第 N 章的句子记成第 N+1 章 sectionIndex。恢复端
  （`reader_hibiki_page.dart:1370` 先 `_currentChapter=bm.sectionIndex` 再 `_loadChapterDirectly`
  忠实加载错章 DOM）→ charAnchor 在错章内是合法值 → `scrollToCharOffset` 安静停错位≈36%，
  用户看不到收藏句。写入点：`chrome.part.dart` 收藏 toggle、`mining.part.dart:333` 制卡历史。
- **[x] ① 已修复** — 根因修复：新增选区时刻章号快照 `_cachedSelectionSectionIndex`
  （`reader_hibiki_page.dart`），在三个选区缓存点（`lookup.part.dart` 主 onTextSelected 路径 +
  歌词 cue 路径、`chrome.part.dart` 原生选区路径）与 `_cachedSentenceRange` 同批原子写入；新增
  消费 getter `_favoriteSectionIndex`（快照优先、无快照回退当前 `_lookupSectionIndex`），收藏
  toggle（`chrome.part.dart`）、制卡（`mining.part.dart`）、isFavorited 查询（`lookup.part.dart`）
  三处改用它。另加恢复端越界兜底：`reader_pagination_scripts.dart` 共享 `charOffsetInRange`
  判据，分页 + 连续两 shell 的 `restoreToCharOffset` 对越界 charAnchor 回退章首（护住旧脏收藏
  记录，不静默停错位）。无需数据迁移。提交 <FIX-COMMIT>。
- **[x] ② 已加自动化测试** — 源码守卫 `hibiki/test/reader/favorite_write_section_source_guard_test.dart`
  （断言快照字段/getter 存在、三写入点消费 `_favoriteSectionIndex` 非裸 `_lookupSectionIndex`、
  三选区缓存点同批快照、两 shell 恢复端有越界回退）。行为级跨章滚动后收藏留真机焦点驱动
  （不在本轮跑设备）。
- **备注**：TODO-1053 Bug A。

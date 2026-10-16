## BUG-3429 · 从对端下载的书落地键不同导致跨设备删除丢失
- **报告**：2026-10-15（排查 BUG-3443 同类问题时发现；用户要求一并修）
- **真实性**：✅ 真 bug（沿代码路径确认，边界条件触发）。
  - 从对端（互联或云盘）下载的 EPUB 由 `EpubImporter` 重新推导本机 bookKey：`sanitizeTtuFilename(元数据标题)`，撞名时加后缀（`packages/fushi_engine/lib/epub/epub_importer.dart:128-144`）。它**不一定等于** host 的 bookKey。两种触发方式：
    1. host 上有同名书、键带 `(2)` 后缀，client 下载后推导出不带后缀的键（反过来同理），host 侧注释 BUG-1503 也承认这一点；
    2. EPUB 没有 `dc:title` 时回落到文件名，而互联下载用的临时文件名把非 ASCII 字符全部替换成了 `_`（`fushi/lib/src/pages/implementations/reader_history/remote.part.dart` 的 `_safeRemoteBookKey`）。
  - 配套的有声书沿用本机 EPUB 键（`bookKeyOverride: localBookKey`），所以一起错位。
  - 后果：`book` / `audiobook` 删除墓碑两个方向都对不上。host→client 求交为空，不弹确认框；client→host 时，host 的 `deleteAudiobook` 只按 bookKey 精确匹配，书则只能靠书名兜底。
  - 现成的对应表 `collection_book_aliases`（本机 uid → 对端键）只在书属于某个合集时才写（`packages/fushi_engine/lib/sync/remote_collection_adoption_service.dart` `adoptBook` 开头的 `collection == null` 早退）。
- **[x] ① 已修复** — `352bec9234`：
  - `adoptBook` 在下载入库时（`localBook` 由 importer 实际返回）只要落地键 ≠ 对端键就写别名，不再限于合集成员；目录刷新路径不变。
  - 新增 `FushiDatabase.syncDeletionBookKeyOf` / `getPeerToLocalBookKeys`。
  - `ReaderFushiSource.deleteBook`（删行前取，`deleteEpubBook` 会级联删别名）和 `AudiobookRepository.deleteAudiobook` 改为用对端键写墓碑。
  - 消费端用 `aliasPeerBookTombstones`（`fushi/lib/src/sync/peer_book_tombstone_alias.dart`，与 BUG-3443 共用）把 `book` / `audiobook` 两类墓碑经别名表换算回本机键，互联 live 和云盘两条通道都覆盖。
- **[x] ② 已加自动化测试** —
  - `fushi/test/sync/remote_collection_adoption_service_test.dart`：无合集也记别名；目录刷新不记；`syncDeletionBookKeyOf` / `getPeerToLocalBookKeys` 换算。
  - `fushi/test/media/sources/reader_fushi_source_test.dart`：带别名的书删除时墓碑写对端键。
  - `fushi/test/sync/peer_book_tombstone_alias_test.dart`：book 和 audiobook 都经别名表换出候选；别名指向不在库的行时不追加。
- **备注**：
  - 只对修复后新下载的书生效：存量已下载、当时又不在合集里的书没有别名，事后按对端键反查恰好查不到，无法自动补。
  - 别名同时是合集 / 标签的 wire 键来源（`CollectionBookIdentityIndex`），所以这类书的合集成员和标签今后以对端键发布，与 host 对齐；以前用的是本机键，对端认不出。
  - 真机复测待补。

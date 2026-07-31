## BUG-1305 · 删除确认文案与真实删除范围对不上（书架递归删解压目录+有声书；合集正文说反话）

- 状态：已修复
- 报告：TODO-2180（用户）
- 平台：全平台
- 严重度：高（数据丢失风险 + 欺骗性 UI）

### 现象

用户以为只是把条目从书架移除，实际磁盘上 app 管理的解压目录和配套有声书目录被递归
删除；确认框只字未提。合集删除更进一步：正文说的和代码做的相反。

### 根因（三处，同族）

1. **书架删除确认只有一句条数 + 不可撤销，未披露真实删除集合。**
   - 文案：`batch_delete_confirm` = `Delete $n book(s)? This cannot be undone.`
     （`hibiki/lib/i18n/strings.i18n.json`），单删是 `srt_delete_confirm`。
   - 真实删除：`hibiki/lib/src/media/sources/reader_hibiki_source.dart:863`
     `AudiobookStorage.deletePersistDir(bookKey)`、`:865` 同函数再删 `srt.uid`、
     `:870` `EpubStorage.deleteBookDir(extractDir)`；底层两处均为
     `Directory.delete(recursive: true)`
     （`hibiki/lib/src/epub/epub_storage.dart:67`、
     `packages/hibiki_audio/lib/src/audiobook/audiobook_storage.dart:223`/`:229`）。
   - 用户 picker 选择的原始 EPUB/字幕/音频不删（`epub_books.epubPath` 只存文件名，
     删除路径从不据它删文件）。

2. **「移除已附加的有声书」说移除、做递归删除。**
   - 文案：`audiobook_remove_confirm` = `Remove the attached audiobook?`
     （`hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart:998` 引用）。
   - 真实行为：`packages/hibiki_audio/lib/src/audiobook/audiobook_repository.dart:81`
     → `AudiobookStorage.deletePersistDir` 递归删整个持久化目录（音频副本 + 对齐字幕）。

3. **合集删除确认框正文写死为视频专属句，且不随勾选变化——在书库里说的是反话。**
   - 正文：`delete_collection_confirm` 旧值 =
     `Deleting the collection won't delete its videos.`，被
     `hibiki/lib/src/media/collections/collection_context_dialog.dart:208` 与
     `hibiki/lib/src/pages/implementations/collection_detail_shared.dart:122`
     无差别用于书 / 视频 / 游戏三个库页。
   - 结构性根因：`hibiki/lib/src/utils/components/hibiki_destructive_confirm_dialog.dart:87`
     的正文与 `:88` 起的勾选行是两个静态节点，`setState` 只翻 `_checked`，正文永不
     随勾选重绘。于是勾上后同屏并存「删除合集不会删除其中的视频」+「同时删除其中的书」，
     而代码按勾选走
     `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:1727`
     `_deleteCollectionMembersMedia` → 递归删每本书的解压目录与有声书目录。

### 修复

- [x] ① 根因修复
  - 新增 `hibiki/lib/src/sync/deletion_disclosure.dart`：结构化披露
    `DeletionDisclosure{willDelete, willKeep}` + 纯函数 `buildDeletionDisclosure`
    + 共享渲染 `DeletionDisclosureView`。确认文案不再由各调用点手写一句笼统正文。
  - 书架单删 SRT / 单删 EPUB / 批量删（`reader_history/books.part.dart`）、合集
    「同时删除其中的书」两个入口、有声书删除，全部挂上披露。
  - `HibikiDestructiveConfirmDialog` 增 `checkedDisclosure`，由 `_checked` 门控，
    正文随勾选重绘——消除「正文与勾选说反话」的结构成因。
  - `delete_collection_confirm` 改为域中立且为真：`Only the grouping is removed.
    The items in it are kept.`（17 语言全量替换，不再提视频）。
  - `audiobook_remove` / `audiobook_remove_confirm` → `audiobook_delete` /
    `audiobook_delete_confirm`，措辞改为「删除」并说明音频文件会从本机删除。
  - 纯解散合集（批量删里 `mediaCount == 0`）不挂披露：它确实不碰媒体本体。
  - 提交：见 PR 分支 `worktree-2180-delete-disclosure`。

- [x] ② 自动化测试
  - `hibiki/test/pages/deletion_disclosure_test.dart`（8 例，三层 + 一条行为锚）：
    widget 层锁披露真的渲染且随勾选联动；源码扫描层锁每个递归删磁盘的确认入口都挂
    披露、且披露由 `_checked` 门控；i18n 层锁 17 语言合集正文不再是视频专属句、
    有声书措辞已改 delete；行为锚证明 `deleteBookDir` 真递归删且不碰目录外文件。
  - 变异实测：删 `_checked &&` 门控 → 红；删披露里的有声书那一项 → 红；把
    `delete_collection_confirm` 改回 video 措辞 → 红；三次反向还原后均转绿。

### 残留 / 未做（需另立项）

- 「从所有设备删除」勾选框有两个死角，**不在本次修复范围**（属同步层实质功能，且与
  PR#594 的 schema 串行冲突组）：
  - 纯 SRT 书（`bookKey` 为空）勾了完全不写墓碑：`reader_history/books.part.dart:819`
    只有 `book.bookKey.isNotEmpty` 分支才传 `scope`；`SyncTombstoneKind`
    （`packages/hibiki_core/lib/src/database/sync_tombstone_kind.dart:13`）无 SRT 取值，
    `SyncOrchestrator._collectPresentDeletionKeys`（`hibiki/lib/src/sync/sync_orchestrator.dart:780`）
    与 `AppModel._applyConfirmedDeletions`（`hibiki/lib/src/models/app_model.dart:594`）
    也都无 SRT 分支——三环全缺。
  - 未配置任何同步后端时勾选框照常可勾，墓碑真写进本地表但发布通道在
    `hibiki/lib/src/sync/sync_auto_trigger.dart:232` 被 `isAuthenticated` 挡掉，
    用户零反馈；且日后配上后端会集中补发历史墓碑（无 GC）。
- `EpubStorage.deleteBookDir`（`hibiki/lib/src/epub/epub_storage.dart:63`）无
  `p.isWithin` 归属护栏（`VideoStorage` 同类函数有）。当前所有 `extractDir` 写入点都
  钉在 `hoshi_books` 内故不可达，属加固缺口。
- 合集自有封面只在 `collection_context_dialog.dart:218` 回收，详情页与批量解散路径
  不回收 → 文件泄漏（漏删，非误删）。

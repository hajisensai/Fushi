## BUG-1338 · 「从所有设备删除」两个死角：纯字幕书无效、无同步后端时静默无效
- **报告**：2026-08-01（用户：两种情况下用户都以为删干净了，实际没有）
- **真实性**：✅ 真 bug（两个死角均沿真实代码路径复核确认，PR#636 有意未做的部分，看板 TODO-2470）

  **死角① 纯字幕书**：`hibiki/lib/src/pages/implementations/reader_history/books.part.dart:558`
  （批量）与 `:837`（单删）删一本 SRT 书时分两步——`bookKey` 非空才调
  `ReaderHibikiSource.deleteBook(scope:)` 写 `book` 墓碑，然后无条件
  `SrtBookRepository.delete(uid)`。而
  `packages/hibiki_audio/lib/src/audiobook/srt_book_repository.dart:156` 当时**没有传播
  参数、从不写墓碑**。于是**纯字幕书 / standalone SRT**（`bookKey` 恒空、无 EpubBooks 行、
  无 Audiobooks 行）只走第二步，用户勾的 `DeleteScope` 被静默丢在地上。srt-backed 的字幕书
  （有配对 EPUB）因为走了第一步，勾选是有效的——只有纯字幕书失效，恰好对上用户报的症状。

  传播对这类书**有意义且身份键早已确定**：`hibiki/lib/src/sync/app_model_library_host_service.dart:660`
  明文规定「纯 SRT（standalone）有声书：身份键 = uid」，接收端导包
  `hibiki/lib/src/sync/sync_asset_package_service.dart:248,316` 逐字保留 uid 不重新生成。
  所以 uid 是稳定跨设备身份，这不属于「书签/Profile 那种无同步前提、结构性做不了」。

  **死角② 无同步后端**：勾选框的**存在**被硬编码成恒真，与「本机到底有没有传播通道」无关
  （`hibiki/lib/src/sync/deletion_prompt.dart:70` 无条件渲染；
  `hibiki/lib/src/pages/implementations/reader_history/dialogs.part.dart:14` 虽有
  `showSyncScope` 逃生口，但**生产代码从未传过 false**，是个死参数）。一个后端都没配时勾上
  → 墓碑写进本地表、`remotePublishedAt` 永远 0 → 无人发布 → 静默无效、零提示。

- **[x] ① 已修复** — 两个死角分别根治，**无 schema 迁移**（墓碑表 `media_type` 是文本列，
  新增种类只是新增一个枚举值；看板上记的「与 PR#594 抢 DB 版本号」这条依赖核实后不成立）。

  死角①：新增 `SyncTombstoneKind.srtbook`
  （`packages/hibiki_core/lib/src/database/sync_tombstone_kind.dart`）；
  `SrtBookRepository.delete(uid, {propagateDeletion})` 写墓碑（范式照同包
  `AudiobookRepository.deleteAudiobook`，用 bool 而非 `DeleteScope`，避免 hibiki_audio
  反向依赖 app 层），`save()` 清墓碑防「删了又加、墓碑还在」；两个书架调用点传
  `scope == syncEverywhere`；`SyncOrchestrator._collectPresentDeletionKeys` 收 srtbook 在库键；
  `AppModel._applyConfirmedDeletions` / `_resolveDeletionViews` 补消费与标题解析（穷尽
  switch 由编译器强制）。发布层与 host `/api/tombstones` 按行泛化，零改动。

  **互斥不变量**（写墓碑与在库键**同一判据**，两侧都只认 `bookKey` 为空的行）：身份键 = uid
  ⟺ standalone。srt-backed 行身份是 bookKey、墓碑走 `book` 种类；两侧任一多收一次，同一
  资产就会在对端弹出两条重复的删除确认。墓碑写在 `deletePersistDir` **之前**——DB 行是唯一
  真相源，磁盘清理是尾活，Windows 上句柄占用抛 errno 32/145 时不该把用户的删除意图一起吞掉
  （同 TODO-1359 那类「尾活失败翻转结果」的坑）。

  死角②：新增 `hasDeletionPropagationChannel`
  （`hibiki/lib/src/sync/deletion_propagation_availability.dart`）——通道枚举**直接复用**
  `enabledSyncChannelBackends`（因此它不再是 `@visibleForTesting`），每条通道满足
  `SyncRepository.hasStoredBackendConfig`（7 后端穷尽 switch，纯 preferences 读）或
  `backend.isAuthenticated`（内存态，补移动端 Google 登录态不落 prefs 的缺口）即算存在。
  `SyncChannel` 补 `type` 字段以承载这次询问。两个删除确认框在弹出**之前**解析该判据，无通道
  时把勾选框换成共享的 `DeleteScopeUnavailableNote` 说明行、恒 `keepLocalOnly`。

  两条硬约束：**零网络**（跑在 UI 路径上，绝不调 `restoreAuth`——互联后端的 `restoreAuth`
  会探测对端地址）；判据语义是「配置过」而非「此刻连得上」（离线删东西时墓碑留在本地等下次
  发布是正确行为，不该因当下离线就把选项藏起来）。

- **[x] ② 已加自动化测试** — 4 个文件，共 25 条，全绿；两处关键实现做过**变异实测**
  （变异后精确变红、反向替换还原）：
  - `hibiki/test/sync/srt_book_deletion_propagation_test.dart`（5）——standalone 写碑 /
    默认不写 / srt-backed 不写 / 删 0 行不写 / 重导清碑。变异（禁用写碑）→ 2 条转红。
  - `hibiki/test/sync/srt_book_tombstone_sync_test.dart`（5）——真跑
    `SyncOrchestrator.syncDeletionTombstones`：发布 + 消费产候选 + srt-backed 不产候选 +
    已收敛不产 + 基线守卫。变异（在库键漏收 srtbook）→「产出候选」那条精确转红。
  - `hibiki/test/sync/deletion_propagation_availability_test.dart`（10）——判据真值表：
    零配置 / WebDAV / 「选中≠配置好」/ 互联 client / 互联 host+对端 / host 无对端 /
    Drive rootFolderId，以及 7 后端零配置一律 false（新增后端漏表态会在此暴露）。
  - `hibiki/test/sync/delete_scope_no_channel_widget_test.dart`（5）——两个删除确认框
    **各测一遍**（它们是两份独立实现，只修一个是这类死角最常见的复发方式）+ 一条端到端
    （传零配置真 DB → 弹窗自己查出无通道并收起勾选框）。

- **备注**：i18n 新增 1 键 `delete_scope_no_channel`（经 `tool/i18n_sync.dart` ×17 语言）。
  向前兼容由既有设计保证：老版本 app 读到 `srtbook` 远端标记时 `SyncTombstoneKind.tryParse`
  返回 null，`_applyConfirmedDeletions` 走 `case null` 跳过并留痕，不会误删。
  **刻意不动**：`_deleteCollectionMembersMedia`（合集删成员本体）那条路径的弹窗是「也删成员
  本体」勾选框，本就不提供删除范围选择，恒 `keepLocalOnly` 是正确语义，不是第三个死角。
  实现计划见 `docs/specs/delete-propagation-all-entities/deadangles-plan.md`。

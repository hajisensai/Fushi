# 「从所有设备删除」两个死角的根因修复计划（TODO-2470）

> 主计划 `plan.md` 交付了删除传播主体；本文件只处理它**有意未做**的两个死角。
> 结论先行：**两个死角都不需要 schema 迁移**（墓碑表 `mediaType` 是文本列，新增种类只是新增
> 一个 `SyncTombstoneKind` 枚举值），因此与 PR#594 的 DB 版本号竞速**不存在**——看板上
> 记的那条依赖是基于「要加表/加列」的猜测，核实后不成立。

## 死角① 纯字幕书勾了完全无效

### 根因（`file:line`）

书架删一本 SRT 书走两条分支（`hibiki/lib/src/pages/implementations/reader_history/books.part.dart:552`
批量、`:837` 单删）：

```dart
if (book.bookKey.isNotEmpty) {
  await ReaderHibikiSource.instance.deleteBook(..., scope: scope);   // ← 'book' 墓碑
}
await repo.delete(uid);                                             // ← scope 被丢弃
```

- **srt-backed 书**（有配对 EPUB，`bookKey` 非空）：`deleteBook` 记 `book` 墓碑，勾选**有效**。
- **纯字幕书 / standalone SRT**（`bookKey` 恒空、无 EPUB 行、无 Audiobooks 行）：只跑第二行，
  而 `SrtBookRepository.delete`（`packages/hibiki_audio/lib/src/audiobook/srt_book_repository.dart:156`）
  **没有传播参数、从不写墓碑** → 用户勾的「从所有设备删除」被静默丢弃。

### 传播是否有意义：有，且身份键已定

纯字幕书**参与跨设备同步**，且身份键就是 `uid`：
- `hibiki/lib/src/sync/app_model_library_host_service.dart:660-661` 明文规定「纯 SRT（standalone）
  有声书：身份键 = uid」；
- 接收端导包 `hibiki/lib/src/sync/sync_asset_package_service.dart:248,316`
  （`uid: _stringValue(srtBook, 'uid')`）**逐字保留 uid**，不重新生成。

所以 `uid` 是稳定跨设备身份，传播删除是可实现的真需求——不属于 `plan.md` 里
「书签 / Profile / 搜索历史」那类「无同步前提，结构性做不了」。

### 修复

1. **`SyncTombstoneKind.srtbook('srtbook')`**（`packages/hibiki_core/lib/src/database/sync_tombstone_kind.dart`）。
   墓碑表 `mediaType` 是文本列，**无迁移**。加值后 `app_model.dart` 两处穷尽 switch 编译期强制补分支。
2. **`SrtBookRepository.delete(String uid, {bool propagateDeletion = false})`**：范式照抄同包
   `AudiobookRepository.deleteAudiobook`（`audiobook_repository.dart:76`）——用 bool 而非 `DeleteScope`，
   避免 `hibiki_audio` → app 层反向依赖。
   **墓碑只对 standalone 行写**（删前读该行，`bookKey` 为空才写）：这不是特例分支，而是上面那条
   既有身份规则「身份键 = uid ⟺ standalone」的直接表达。srt-backed 行的身份是 `bookKey`，
   它的墓碑由 `deleteBook` 写成 `book` 种类——两者互斥，绝不会给同一资产产生两条墓碑。
3. **`upsert` 清墓碑**（`srt_book_repository.dart` upsert 处）：防「删了又加、墓碑还在」，
   与 `saveAudiobook`（`audiobook_repository.dart:66`）同纪律。
4. **调用点**：`books.part.dart:558` / `:837` 传 `propagateDeletion: scope == DeleteScope.syncEverywhere`。
   `_deleteCollectionMembersMedia`（`reader_hibiki_history_page.dart:1731`）**不动**——那条路径的
   弹窗是「也删成员本体」勾选框，本就不提供删除范围选择，恒 keepLocalOnly 是正确语义。
5. **在库键**（`sync_orchestrator.dart:848 _collectPresentDeletionKeys`）：加
   `srtbook` → 全部 `bookKey` 为空的 srt uid（与写入侧同一判据，对称）。顺带把该 map 里的
   6 个裸字符串字面量换成 `SyncTombstoneKind.X.dbValue`（同值，杜绝新种类拼错）。
6. **消费**（`app_model.dart:619 _applyConfirmedDeletions`）：
   `case srtbook: await SrtBookRepository(database).delete(c.itemKey)`（默认不回写墓碑）。
7. **标题解析**（`app_model.dart:591`）：srtbook → srt 标题表；解析不到回落 itemKey。
8. 发布层（`sync_orchestrator.dart:903` 逐行遍历墓碑表）与 host `/api/tombstones` **按行泛化，
   零改动**。

## 死角② 没配同步后端时勾了静默无效

### 根因

勾选框的**存在**被硬编码成恒真，与「本机到底有没有传播通道」无关：
- `hibiki/lib/src/sync/deletion_prompt.dart:70` 无条件渲染；
- `reader_history/dialogs.part.dart:14` 有 `showSyncScope` 逃生口，但**生产代码从未传过 false**，
  是个死参数。

没配任何后端时勾上 → 墓碑写进本地表、`remotePublishedAt` 永远 0 → 无人发布 → 静默无效。

### 修复：让控件的可用性由**真实通道状态**派生

无通道时跨设备删除物理上不可能，所以「做实」只能是让 UI 不再撒谎。关键是这个判据必须与
同步真正用的判据**同源**，否则又会漂开。

1. **`SyncChannel` 加 `type` 字段**（`sync_auto_trigger.dart:139`）：两个构造点的
   `SyncBackendType` 本来就在手边。这样通道枚举仍只有 `enabledSyncChannelBackends` 一处。
2. **`SyncRepository.hasStoredBackendConfig(SyncBackendType)`**：对 7 个后端的穷尽 switch，
   纯本地 preferences 读、零网络。SyncRepository 本来就持有全部凭据 key，是唯一自然归宿；
   穷尽 switch 让新后端编译期必须表态。
3. **`hasDeletionPropagationChannel(SyncRepository)`**（新文件 `deletion_propagation_availability.dart`）：
   ```dart
   for (final SyncChannel ch in await enabledSyncChannelBackends(repo)) {
     if (await repo.hasStoredBackendConfig(ch.type)) return true; // 已配置（离线也算）
     if (await ch.backend.isAuthenticated) return true;           // 会话已恢复（移动端 Google 登录态不落 prefs）
   }
   return false;
   ```
   两个条件缺一不可：`isAuthenticated` 是纯内存读（7 个后端全是 `_x != null`，**零网络**，
   与 `_runSyncChannel:232` 同一个门），但自动同步关时启动不跑 `restoreAuth`，单靠它会假阴性；
   `hasStoredBackendConfig` 覆盖「配了但本次会话还没恢复」。**绝不调 `restoreAuth`**——
   互联后端的 `restoreAuth` 会探测地址，删除弹窗不得做网络 IO。
4. **两个弹窗消费**：`showDeleteScopeConfirm` 在 `showAppDialog` **之前** await 该判据
   （它本就返回 Future，调用点零改动，只多传 `db`）；`_confirmMediaDelete` 同理传
   `showSyncScope:`。无通道时不渲染勾选框，改渲染一行不可交互说明（1 个新 i18n key ×17 语言）。

## 影响范围 / 风险

- 🟡 新 `srtbook` 种类：老版本 app 读到该 mediaType 的远端标记 → `tryParse` 返回 null →
  `_applyConfirmedDeletions` 走 `case null` 跳过并留痕。**向前兼容已由既有设计保证**。
- 🟡 `SyncChannel` 加字段：app 内部类，2 个构造点 + 测试。
- 🟢 **不碰** `SyncBackend` 接口——`sync_backend.dart:205` 明文要求「接口零变化，测试 fake 用
  `implements SyncBackend` 不受影响」，约 20 个测试 fake 依赖此约定。
- 🟢 无 schema 迁移，无 DB 版本号竞速。

## 验证

- DB 层：standalone SRT 删除写墓碑 / srt-backed 不写 / `propagateDeletion:false` 不写 / upsert 清墓碑。
- orchestrator：`_collectPresentDeletionKeys` 含且仅含 standalone uid。
- 消费：srtbook 候选 → 真删本地 srt 行，且不回写墓碑。
- 判据真值表：零配置→false；WebDAV URL→true；互联启用+对端地址→true；仅 `isAuthenticated`→true。
- Widget：无通道时不渲染勾选框且恒 keepLocalOnly；有通道时渲染。
- `flutter analyze`（含 test）+ `dart run tool/flutter_test_failures.dart`。

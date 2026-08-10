// 标签全域 / CSS 与揭开状态同步 / 删除传播 / Profile / 基线 / v16 重键（God 类拆分 2026-08：part+mixin，仓库 reader_fushi
// part 先例；mixin 是真类成员——可被测试子类 override、虚分派正常
// （extension 方案在此翻车过）；私有 mixin 不进公共 API 面。
part of 'database.dart';

mixin _FushiDbTagsSync on _$FushiDatabase, _FushiDbInfra {
  // ── book tags ───────────────────────────────────────────────────
  Future<List<BookTagRow>> getAllTags() => (select(bookTags)
        ..orderBy([
          (t) => OrderingTerm.asc(t.sortOrder),
          (t) => OrderingTerm.asc(t.createdAt),
        ]))
      .get();

  // ── tag_assignments 通用内核（v77 五表合一）───────────────────────
  // 五种宿主的公开 API 保持类型化签名（addTagToBook / addTagToGame / ...），
  // 内脏统一走这四个泛型内核——语义差异（谁写墓碑、谁进 sync）留在公开方法层，
  // 数据形状只有一份。

  /// 宿主当前标签（按 createdAt 升序，五域一致）。
  Future<List<BookTagRow>> _tagsForHost(TagHostKind kind, String entryKey) {
    final query = select(bookTags).join([
      innerJoin(tagAssignments, tagAssignments.tagId.equalsExp(bookTags.id)),
    ])
      ..where(tagAssignments.mediaKind.equals(kind.dbValue) &
          tagAssignments.entryKey.equals(entryKey))
      ..orderBy([OrderingTerm.asc(bookTags.createdAt)]);
    return query.map((row) => row.readTable(bookTags)).get();
  }

  /// upsert 一条映射并写 [addedAt]（无则插入，有则刷新 addedAt——LWW add 时钟）。
  Future<void> _upsertAssignmentWithTime(
      TagHostKind kind, String entryKey, int tagId, int addedAt) async {
    await into(tagAssignments).insert(
      TagAssignmentsCompanion.insert(
        mediaKind: kind.dbValue,
        entryKey: entryKey,
        tagId: tagId,
        addedAt: Value(addedAt),
      ),
      onConflict: DoUpdate(
        (old) => TagAssignmentsCompanion(addedAt: Value(addedAt)),
        target: [
          tagAssignments.mediaKind,
          tagAssignments.entryKey,
          tagAssignments.tagId,
        ],
      ),
    );
  }

  Future<void> _deleteAssignment(
          TagHostKind kind, String entryKey, int tagId) =>
      (delete(tagAssignments)
            ..where((t) =>
                t.mediaKind.equals(kind.dbValue) &
                t.entryKey.equals(entryKey) &
                t.tagId.equals(tagId)))
          .go();

  /// 含【全部】选中标签的宿主键（AND 语义）。空集返回空。
  Future<Set<String>> _entryKeysForAllTags(
      TagHostKind kind, Set<int> tagIds) async {
    if (tagIds.isEmpty) return <String>{};
    final int tagCount = tagIds.length;
    final String placeholders = List.generate(tagCount, (_) => '?').join(',');
    final rows = await customSelect(
      'SELECT entry_key FROM tag_assignments '
      'WHERE media_kind = ? AND tag_id IN ($placeholders) '
      'GROUP BY entry_key '
      'HAVING COUNT(DISTINCT tag_id) = ?',
      variables: <Variable>[
        Variable<String>(kind.dbValue),
        ...tagIds.map((id) => Variable<int>(id)),
        Variable<int>(tagCount),
      ],
    ).get();
    return rows.map((row) => row.read<String>('entry_key')).toSet();
  }

  /// 宿主删除路径的映射清理（v77 起五表 cascade 由显式清理取代——逻辑外键，
  /// 同 ShelfEntries 惯例）。
  Future<void> deleteTagAssignmentsForHost(TagHostKind kind, String entryKey) =>
      (delete(tagAssignments)
            ..where((t) =>
                t.mediaKind.equals(kind.dbValue) & t.entryKey.equals(entryKey)))
          .go();

  /// 某 kind 的全部映射行（SQL 面过滤——PK 前缀白拿的索引，别在调用方全表
  /// 扫再 Dart 滤，review5-8）。
  Future<List<TagAssignmentRow>> getTagAssignmentsForKind(TagHostKind kind) =>
      (select(tagAssignments)..where((t) => t.mediaKind.equals(kind.dbValue)))
          .get();

  /// 全部映射行（迁移/合并测试断言全景用；业务查询走
  /// [getTagAssignmentsForKind]）。
  Future<List<TagAssignmentRow>> getAllTagAssignments() =>
      select(tagAssignments).get();

  Future<List<BookTagRow>> getTagsForBook(String bookKey) =>
      _tagsForHost(TagHostKind.epub, bookKey);

  Future<int> createTag(String name, int colorValue) async {
    final maxQuery = selectOnly(bookTags)
      ..addColumns([bookTags.sortOrder.max()]);
    final maxRow = await maxQuery.getSingleOrNull();
    final int nextOrder = (maxRow?.read(bookTags.sortOrder.max()) ?? 0) + 1;
    return into(bookTags).insert(
      BookTagsCompanion.insert(
        name: name,
        colorValue: Value(colorValue),
        sortOrder: Value(nextOrder),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 按标签名取或建标签，返回其 id（TODO-1165）。
  ///
  /// 标签是每设备本地数据（[BookTags].id autoincrement，各设备不一致），跨设备
  /// 同步/下载重建标签映射只能按 name 传递、落地端按名归一。命中已存在同名标签
  /// 返回其 id（幂等，绝不建重复行——[BookTags].name 有 UNIQUE 约束）；否则以默认
  /// 颜色新建并返回新 id。与 [BackupMergeEngine] 的 name-based UNION 合并同语义。
  Future<int> getOrCreateTagByName(String name) async {
    // 原子 get-or-create：INSERT OR IGNORE 撞 [BookTags].name UNIQUE 时静默忽略，
    // 随后 select 必命中——消除 select-then-insert 的竞态（两并发下载流带同一尚不
    // 存在的 tag 名时，旧实现会一个插入成功、另一个撞 UNIQUE 抛异常丢标签）。命中
    // 既有行时 insertOrIgnore 整条无操作，既有色值/排序不被覆盖；仅新建才给默认灰
    // + 末位排序（与 [createTag] 语义一致）。
    final maxRow = await (selectOnly(bookTags)
          ..addColumns([bookTags.sortOrder.max()]))
        .getSingleOrNull();
    final int nextOrder = (maxRow?.read(bookTags.sortOrder.max()) ?? 0) + 1;
    await into(bookTags).insert(
      BookTagsCompanion.insert(
        name: name,
        colorValue: const Value(0xFF9E9E9E),
        sortOrder: Value(nextOrder),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
      mode: InsertMode.insertOrIgnore,
    );
    final BookTagRow row = await (select(bookTags)
          ..where((t) => t.name.equals(name))
          ..limit(1))
        .getSingle();
    return row.id;
  }

  Future<void> updateTag(int id, {String? name, int? colorValue}) =>
      (update(bookTags)..where((t) => t.id.equals(id))).write(
        BookTagsCompanion(
          name: name != null ? Value(name) : const Value.absent(),
          colorValue:
              colorValue != null ? Value(colorValue) : const Value.absent(),
        ),
      );

  Future<int> deleteTag(int id) =>
      (delete(bookTags)..where((t) => t.id.equals(id))).go();

  Future<void> setTagsForBook(String bookKey, Set<int> tagIds) =>
      _setTagsWithTombstones(TagHostKind.epub, bookKey, tagIds);

  /// 带墓碑的整组替换内核（epub/video 共用；srt/collection/game 不进 sync，
  /// 无墓碑语义，走各自的简单增删）。墓碑域由 [tombstoneMediaKindOf] 从 kind
  /// 推导——手工传配对双参能配错且编译不拦（review5-9）。
  Future<void> _setTagsWithTombstones(
          TagHostKind kind, String entryKey, Set<int> tagIds) =>
      transaction(() async {
        final MediaKind tombstoneKind = tombstoneMediaKindOf(kind);
        final int now = DateTime.now().millisecondsSinceEpoch;
        final existing = await (select(tagAssignments)
              ..where((t) =>
                  t.mediaKind.equals(kind.dbValue) &
                  t.entryKey.equals(entryKey)))
            .get();
        final existingTagIds =
            existing.map((TagAssignmentRow e) => e.tagId).toSet();

        for (final tagId in existingTagIds.difference(tagIds)) {
          final String? name = await _tagNameById(tagId);
          await _deleteAssignment(kind, entryKey, tagId);
          if (name != null) {
            await _upsertTagTombstone(entryKey, tombstoneKind, name, now);
          }
        }
        for (final tagId in tagIds.difference(existingTagIds)) {
          await _upsertAssignmentWithTime(kind, entryKey, tagId, now);
          final String? name = await _tagNameById(tagId);
          if (name != null) {
            await _clearTagTombstone(entryKey, tombstoneKind, name);
          }
        }
      });

  Future<void> addTagToBook(String bookKey, int tagId) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _upsertAssignmentWithTime(TagHostKind.epub, bookKey, tagId, now);
    final String? name = await _tagNameById(tagId);
    if (name != null) await _clearTagTombstone(bookKey, MediaKind.epub, name);
  }

  Future<void> removeTagFromBook(String bookKey, int tagId) async {
    final String? name = await _tagNameById(tagId);
    await _deleteAssignment(TagHostKind.epub, bookKey, tagId);
    if (name != null) {
      await _upsertTagTombstone(
          bookKey, MediaKind.epub, name, DateTime.now().millisecondsSinceEpoch);
    }
  }

  Future<Set<String>> getBookKeysForAllTags(Set<int> tagIds) =>
      _entryKeysForAllTags(TagHostKind.epub, tagIds);

  Future<void> reorderTags(List<int> orderedTagIds) => transaction(() async {
        for (int i = 0; i < orderedTagIds.length; i++) {
          await (update(bookTags)..where((t) => t.id.equals(orderedTagIds[i])))
              .write(BookTagsCompanion(sortOrder: Value(i)));
        }
      });

  /// 某标签下的条目数量 = EPUB + 有声书(SRT) + 视频 + 游戏命中该 tagId 的映射
  /// 行数（合集刻意不计：合集是容器而非条目）。v77 合表后一条 COUNT 搞定——
  /// 旧实现逐表 COUNT 漏表的 bug 形状（BUG-1113）在结构上不可能再犯。
  Future<int> countBooksForTag(int tagId) async {
    final cnt = countAll();
    final row = await (selectOnly(tagAssignments)
          ..where(tagAssignments.tagId.equals(tagId) &
              tagAssignments.mediaKind
                  .equals(TagHostKind.collection.dbValue)
                  .not())
          ..addColumns([cnt]))
        .getSingle();
    return row.read(cnt) ?? 0;
  }

  // ── srt book tags ───────────────────────────────────────────────
  // v77 起宿主键换 SrtBooks.uid（跨设备稳定），弃本机自增 int id。

  Future<List<BookTagRow>> getTagsForSrtBook(String srtUid) =>
      _tagsForHost(TagHostKind.srt, srtUid);

  Future<void> addTagToSrtBook(String srtUid, int tagId) =>
      _upsertAssignmentWithTime(TagHostKind.srt, srtUid, tagId,
          DateTime.now().millisecondsSinceEpoch);

  Future<void> removeTagFromSrtBook(String srtUid, int tagId) =>
      _deleteAssignment(TagHostKind.srt, srtUid, tagId);

  Future<Set<String>> getSrtUidsForAllTags(Set<int> tagIds) =>
      _entryKeysForAllTags(TagHostKind.srt, tagIds);

  // ── video book tags ─────────────────────────────────────────────

  Future<List<BookTagRow>> getTagsForVideoBook(String videoBookUid) =>
      _tagsForHost(TagHostKind.video, videoBookUid);

  Future<void> addTagToVideoBook(String videoBookUid, int tagId) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _upsertAssignmentWithTime(
        TagHostKind.video, videoBookUid, tagId, now);
    final String? name = await _tagNameById(tagId);
    if (name != null) {
      await _clearTagTombstone(videoBookUid, MediaKind.video, name);
    }
  }

  Future<void> removeTagFromVideoBook(String videoBookUid, int tagId) async {
    final String? name = await _tagNameById(tagId);
    await _deleteAssignment(TagHostKind.video, videoBookUid, tagId);
    if (name != null) {
      await _upsertTagTombstone(videoBookUid, MediaKind.video, name,
          DateTime.now().millisecondsSinceEpoch);
    }
  }

  // ── 合集标签（复用 BookTags 池；只增不删并集，无墓碑——见 collection-tags 设计 §5）──

  /// 合集当前挂的标签（按 createdAt 升序，与 getTagsForBook 一致）。
  Future<List<BookTagRow>> getTagsForCollection(int collectionId) =>
      _tagsForHost(TagHostKind.collection, collectionTagEntryKey(collectionId));

  /// 给合集加标签（幂等；不写墓碑——合集标签同步不消费墓碑）。
  Future<void> addTagToCollection(int collectionId, int tagId) =>
      _upsertAssignmentWithTime(
          TagHostKind.collection,
          collectionTagEntryKey(collectionId),
          tagId,
          DateTime.now().millisecondsSinceEpoch);

  /// 从合集移除标签（纯 DELETE，本地生效；同步不传播移除——同书/视频标签现状）。
  Future<void> removeTagFromCollection(int collectionId, int tagId) =>
      _deleteAssignment(
          TagHostKind.collection, collectionTagEntryKey(collectionId), tagId);

  /// 含【全部】选中标签的合集 id（AND 语义，仿 getBookKeysForAllTags）。空集返回空。
  Future<Set<int>> getCollectionIdsForAllTags(Set<int> tagIds) async {
    final Set<String> keys =
        await _entryKeysForAllTags(TagHostKind.collection, tagIds);
    return <int>{
      for (final String key in keys)
        if (collectionIdOfTagEntryKey(key) case final int id) id,
    };
  }

  // ── 游戏标签（v59 / BUG-1113；复用 BookTags 池；仅本机）──────────────

  Future<List<BookTagRow>> getTagsForGame(String gameId) =>
      _tagsForHost(TagHostKind.game, gameId);

  Future<void> addTagToGame(String gameId, int tagId) =>
      _upsertAssignmentWithTime(TagHostKind.game, gameId, tagId,
          DateTime.now().millisecondsSinceEpoch);

  Future<void> removeTagFromGame(String gameId, int tagId) =>
      _deleteAssignment(TagHostKind.game, gameId, tagId);

  Future<void> setTagsForGame(String gameId, Set<int> tagIds) =>
      transaction(() async {
        final existing = await (select(tagAssignments)
              ..where((t) =>
                  t.mediaKind.equals(TagHostKind.game.dbValue) &
                  t.entryKey.equals(gameId)))
            .get();
        final Set<int> existingTagIds =
            existing.map((TagAssignmentRow e) => e.tagId).toSet();
        for (final int tagId in existingTagIds.difference(tagIds)) {
          await removeTagFromGame(gameId, tagId);
        }
        for (final int tagId in tagIds.difference(existingTagIds)) {
          await addTagToGame(gameId, tagId);
        }
      });

  Future<Set<String>> getGameIdsForAllTags(Set<int> tagIds) =>
      _entryKeysForAllTags(TagHostKind.game, tagIds);

  Future<void> setTagsForVideoBook(String videoBookUid, Set<int> tagIds) =>
      _setTagsWithTombstones(TagHostKind.video, videoBookUid, tagIds);

  // ── tags 跨端同步（LWW-element-set：added_at vs 墓碑 deleted_at）──────────────
  // 标签跨设备身份 = name。sync 合并按名并集两端「当前标签(带 addedAt)」与「移除墓碑
  // (带 deletedAt)」，逐名 max(addedAt) vs max(deletedAt) 裁决 present/removed，防复活/
  // 防误删。UI 加/删标签写 addedAt/墓碑，让本地操作也进入同一 LWW 时钟。

  Future<String?> _tagNameById(int tagId) async {
    final BookTagRow? row = await (select(bookTags)
          ..where((t) => t.id.equals(tagId))
          ..limit(1))
        .getSingleOrNull();
    return row?.name;
  }

  /// 宿主标签「名 → 加入毫秒戳」（sync 合并的 add 时钟）。
  Future<Map<String, int>> _tagAddedAtByName(
      TagHostKind kind, String entryKey) async {
    final rows = await (select(tagAssignments).join([
      innerJoin(bookTags, bookTags.id.equalsExp(tagAssignments.tagId)),
    ])
          ..where(tagAssignments.mediaKind.equals(kind.dbValue) &
              tagAssignments.entryKey.equals(entryKey)))
        .get();
    return <String, int>{
      for (final row in rows)
        row.readTable(bookTags).name: row.readTable(tagAssignments).addedAt,
    };
  }

  /// 当前书 [bookKey] 的标签「名 → 加入毫秒戳」。
  Future<Map<String, int>> bookTagAddedAtByName(String bookKey) =>
      _tagAddedAtByName(TagHostKind.epub, bookKey);

  /// 当前视频 [videoBookUid] 的标签「名 → 加入毫秒戳」。
  Future<Map<String, int>> videoTagAddedAtByName(String videoBookUid) =>
      _tagAddedAtByName(TagHostKind.video, videoBookUid);

  /// 某宿主 [itemKey]（[mediaType] 为 [MediaKind.epub]/[MediaKind.video]）的
  /// 标签移除墓碑「名 → 移除毫秒戳」。
  Future<Map<String, int>> tagTombstonesByName(
      String itemKey, MediaKind mediaType) async {
    final rows = await (select(bookTagMembershipTombstones)
          ..where((t) =>
              t.itemKey.equals(itemKey) &
              t.mediaType.equals(mediaType.dbValue)))
        .get();
    return <String, int>{for (final r in rows) r.tagName: r.deletedAt};
  }

  /// 某 kind 全库标签「entryKey → (名 → 加入毫秒戳)」一趟批查。
  ///
  /// 互联 host 清单（listBooks/listVideos）逐条调 [bookTagAddedAtByName] 是
  /// O(N) 次查询，大库拖慢清单端点；这里一条 join 拉全量再按 entryKey 分组，
  /// 语义与逐条版一致。
  Future<Map<String, Map<String, int>>> _allTagAddedAtByName(
      TagHostKind kind) async {
    final rows = await (select(tagAssignments).join([
      innerJoin(bookTags, bookTags.id.equalsExp(tagAssignments.tagId)),
    ])
          ..where(tagAssignments.mediaKind.equals(kind.dbValue)))
        .get();
    final Map<String, Map<String, int>> out = <String, Map<String, int>>{};
    for (final row in rows) {
      final TagAssignmentRow m = row.readTable(tagAssignments);
      (out[m.entryKey] ??= <String, int>{})[row.readTable(bookTags).name] =
          m.addedAt;
    }
    return out;
  }

  Future<Map<String, Map<String, int>>> allBookTagAddedAtByName() =>
      _allTagAddedAtByName(TagHostKind.epub);

  Future<Map<String, Map<String, int>>> allVideoTagAddedAtByName() =>
      _allTagAddedAtByName(TagHostKind.video);

  /// 某 [mediaType] 全部标签移除墓碑「itemKey → (名 → 移除毫秒戳)」一趟批查
  /// （替代清单端点逐条 [tagTombstonesByName]）。
  Future<Map<String, Map<String, int>>> allTagTombstonesByName(
      MediaKind mediaType) async {
    final rows = await (select(bookTagMembershipTombstones)
          ..where((t) => t.mediaType.equals(mediaType.dbValue)))
        .get();
    final Map<String, Map<String, int>> out = <String, Map<String, int>>{};
    for (final r in rows) {
      (out[r.itemKey] ??= <String, int>{})[r.tagName] = r.deletedAt;
    }
    return out;
  }

  Future<void> _upsertTagTombstone(
          String itemKey, MediaKind mediaType, String tagName, int deletedAt) =>
      into(bookTagMembershipTombstones).insertOnConflictUpdate(
        BookTagMembershipTombstonesCompanion.insert(
          itemKey: itemKey,
          mediaType: mediaType.dbValue,
          tagName: tagName,
          deletedAt: deletedAt,
        ),
      );

  Future<void> _clearTagTombstone(
          String itemKey, MediaKind mediaType, String tagName) =>
      (delete(bookTagMembershipTombstones)
            ..where((t) =>
                t.itemKey.equals(itemKey) &
                t.mediaType.equals(mediaType.dbValue) &
                t.tagName.equals(tagName)))
          .go();

  /// LWW-element-set 合并内核（epub/video 两个 sync kind 共用）：把远端标签快照
  /// 合并进宿主本地状态。[remoteAddedAt]=远端当前标签名→加入戳；
  /// [remoteTombstones]=远端移除墓碑名→移除戳。按名并集两端 add 时钟与墓碑时钟，
  /// 逐名 max(add) > max(removed) ⇒ present（写映射，addedAt=合并后 add 戳）；
  /// 否则 removed（删映射 + 写墓碑）。幂等。
  Future<void> _mergeRemoteTags(
    TagHostKind kind,
    String entryKey, {
    required Map<String, int> remoteAddedAt,
    required Map<String, int> remoteTombstones,
  }) =>
      transaction(() async {
        final MediaKind tombstoneKind = tombstoneMediaKindOf(kind);
        final Map<String, int> localAdded =
            await _tagAddedAtByName(kind, entryKey);
        final Map<String, int> localTomb =
            await tagTombstonesByName(entryKey, tombstoneKind);
        final _MergedTagState merged = _mergeTagClocks(
            localAdded, remoteAddedAt, localTomb, remoteTombstones);
        for (final MapEntry<String, int> e in merged.present.entries) {
          final int tagId = await getOrCreateTagByName(e.key);
          await _upsertAssignmentWithTime(kind, entryKey, tagId, e.value);
          await _clearTagTombstone(entryKey, tombstoneKind, e.key);
        }
        for (final MapEntry<String, int> e in merged.tombstones.entries) {
          final int? tagId = await _tagIdByName(e.key);
          if (tagId != null) await _deleteAssignment(kind, entryKey, tagId);
          await _upsertTagTombstone(entryKey, tombstoneKind, e.key, e.value);
        }
      });

  /// LWW-element-set：把远端标签快照合并进书 [bookKey] 本地状态。
  Future<void> mergeRemoteBookTags(
    String bookKey, {
    required Map<String, int> remoteAddedAt,
    Map<String, int> remoteTombstones = const <String, int>{},
  }) =>
      _mergeRemoteTags(TagHostKind.epub, bookKey,
          remoteAddedAt: remoteAddedAt, remoteTombstones: remoteTombstones);

  /// LWW-element-set：把远端标签快照合并进视频 [videoBookUid] 本地状态。
  Future<void> mergeRemoteVideoTags(
    String videoBookUid, {
    required Map<String, int> remoteAddedAt,
    Map<String, int> remoteTombstones = const <String, int>{},
  }) =>
      _mergeRemoteTags(TagHostKind.video, videoBookUid,
          remoteAddedAt: remoteAddedAt, remoteTombstones: remoteTombstones);

  Future<int?> _tagIdByName(String name) async {
    final BookTagRow? row = await (select(bookTags)
          ..where((t) => t.name.equals(name))
          ..limit(1))
        .getSingleOrNull();
    return row?.id;
  }

  // ── per-book 自定义 CSS 跨端同步（LWW by updatedAt）──────────────────────────

  /// 记录/刷新书 [bookUid]（v82 起 = 书稳定 uid）的 CSS 文件 [relativePath] 自定义内容（保存时调，updatedAt=now）。
  Future<void> upsertBookCss(
          String bookUid, String relativePath, String content, int updatedAt) =>
      into(bookCustomCss).insertOnConflictUpdate(BookCustomCssRow(
        bookUid: bookUid,
        relativePath: relativePath,
        content: content,
        deleted: false,
        updatedAt: updatedAt,
      ));

  /// 记录书 [bookUid] 的 CSS 文件 [relativePath] 已重置回原始（重置墓碑，updatedAt=now）。
  /// 使「reset」跨端传播（LWW 较新的重置让他端也 reset）。
  Future<void> markBookCssReset(
          String bookUid, String relativePath, int updatedAt) =>
      into(bookCustomCss).insertOnConflictUpdate(BookCustomCssRow(
        bookUid: bookUid,
        relativePath: relativePath,
        content: '',
        deleted: true,
        updatedAt: updatedAt,
      ));

  /// 书 [bookUid] 的全部自定义 CSS 行（含重置墓碑）。sync push 快照用。
  Future<List<BookCustomCssRow>> getBookCssRows(String bookUid) =>
      (select(bookCustomCss)..where((t) => t.bookUid.equals(bookUid))).get();

  // ── 图片防剧透遮罩揭开状态（持久 per-book；书内↔图片库双向同步，BUG-898）──────────

  /// 标记书 [bookUid] 的图片 [imageKey]（extractDir 相对、解码、正斜杠归一路径）已揭开
  /// 遮罩。幂等 upsert（重复揭开刷新 [revealedAt]）。阅读器点击/手柄/音频跨图、图片库
  /// 点开都调它，DB 是唯一真相源。
  Future<void> markImageRevealed(
          String bookUid, String imageKey, int revealedAt) =>
      into(revealedImages).insertOnConflictUpdate(RevealedImageRow(
        bookUid: bookUid,
        imageKey: imageKey,
        revealedAt: revealedAt,
      ));

  /// 一次标记书 [bookUid] 的多张图片已揭开（音频跨多图一次全揭时批量写，省往返）。
  Future<void> markImagesRevealed(
      String bookUid, Iterable<String> imageKeys, int revealedAt) {
    final List<String> keys = imageKeys.toList(growable: false);
    if (keys.isEmpty) return Future<void>.value();
    return batch((Batch b) {
      for (final String k in keys) {
        b.insert(
          revealedImages,
          RevealedImageRow(
              bookUid: bookUid, imageKey: k, revealedAt: revealedAt),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  /// 书 [bookUid] 全部已揭开图片 key 集合。阅读器打开时读它灌入会话集、图片库渲染时读它
  /// 判断哪些图不遮罩。
  Future<Set<String>> getRevealedImageKeys(String bookUid) async {
    final List<RevealedImageRow> rows = await (select(revealedImages)
          ..where((t) => t.bookUid.equals(bookUid)))
        .get();
    return rows.map((RevealedImageRow r) => r.imageKey).toSet();
  }

  /// 书 [bookUid] 已揭开图片 key 的实时流（图片库/阅读器 live 双向同步：一端揭开另一端
  /// 自动收到更新）。
  Stream<Set<String>> watchRevealedImageKeys(String bookUid) =>
      (select(revealedImages)..where((t) => t.bookUid.equals(bookUid)))
          .watch()
          .map((List<RevealedImageRow> rows) =>
              rows.map((RevealedImageRow r) => r.imageKey).toSet());

  // ── 删除传播墓碑（显式确认式）─────────────────────────────────────────────────

  /// 记一条删除墓碑（本地删资产时调；重复删同键 upsert 刷新 deletedAt，重置发布状态）。
  Future<void> writeSyncDeletionTombstone(
          String mediaType, String itemKey, int deletedAt) =>
      into(syncDeletionTombstones).insertOnConflictUpdate(
          SyncDeletionTombstoneRow(
              mediaType: mediaType,
              itemKey: itemKey,
              deletedAt: deletedAt,
              remotePublishedAt: 0));

  /// 清除某资产的删除墓碑（重新导入 / 新增同 (mediaType, itemKey) 时调，防误删复活）。
  Future<void> clearSyncDeletionTombstone(String mediaType, String itemKey) =>
      (delete(syncDeletionTombstones)
            ..where((t) =>
                t.mediaType.equals(mediaType) & t.itemKey.equals(itemKey)))
          .go();

  /// 全部删除墓碑（sync 发布 / compare 对话框读）。
  Future<List<SyncDeletionTombstoneRow>> getSyncDeletionTombstones() =>
      select(syncDeletionTombstones).get();

  /// 某种资产的删除墓碑。
  Future<List<SyncDeletionTombstoneRow>> getSyncDeletionTombstonesOfType(
          String mediaType) =>
      (select(syncDeletionTombstones)
            ..where((t) => t.mediaType.equals(mediaType)))
          .get();

  /// 标记某墓碑已发布到远端（避免每轮重发；[publishedAt] = 发布时刻）。
  Future<void> markSyncDeletionPublished(
          String mediaType, String itemKey, int publishedAt) =>
      (update(syncDeletionTombstones)
            ..where((t) =>
                t.mediaType.equals(mediaType) & t.itemKey.equals(itemKey)))
          .write(SyncDeletionTombstonesCompanion(
              remotePublishedAt: Value(publishedAt)));

  /// LWW 合并远端 CSS 快照进书 [bookKey]。[remote] 是远端每个 relativePath 的
  /// (content, deleted, updatedAt)。逐 relativePath 比 updatedAt 取较新写本地行；返回
  /// **本地实际发生变化**的 (relativePath, content, deleted) 列表，供调用方把较新内容
  /// 写穿磁盘（BookCssRepository.saveCss / resetFile）——DB 只是时间戳载体，磁盘才是
  /// 渲染真相源。幂等（同快照重复合并第二次返回空）。
  Future<List<({String relativePath, String content, bool deleted})>>
      mergeRemoteBookCss(
    String bookUid,
    Map<String, ({String content, bool deleted, int updatedAt})> remote,
  ) =>
          transaction(() async {
            final Map<String, BookCustomCssRow> localByPath =
                <String, BookCustomCssRow>{
              for (final BookCustomCssRow r in await getBookCssRows(bookUid))
                r.relativePath: r,
            };
            final List<({String relativePath, String content, bool deleted})>
                changed =
                <({String relativePath, String content, bool deleted})>[];
            for (final MapEntry<String,
                    ({String content, bool deleted, int updatedAt})> e
                in remote.entries) {
              final BookCustomCssRow? local = localByPath[e.key];
              // 远端严格更新才落地（相等 / 更旧不动，防每轮写放大 + 保留本地更新）。
              if (local != null && local.updatedAt >= e.value.updatedAt)
                continue;
              await into(bookCustomCss).insertOnConflictUpdate(BookCustomCssRow(
                bookUid: bookUid,
                relativePath: e.key,
                content: e.value.deleted ? '' : e.value.content,
                deleted: e.value.deleted,
                updatedAt: e.value.updatedAt,
              ));
              changed.add((
                relativePath: e.key,
                content: e.value.content,
                deleted: e.value.deleted,
              ));
            }
            return changed;
          });

  Future<Set<String>> getVideoBookUidsForAllTags(Set<int> tagIds) =>
      _entryKeysForAllTags(TagHostKind.video, tagIds);

  // ── profiles ──────────────────────────────────────────────────────
  Future<List<ProfileRow>> getAllProfiles() =>
      (select(profiles)..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get();

  Future<ProfileRow?> getProfileById(int id) =>
      (select(profiles)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<int> insertProfile(ProfilesCompanion p) => into(profiles).insert(p);

  Future<void> updateProfileName(int id, String name) =>
      (update(profiles)..where((t) => t.id.equals(id))).write(
        ProfilesCompanion(
          name: Value(name),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );

  Future<int> deleteProfile(int id) =>
      (delete(profiles)..where((t) => t.id.equals(id))).go();

  Future<int> countProfiles() async {
    final cnt = countAll();
    final q = selectOnly(profiles)..addColumns([cnt]);
    final row = await q.getSingle();
    return row.read(cnt)!;
  }

  // ── profile settings ─────────────────────────────────────────────
  Future<List<ProfileSettingRow>> getProfileSettings(int profileId) =>
      (select(profileSettings)..where((t) => t.profileId.equals(profileId)))
          .get();

  Future<void> upsertProfileSetting(ProfileSettingsCompanion s) =>
      into(profileSettings).insert(
        s,
        onConflict: DoUpdate(
          (old) => ProfileSettingsCompanion(value: s.value),
          target: [
            profileSettings.profileId,
            profileSettings.category,
            profileSettings.key,
          ],
        ),
      );

  Future<void> replaceProfileSettings(
          int profileId, List<ProfileSettingsCompanion> settings) =>
      transaction(() async {
        await (delete(profileSettings)
              ..where((t) => t.profileId.equals(profileId)))
            .go();
        await batch((b) {
          for (final s in settings) {
            b.insert(profileSettings, s);
          }
        });
      });

  // ── media type profiles ──────────────────────────────────────────
  Future<List<MediaTypeProfileRow>> getAllMediaTypeProfiles() =>
      select(mediaTypeProfiles).get();

  Future<MediaTypeProfileRow?> getMediaTypeProfile(String mediaType) =>
      (select(mediaTypeProfiles)..where((t) => t.mediaType.equals(mediaType)))
          .getSingleOrNull();

  Future<void> setMediaTypeProfile(String mediaType, int profileId) =>
      into(mediaTypeProfiles).insertOnConflictUpdate(
        MediaTypeProfilesCompanion.insert(
          mediaType: mediaType,
          profileId: profileId,
        ),
      );

  Future<int> deleteMediaTypeProfile(String mediaType) =>
      (delete(mediaTypeProfiles)..where((t) => t.mediaType.equals(mediaType)))
          .go();

  // ── book profiles ────────────────────────────────────────────────
  Future<BookProfileRow?> getBookProfile(String bookKey) =>
      (select(bookProfiles)..where((t) => t.bookKey.equals(bookKey)))
          .getSingleOrNull();

  Future<void> setBookProfile(String bookKey, int profileId) =>
      into(bookProfiles).insertOnConflictUpdate(
        BookProfilesCompanion.insert(
          bookKey: bookKey,
          profileId: profileId,
        ),
      );

  Future<int> deleteBookProfile(String bookKey) =>
      (delete(bookProfiles)..where((t) => t.bookKey.equals(bookKey))).go();

  // ── sync baselines ──────────────────────────────────────────────
  /// 读某资产某维度的基线版本；无记录返回 null。
  Future<int?> getSyncBaseline(String assetKey, String dimension) async {
    final SyncBaselineRow? row = await (select(syncBaselines)
          ..where((t) =>
              t.assetKey.equals(assetKey) & t.dimension.equals(dimension)))
        .getSingleOrNull();
    return row?.baseVersion;
  }

  /// 写/更新基线版本（主键 assetKey+dimension upsert）。
  Future<void> setSyncBaseline(
    String assetKey,
    String dimension,
    int baseVersion,
  ) =>
      into(syncBaselines).insertOnConflictUpdate(SyncBaselinesCompanion(
        assetKey: Value(assetKey),
        dimension: Value(dimension),
        baseVersion: Value(baseVersion),
      ));

  // ── v16 book-key migration ──────────────────────────────────────
  // Legacy uid prefix that wrapped the int book id in audiobooks/audio_cues/
  // book_profiles and in the uid-style audiobook_pos_ prefs. Single literal so
  // the migration's int-extraction matches what buildLegacyBookUid produced.
  static const String _kLegacyUidPrefix = 'reader_ttu/hoshi://book/';

  /// Delegates to the core-local copy of `sanitizeTtuFilename`
  /// (`../utils/ttu_sanitize.dart`). fushi_core cannot depend on the app
  /// package, so the core copy stands in for the app truth source
  /// `fushi/lib/src/sync/ttu_filename.dart`. Core copy and app copy MUST
  /// stay byte-identical: the migrated bookKey has to equal the key
  /// sync/folder code derives from the same title, or cross-device identity
  /// drifts. A source guard (book_key_guard_test) plus the behavioral
  /// parity test (video_book_uid_core_parity_test) lock the two together.
  static String _sanitizeBookKey(String title) => sanitizeTtuFilename(title);

  /// Re-keys every book + all reading data from the autoincrement int id to
  /// bookKey = sanitizeTtuFilename(title). Lossless: builds an id→key map (with
  /// dedup), then rebuilds each table by JOINing through that map.
  ///
  /// Atomicity is the iron rule here — this rewrites user data. drift does NOT
  /// wrap onUpgrade in a transaction by default, so the whole migration body
  /// runs inside an EXPLICIT `transaction()`: it either fully commits or fully
  /// rolls back, leaving user_version at 15 for a safe retry on next launch.
  /// `PRAGMA foreign_keys` is a no-op inside a transaction (SQLite rule), so the
  /// OFF/ON toggles sit OUTSIDE `transaction()`, per drift's "migrations and
  /// foreign keys" guidance. A `foreign_key_check` at the end aborts (rolls
  /// back) the whole migration if any FK relation was left dangling.
  Future<void> _migrateBookKeyV16(Migrator m) async {
    await customStatement('PRAGMA foreign_keys = OFF');
    try {
      await transaction(() async {
        await _runBookKeyMigrationBodyV16();
      });
    } finally {
      await customStatement('PRAGMA foreign_keys = ON');
    }
  }

  /// The full v16 re-key work, run inside the explicit transaction opened by
  /// [_migrateBookKeyV16]. Extracted so the transaction boundary and the
  /// foreign_keys OFF/ON toggles (which must stay outside any transaction) read
  /// cleanly. Throwing anywhere here rolls back the entire migration.
  Future<void> _runBookKeyMigrationBodyV16() async {
    {
      // Guard: only run the re-key when epub_books still carries the legacy
      // autoincrement `id` column. A DB reaching this step with epub_books
      // already created fresh under the v16 generated schema (its PK is
      // `book_key`, no `id`) — e.g. a pre-v5 DB whose from<5 ladder step ran
      // m.createTable(epubBooks) — is already on the target shape, so the whole
      // re-key is a no-op. This also covers synthetic/partial seeds with no
      // epub_books at all (_columnExists implies the table exists). A genuine
      // pre-v16 DB has the int `id` column, so real upgrades still migrate.
      if (!await _columnExists('epub_books', 'id')) {
        return;
      }

      // 1. Read (id, title); compute key + dedup collisions deterministically.
      final List<QueryRow> books =
          await customSelect('SELECT id, title FROM epub_books ORDER BY id')
              .get();
      final Map<int, String> idToKey = <int, String>{};
      final Set<String> used = <String>{};
      for (final QueryRow r in books) {
        final int id = r.read<int>('id');
        String key = _sanitizeBookKey(r.read<String>('title'));
        if (used.contains(key)) {
          for (int i = 2;; i++) {
            final String candidate = '$key ($i)';
            if (!used.contains(candidate)) {
              key = candidate;
              break;
            }
          }
        }
        used.add(key);
        idToKey[id] = key;
      }

      // 2. Temp map table (old_id -> book_key).
      await customStatement('DROP TABLE IF EXISTS _id_key_map');
      await customStatement(
          'CREATE TABLE _id_key_map (old_id INTEGER PRIMARY KEY, book_key TEXT NOT NULL)');
      for (final MapEntry<int, String> e in idToKey.entries) {
        await customStatement(
            'INSERT INTO _id_key_map (old_id, book_key) VALUES (?, ?)',
            <Object?>[e.key, e.value]);
      }

      // 3. epub_books: id PK -> book_key PK.
      await customStatement('''
        CREATE TABLE epub_books_new (
          book_key TEXT NOT NULL PRIMARY KEY,
          title TEXT NOT NULL,
          author TEXT,
          cover_path TEXT,
          epub_path TEXT NOT NULL,
          extract_dir TEXT NOT NULL,
          chapter_count INTEGER NOT NULL,
          chapters_json TEXT NOT NULL,
          toc_json TEXT,
          source_metadata TEXT,
          imported_at INTEGER NOT NULL)''');
      await customStatement('''
        INSERT INTO epub_books_new
        SELECT m.book_key, b.title, b.author, b.cover_path, b.epub_path,
               b.extract_dir, b.chapter_count, b.chapters_json, b.toc_json,
               b.source_metadata, b.imported_at
        FROM epub_books b JOIN _id_key_map m ON m.old_id = b.id''');
      await customStatement('DROP TABLE epub_books');
      await customStatement('ALTER TABLE epub_books_new RENAME TO epub_books');

      // Each relation table is rebuilt ONLY if it still carries its legacy
      // int/uid column. A DB that reached this step with a table already
      // created fresh under the current v16 generated schema (e.g. a pre-v11 DB
      // whose from<11 ladder step ran m.createTable) already has `book_key` and
      // must be left untouched — rebuilding it would JOIN on a non-existent
      // legacy column. Synthetic/partial seeds that lack the table entirely are
      // likewise skipped (column check implies table check).

      // 4. reader_positions: ttu_book_id INT UNIQUE -> book_key TEXT UNIQUE.
      if (await _columnExists('reader_positions', 'ttu_book_id')) {
        await customStatement('''
        CREATE TABLE reader_positions_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          book_key TEXT NOT NULL UNIQUE,
          section_index INTEGER NOT NULL,
          norm_char_offset INTEGER NOT NULL,
          ttu_char_offset INTEGER NOT NULL DEFAULT -1,
          updated_at INTEGER NOT NULL)''');
        await customStatement('''
        INSERT INTO reader_positions_new
          (book_key, section_index, norm_char_offset, ttu_char_offset, updated_at)
        SELECT m.book_key, rp.section_index, rp.norm_char_offset,
               rp.ttu_char_offset, rp.updated_at
        FROM reader_positions rp JOIN _id_key_map m ON m.old_id = rp.ttu_book_id''');
        await customStatement('DROP TABLE reader_positions');
        await customStatement(
            'ALTER TABLE reader_positions_new RENAME TO reader_positions');
      }

      // 5. bookmarks: ttu_book_id INT FK -> book_key TEXT FK (cascade).
      if (await _columnExists('bookmarks', 'ttu_book_id')) {
        await customStatement('''
        CREATE TABLE bookmarks_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          book_key TEXT NOT NULL REFERENCES epub_books (book_key) ON DELETE CASCADE,
          section_index INTEGER NOT NULL,
          norm_char_offset INTEGER NOT NULL,
          label TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          book_title TEXT,
          page_in_chapter INTEGER,
          total_pages_in_chapter INTEGER)''');
        await customStatement('''
        INSERT INTO bookmarks_new
          (id, book_key, section_index, norm_char_offset, label, created_at,
           book_title, page_in_chapter, total_pages_in_chapter)
        SELECT bm.id, m.book_key, bm.section_index, bm.norm_char_offset,
               bm.label, bm.created_at, bm.book_title, bm.page_in_chapter,
               bm.total_pages_in_chapter
        FROM bookmarks bm JOIN _id_key_map m ON m.old_id = bm.ttu_book_id''');
        await customStatement('DROP TABLE bookmarks');
        await customStatement('ALTER TABLE bookmarks_new RENAME TO bookmarks');
      }

      // 6. book_tag_mappings: book_id INT FK -> book_key TEXT FK (cascade).
      if (await _columnExists('book_tag_mappings', 'book_id')) {
        await customStatement('''
        CREATE TABLE book_tag_mappings_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          book_key TEXT NOT NULL REFERENCES epub_books (book_key) ON DELETE CASCADE,
          tag_id INTEGER NOT NULL REFERENCES book_tags (id) ON DELETE CASCADE,
          UNIQUE (book_key, tag_id))''');
        await customStatement('''
        INSERT INTO book_tag_mappings_new (id, book_key, tag_id)
        SELECT btm.id, m.book_key, btm.tag_id
        FROM book_tag_mappings btm JOIN _id_key_map m ON m.old_id = btm.book_id''');
        await customStatement('DROP TABLE book_tag_mappings');
        await customStatement(
            'ALTER TABLE book_tag_mappings_new RENAME TO book_tag_mappings');
      }

      // 7. srt_books: ttu_book_id INT (0 = standalone) -> book_key TEXT ('').
      //    LEFT JOIN so standalone rows (no mapped epub) keep '' sentinel.
      if (await _columnExists('srt_books', 'ttu_book_id')) {
        await customStatement('''
        CREATE TABLE srt_books_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          uid TEXT NOT NULL UNIQUE,
          title TEXT NOT NULL,
          author TEXT,
          audio_root TEXT,
          audio_paths_json TEXT,
          srt_path TEXT NOT NULL,
          cover_path TEXT,
          imported_at INTEGER NOT NULL,
          book_key TEXT NOT NULL DEFAULT '')''');
        await customStatement('''
        INSERT INTO srt_books_new
          (id, uid, title, author, audio_root, audio_paths_json, srt_path,
           cover_path, imported_at, book_key)
        SELECT sb.id, sb.uid, sb.title, sb.author, sb.audio_root,
               sb.audio_paths_json, sb.srt_path, sb.cover_path, sb.imported_at,
               COALESCE(m.book_key, '')
        FROM srt_books sb LEFT JOIN _id_key_map m ON m.old_id = sb.ttu_book_id''');
        await customStatement('DROP TABLE srt_books');
        await customStatement('ALTER TABLE srt_books_new RENAME TO srt_books');
      }

      // 8. audiobooks: book_uid 'reader_ttu/hoshi://book/<id>' -> book_key.
      //    Extract <id>, JOIN map. Rows whose uid doesn't map are dropped
      //    (orphan audiobooks — their epub is gone; v12 already pruned cues).
      if (await _columnExists('audiobooks', 'book_uid')) {
        await customStatement('''
        CREATE TABLE audiobooks_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          book_key TEXT NOT NULL UNIQUE,
          audio_root TEXT,
          audio_paths_json TEXT,
          alignment_format TEXT NOT NULL,
          alignment_path TEXT NOT NULL,
          health_kind_raw TEXT,
          match_rate_pct INTEGER,
          health_measured_at INTEGER,
          health_reason TEXT,
          follow_audio INTEGER)''');
        await customStatement('''
        INSERT INTO audiobooks_new
          (id, book_key, audio_root, audio_paths_json, alignment_format,
           alignment_path, health_kind_raw, match_rate_pct, health_measured_at,
           health_reason, follow_audio)
        SELECT ab.id, m.book_key, ab.audio_root, ab.audio_paths_json,
               ab.alignment_format, ab.alignment_path, ab.health_kind_raw,
               ab.match_rate_pct, ab.health_measured_at, ab.health_reason,
               ab.follow_audio
        FROM audiobooks ab
        JOIN _id_key_map m
          ON m.old_id = CAST(
               substr(ab.book_uid, ${_kLegacyUidPrefix.length + 1}) AS INTEGER)
        WHERE ab.book_uid LIKE '$_kLegacyUidPrefix%' ''');
        await customStatement('DROP TABLE audiobooks');
        await customStatement(
            'ALTER TABLE audiobooks_new RENAME TO audiobooks');
      }

      // 9. audio_cues: book_uid owns EITHER an audiobook uid OR an srt_books.uid.
      //    Rename column to book_key; translate ONLY the audiobook-uid rows
      //    ('reader_ttu/hoshi://book/<id>'), leaving srt uids untouched. Drop
      //    audiobook-uid cues whose id no longer maps (orphans).
      if (await _columnExists('audio_cues', 'book_uid')) {
        await customStatement('''
        CREATE TABLE audio_cues_new (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          book_key TEXT NOT NULL,
          chapter_href TEXT NOT NULL,
          sentence_index INTEGER NOT NULL,
          text_fragment_id TEXT NOT NULL,
          cue_text TEXT NOT NULL,
          start_ms INTEGER NOT NULL,
          end_ms INTEGER NOT NULL,
          audio_file_index INTEGER NOT NULL)''');
        // 9a. non-audiobook-uid cues (srt-owned) carried over verbatim.
        await customStatement('''
        INSERT INTO audio_cues_new
          (id, book_key, chapter_href, sentence_index, text_fragment_id,
           cue_text, start_ms, end_ms, audio_file_index)
        SELECT ac.id, ac.book_uid, ac.chapter_href, ac.sentence_index,
               ac.text_fragment_id, ac.cue_text, ac.start_ms, ac.end_ms,
               ac.audio_file_index
        FROM audio_cues ac
        WHERE ac.book_uid NOT LIKE '$_kLegacyUidPrefix%' ''');
        // 9b. audiobook-uid cues translated through the map.
        await customStatement('''
        INSERT INTO audio_cues_new
          (id, book_key, chapter_href, sentence_index, text_fragment_id,
           cue_text, start_ms, end_ms, audio_file_index)
        SELECT ac.id, m.book_key, ac.chapter_href, ac.sentence_index,
               ac.text_fragment_id, ac.cue_text, ac.start_ms, ac.end_ms,
               ac.audio_file_index
        FROM audio_cues ac
        JOIN _id_key_map m
          ON m.old_id = CAST(
               substr(ac.book_uid, ${_kLegacyUidPrefix.length + 1}) AS INTEGER)
        WHERE ac.book_uid LIKE '$_kLegacyUidPrefix%' ''');
        await customStatement('DROP TABLE audio_cues');
        await customStatement(
            'ALTER TABLE audio_cues_new RENAME TO audio_cues');
      }

      // 10. book_profiles: book_uid PK 'reader_ttu/hoshi://book/<id>' -> book_key.
      if (await _columnExists('book_profiles', 'book_uid')) {
        await customStatement('''
        CREATE TABLE book_profiles_new (
          book_key TEXT NOT NULL PRIMARY KEY,
          profile_id INTEGER NOT NULL REFERENCES profiles (id) ON DELETE CASCADE)''');
        await customStatement('''
        INSERT INTO book_profiles_new (book_key, profile_id)
        SELECT m.book_key, bp.profile_id
        FROM book_profiles bp
        JOIN _id_key_map m
          ON m.old_id = CAST(
               substr(bp.book_uid, ${_kLegacyUidPrefix.length + 1}) AS INTEGER)
        WHERE bp.book_uid LIKE '$_kLegacyUidPrefix%' ''');
        await customStatement('DROP TABLE book_profiles');
        await customStatement(
            'ALTER TABLE book_profiles_new RENAME TO book_profiles');
      }

      // 11. media_items identifier/unique_key: hoshi://book/<id> -> /<key>.
      // media_items is a v1 baseline table (created only in onCreate), so a
      // synthetic/partial legacy seed that starts mid-ladder may lack it.
      const String kIdentPrefix = 'hoshi://book/';
      final List<QueryRow> items = await _tableExists('media_items')
          ? await customSelect(
              "SELECT id, media_identifier, unique_key FROM media_items "
              "WHERE media_identifier LIKE 'hoshi://book/%'",
            ).get()
          : const <QueryRow>[];
      for (final QueryRow it in items) {
        final String mid = it.read<String>('media_identifier');
        final int? oldId = int.tryParse(mid.substring(kIdentPrefix.length));
        final String? key = oldId == null ? null : idToKey[oldId];
        if (key == null) continue;
        await customStatement(
          'UPDATE media_items SET media_identifier = ?, unique_key = ? '
          'WHERE id = ?',
          <Object?>[
            '$kIdentPrefix$key',
            '$kIdentPrefix$key',
            it.read<int>('id'),
          ],
        );
      }

      // 12. preferences re-key (two audiobook_pos key spaces merge to one).
      await _migrateBookKeyPrefsV16(idToKey);

      // 13. reading_statistics: align bare title -> sanitized key, merging
      //     rows that collapse to the same (title, date_key).
      await _migrateReadingStatsTitlesV16();

      // 14. Recreate indexes under the new book_key column names.
      await _ensureIndexes();

      await customStatement('DROP TABLE _id_key_map');

      // 15. Integrity gate: any dangling FK relation means the re-key was
      //     lossy/wrong. Throw to roll back the whole transaction (FK checks
      //     are deferred while foreign_keys=OFF, so this runs them explicitly).
      final List<QueryRow> violations =
          await customSelect('PRAGMA foreign_key_check').get();
      if (violations.isNotEmpty) {
        throw StateError(
            'book-key migration left FK violations: ${violations.length}');
      }
    }
  }

  /// Re-keys all per-book preferences from int id / legacy uid to bookKey.
  /// The two audiobook_pos_ key spaces (int-style from SyncRepository and
  /// uid-style from AudiobookRepository's realtime writes) merge; on conflict
  /// the uid-style value wins (it is the live player write).
  Future<void> _migrateBookKeyPrefsV16(Map<int, String> idToKey) async {
    if (!await _tableExists('preferences')) return;
    final List<QueryRow> rows =
        await customSelect('SELECT key, value FROM preferences').get();

    // Resolved new key -> value, with a priority flag so uid-style audiobook_pos
    // wins over int-style on collision.
    final Map<String, String> resolved = <String, String>{};
    final Set<String> uidWonPos = <String>{};
    final Set<String> oldKeysToDelete = <String>{};

    // Prefixes whose suffix is the legacy uid string (reader_ttu/hoshi://book/<id>).
    const List<String> uidPrefixes = <String>[
      'audiobook_pos_',
      'audiobook_follow_',
      'audiobook_delay_',
      'audiobook_speed_',
      'audiobook_volume_',
      'audiobook_image_pause_',
      'audiobook_health_overlay_',
    ];

    String? mapUidSuffix(String suffix) {
      if (!suffix.startsWith(_kLegacyUidPrefix)) return null;
      final int? oldId =
          int.tryParse(suffix.substring(_kLegacyUidPrefix.length));
      if (oldId == null) return null;
      return idToKey[oldId];
    }

    for (final QueryRow r in rows) {
      final String key = r.read<String>('key');
      final String value = r.read<String>('value');

      // audiobook_pos_ has TWO suffix shapes: bare int (SyncRepository) or the
      // legacy uid (AudiobookRepository). Handle it explicitly so both merge.
      if (key.startsWith('audiobook_pos_')) {
        final String suffix = key.substring('audiobook_pos_'.length);
        String? newKeyKey;
        bool isUid = false;
        if (suffix.startsWith(_kLegacyUidPrefix)) {
          final String? bk = mapUidSuffix(suffix);
          if (bk != null) {
            newKeyKey = 'audiobook_pos_$bk';
            isUid = true;
          }
        } else {
          final int? oldId = int.tryParse(suffix);
          final String? bk = oldId == null ? null : idToKey[oldId];
          if (bk != null) newKeyKey = 'audiobook_pos_$bk';
        }
        if (newKeyKey != null) {
          oldKeysToDelete.add(key);
          if (isUid) {
            resolved[newKeyKey] = value;
            uidWonPos.add(newKeyKey);
          } else if (!uidWonPos.contains(newKeyKey)) {
            resolved[newKeyKey] = value;
          }
        }
        continue;
      }

      // bookmarks_<int> (BookmarkRepository / migrateLegacyBookmarkPreferences
      // normally consumes these into the table, but re-key any leftover).
      if (key.startsWith('bookmarks_')) {
        final String suffix = key.substring('bookmarks_'.length);
        final int? oldId = int.tryParse(suffix);
        final String? bk = oldId == null ? null : idToKey[oldId];
        if (bk != null) {
          oldKeysToDelete.add(key);
          resolved['bookmarks_$bk'] = value;
        }
        continue;
      }

      // Remaining uid-suffix prefixes.
      for (final String prefix in uidPrefixes) {
        if (prefix == 'audiobook_pos_') continue; // handled above
        if (!key.startsWith(prefix)) continue;
        final String suffix = key.substring(prefix.length);
        final String? bk = mapUidSuffix(suffix);
        if (bk != null) {
          oldKeysToDelete.add(key);
          resolved['$prefix$bk'] = value;
        }
        break;
      }
    }

    // Delete old keys first, then write resolved new keys (uid-priority applied).
    for (final String k in oldKeysToDelete) {
      await customStatement(
          'DELETE FROM preferences WHERE key = ?', <Object?>[k]);
    }
    for (final MapEntry<String, String> e in resolved.entries) {
      await customStatement(
        'INSERT INTO preferences (key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        <Object?>[e.key, e.value],
      );
    }
  }

  /// Rewrites reading_statistics.title from the bare title to the sanitized
  /// bookKey domain so stats join the new identity. Rows that collapse to the
  /// same (sanitized title, date_key) are merged additively.
  ///
  /// CONTRACT / known follow-up: reading_statistics is keyed by `title`, not by
  /// a book id — same-title books have always shared a stats row, so merging
  /// here is a pre-existing property, not new behaviour introduced by this
  /// migration. After this step the stored title equals `_sanitizeBookKey(title)`
  /// (the bookKey domain), but runtime stats writes STILL use the bare title.
  /// Milestone 2 (the runtime-sweep pass) switches those writes to key by
  /// bookKey; until then a stale bare-title write would create a parallel row.
  /// That divergence is bounded and intentionally accepted for milestone 1 —
  /// milestone 2 aligns the two.
  Future<void> _migrateReadingStatsTitlesV16() async {
    if (!await _tableExists('reading_statistics')) return;
    final List<QueryRow> rows = await customSelect(
            'SELECT id, title, date_key, characters_read, reading_time_ms, '
            'last_statistic_modified FROM reading_statistics')
        .get();

    // Group target (sanitizedTitle, dateKey) -> accumulated values + the row id
    // we keep (smallest id) and the row ids we delete (merged away).
    final Map<String, _StatAccum> merged = <String, _StatAccum>{};
    for (final QueryRow r in rows) {
      final int id = r.read<int>('id');
      final String sanitized = _sanitizeBookKey(r.read<String>('title'));
      final String dateKey = r.read<String>('date_key');
      final String groupKey = '$sanitized\u0000$dateKey';
      final int chars = r.read<int>('characters_read');
      final int timeMs = r.read<int>('reading_time_ms');
      final int lastMod = r.read<int>('last_statistic_modified');
      final _StatAccum? acc = merged[groupKey];
      if (acc == null) {
        merged[groupKey] = _StatAccum(
          keepId: id,
          title: sanitized,
          chars: chars,
          timeMs: timeMs,
          lastMod: lastMod,
        );
      } else {
        acc.chars += chars;
        acc.timeMs += timeMs;
        if (lastMod > acc.lastMod) acc.lastMod = lastMod;
        acc.deleteIds.add(id);
      }
    }

    for (final _StatAccum acc in merged.values) {
      for (final int delId in acc.deleteIds) {
        await customStatement(
            'DELETE FROM reading_statistics WHERE id = ?', <Object?>[delId]);
      }
      await customStatement(
        'UPDATE reading_statistics SET title = ?, characters_read = ?, '
        'reading_time_ms = ?, last_statistic_modified = ? WHERE id = ?',
        <Object?>[
          acc.title,
          acc.chars,
          acc.timeMs,
          acc.lastMod,
          acc.keepId,
        ],
      );
    }
  }
}

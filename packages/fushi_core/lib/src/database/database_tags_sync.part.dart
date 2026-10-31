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

  /// 改标签名 / 颜色。
  ///
  /// 标签跨设备身份是**名字**，所以改名在同步语义上等于「全部宿主移除旧名 +
  /// 以当下时刻加入新名」：给每条映射写旧名墓碑、把 addedAt 刷成 now。否则对端
  /// 仍挂着旧名的宿主会在下一轮互联标签同步里把旧名原样推回来（改名被撤销）。
  /// 颜色不是跨端身份，只改本行。
  Future<void> updateTag(int id, {String? name, int? colorValue}) =>
      transaction(() async {
        final String? oldName = await _tagNameById(id);
        await (update(bookTags)..where((t) => t.id.equals(id))).write(
          BookTagsCompanion(
            name: name != null ? Value(name) : const Value.absent(),
            colorValue:
                colorValue != null ? Value(colorValue) : const Value.absent(),
          ),
        );
        if (name == null || oldName == null || oldName == name) return;
        final int now = DateTime.now().millisecondsSinceEpoch;
        final List<TagAssignmentRow> rows =
            await (select(tagAssignments)..where((t) => t.tagId.equals(id)))
                .get();
        for (final TagAssignmentRow r in rows) {
          final TagHostKind? kind = _tagHostKindOf(r.mediaKind);
          if (kind == null) continue;
          final String domain = tagTombstoneDomainOf(kind);
          await _upsertTagTombstone(r.entryKey, domain, oldName, now);
          await _clearTagTombstone(r.entryKey, domain, name);
          await _upsertAssignmentWithTime(kind, r.entryKey, id, now);
        }
      });

  /// 删标签（映射随 FK cascade 消失）。
  ///
  /// 删之前给每条映射写移除墓碑：删标签在同步语义上就是「从所有宿主移除它」，
  /// 不写墓碑的话对端下一轮互联标签同步会按名把它整组推回来。
  Future<int> deleteTag(int id) => transaction(() async {
        final String? name = await _tagNameById(id);
        if (name != null) {
          final int now = DateTime.now().millisecondsSinceEpoch;
          final List<TagAssignmentRow> rows =
              await (select(tagAssignments)..where((t) => t.tagId.equals(id)))
                  .get();
          for (final TagAssignmentRow r in rows) {
            final TagHostKind? kind = _tagHostKindOf(r.mediaKind);
            if (kind == null) continue;
            await _upsertTagTombstone(
                r.entryKey, tagTombstoneDomainOf(kind), name, now);
          }
        }
        return (delete(bookTags)..where((t) => t.id.equals(id))).go();
      });

  TagHostKind? _tagHostKindOf(String dbValue) {
    for (final TagHostKind k in TagHostKind.values) {
      if (k.dbValue == dbValue) return k;
    }
    return null;
  }

  /// 本机用户给宿主加标签：写 add 时钟（now）并清同名墓碑。五种宿主共用，
  /// 让本地操作进入互联标签同步的同一 LWW 时钟。
  Future<void> _addTagClocked(
      TagHostKind kind, String entryKey, int tagId) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _upsertAssignmentWithTime(kind, entryKey, tagId, now);
    final String? name = await _tagNameById(tagId);
    if (name != null) {
      await _clearTagTombstone(entryKey, tagTombstoneDomainOf(kind), name);
    }
  }

  /// 本机用户从宿主移除标签：删映射并写移除墓碑（now），防对端并集复活。
  Future<void> _removeTagClocked(
      TagHostKind kind, String entryKey, int tagId) async {
    final String? name = await _tagNameById(tagId);
    await _deleteAssignment(kind, entryKey, tagId);
    if (name != null) {
      await _upsertTagTombstone(entryKey, tagTombstoneDomainOf(kind), name,
          DateTime.now().millisecondsSinceEpoch);
    }
  }

  Future<void> setTagsForBook(String bookKey, Set<int> tagIds) =>
      _setTagsWithTombstones(TagHostKind.epub, bookKey, tagIds);

  /// 带墓碑的整组替换内核（五种宿主共用）。墓碑域由 [tagTombstoneDomainOf] 从
  /// kind 推导——手工传配对双参能配错且编译不拦（review5-9）。
  Future<void> _setTagsWithTombstones(
          TagHostKind kind, String entryKey, Set<int> tagIds) =>
      transaction(() async {
        final String tombstoneKind = tagTombstoneDomainOf(kind);
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

  Future<void> addTagToBook(String bookKey, int tagId) =>
      _addTagClocked(TagHostKind.epub, bookKey, tagId);

  Future<void> removeTagFromBook(String bookKey, int tagId) =>
      _removeTagClocked(TagHostKind.epub, bookKey, tagId);

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
      _addTagClocked(TagHostKind.srt, srtUid, tagId);

  Future<void> removeTagFromSrtBook(String srtUid, int tagId) =>
      _removeTagClocked(TagHostKind.srt, srtUid, tagId);

  Future<Set<String>> getSrtUidsForAllTags(Set<int> tagIds) =>
      _entryKeysForAllTags(TagHostKind.srt, tagIds);

  // ── video book tags ─────────────────────────────────────────────

  Future<List<BookTagRow>> getTagsForVideoBook(String videoBookUid) =>
      _tagsForHost(TagHostKind.video, videoBookUid);

  Future<void> addTagToVideoBook(String videoBookUid, int tagId) =>
      _addTagClocked(TagHostKind.video, videoBookUid, tagId);

  Future<void> removeTagFromVideoBook(String videoBookUid, int tagId) =>
      _removeTagClocked(TagHostKind.video, videoBookUid, tagId);

  // ── 合集标签（复用 BookTags 池）──────────────────────────────────────
  // 互联标签同步（tag_sync_engine）起合集标签与书/视频同一套 LWW 时钟 + 移除墓碑；
  // 合集清单里无时钟的 tagNames 只经 [mergeRemoteCollectionTagNames] 弱并入。

  /// 合集当前挂的标签（按 createdAt 升序，与 getTagsForBook 一致）。
  Future<List<BookTagRow>> getTagsForCollection(int collectionId) =>
      _tagsForHost(TagHostKind.collection, collectionTagEntryKey(collectionId));

  /// 给合集加标签（幂等；清同名移除墓碑）。
  Future<void> addTagToCollection(int collectionId, int tagId) =>
      _addTagClocked(
          TagHostKind.collection, collectionTagEntryKey(collectionId), tagId);

  /// 从合集移除标签（写移除墓碑，经互联标签同步传播到对端）。
  Future<void> removeTagFromCollection(int collectionId, int tagId) =>
      _removeTagClocked(
          TagHostKind.collection, collectionTagEntryKey(collectionId), tagId);

  /// 合集清单（`CollectionManifestEntry.tagNames`）带来的标签名弱并入：清单只有
  /// 名字没有时钟，按 addedAt=1（最古 add）合并——本机移除过（有墓碑）的名字不
  /// 复活，真实时钟到了（互联标签同步）自然压过它。返回是否改了库。
  Future<bool> mergeRemoteCollectionTagNames(
          int collectionId, Iterable<String> names) =>
      mergeRemoteTagClocks(
        TagHostKind.collection,
        collectionTagEntryKey(collectionId),
        remoteAddedAt: <String, int>{
          for (final String n in names)
            if (n.isNotEmpty) n: 1,
        },
      );

  /// 含【全部】选中标签的合集 id（AND 语义，仿 getBookKeysForAllTags）。空集返回空。
  Future<Set<int>> getCollectionIdsForAllTags(Set<int> tagIds) async {
    final Set<String> keys =
        await _entryKeysForAllTags(TagHostKind.collection, tagIds);
    return <int>{
      for (final String key in keys)
        if (collectionIdOfTagEntryKey(key) case final int id) id,
    };
  }

  // ── 游戏标签（v59 / BUG-1113；复用 BookTags 池）────────────────────────
  // 宿主键是本机 galgames.id；跨设备经 GameIdentityIndex 换算成游戏跨端身份。

  Future<List<BookTagRow>> getTagsForGame(String gameId) =>
      _tagsForHost(TagHostKind.game, gameId);

  Future<void> addTagToGame(String gameId, int tagId) =>
      _addTagClocked(TagHostKind.game, gameId, tagId);

  Future<void> removeTagFromGame(String gameId, int tagId) =>
      _removeTagClocked(TagHostKind.game, gameId, tagId);

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
          String itemKey, MediaKind mediaType) =>
      _tagTombstonesByDomain(itemKey, mediaType.dbValue);

  Future<Map<String, int>> _tagTombstonesByDomain(
      String itemKey, String domain) async {
    final rows = await (select(bookTagMembershipTombstones)
          ..where((t) => t.itemKey.equals(itemKey) & t.mediaType.equals(domain)))
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
          MediaKind mediaType) =>
      _allTagTombstonesByDomain(mediaType.dbValue);

  /// 某宿主种类全库标签时钟「entryKey → (加入 名→戳, 墓碑 名→戳)」一趟批查，
  /// 供互联标签同步构建本机清单（tag_sync_engine）。只含有映射或有墓碑的宿主。
  Future<Map<String, TagClockSet>> allTagClocksForKind(
      TagHostKind kind) async {
    final Map<String, Map<String, int>> added =
        await _allTagAddedAtByName(kind);
    final Map<String, Map<String, int>> tombs =
        await _allTagTombstonesByDomain(tagTombstoneDomainOf(kind));
    return <String, TagClockSet>{
      for (final String key in <String>{...added.keys, ...tombs.keys})
        key: (
          addedAt: added[key] ?? const <String, int>{},
          tombstones: tombs[key] ?? const <String, int>{},
        ),
    };
  }

  Future<Map<String, Map<String, int>>> _allTagTombstonesByDomain(
      String domain) async {
    final rows = await (select(bookTagMembershipTombstones)
          ..where((t) => t.mediaType.equals(domain)))
        .get();
    final Map<String, Map<String, int>> out = <String, Map<String, int>>{};
    for (final r in rows) {
      (out[r.itemKey] ??= <String, int>{})[r.tagName] = r.deletedAt;
    }
    return out;
  }

  Future<void> _upsertTagTombstone(
          String itemKey, String domain, String tagName, int deletedAt) =>
      into(bookTagMembershipTombstones).insertOnConflictUpdate(
        BookTagMembershipTombstonesCompanion.insert(
          itemKey: itemKey,
          mediaType: domain,
          tagName: tagName,
          deletedAt: deletedAt,
        ),
      );

  Future<void> _clearTagTombstone(
          String itemKey, String domain, String tagName) =>
      (delete(bookTagMembershipTombstones)
            ..where((t) =>
                t.itemKey.equals(itemKey) &
                t.mediaType.equals(domain) &
                t.tagName.equals(tagName)))
          .go();

  /// LWW-element-set 合并内核（五种宿主共用）：把远端标签快照合并进宿主本地
  /// 状态。[remoteAddedAt]=远端当前标签名→加入戳；[remoteTombstones]=远端移除
  /// 墓碑名→移除戳。按名并集两端 add 时钟与墓碑时钟，逐名 max(add) > max(removed)
  /// ⇒ present（写映射，addedAt=合并后 add 戳）；否则 removed（删映射 + 写墓碑）。
  ///
  /// **只写有变化的行**，返回是否改了库：互联标签同步由表变更观察者防抖触发，
  /// 合并结果与本地一致时还去 upsert 会让观察者每个防抖窗自激一轮、永不停歇。
  /// [newTagColors] 是远端标签定义的颜色：本机要新建该名标签时沿用它（已有标签
  /// 的颜色不动——颜色没有时钟，不跨端覆盖）。
  Future<bool> mergeRemoteTagClocks(
    TagHostKind kind,
    String entryKey, {
    required Map<String, int> remoteAddedAt,
    Map<String, int> remoteTombstones = const <String, int>{},
    Map<String, int> newTagColors = const <String, int>{},
  }) =>
      transaction(() async {
        final String tombstoneKind = tagTombstoneDomainOf(kind);
        final Map<String, int> localAdded =
            await _tagAddedAtByName(kind, entryKey);
        final Map<String, int> localTomb =
            await _tagTombstonesByDomain(entryKey, tombstoneKind);
        final _MergedTagState merged = _mergeTagClocks(
            localAdded, remoteAddedAt, localTomb, remoteTombstones);
        bool changed = false;
        for (final MapEntry<String, int> e in merged.present.entries) {
          if (localAdded[e.key] != e.value) {
            int? tagId = await _tagIdByName(e.key);
            if (tagId == null) {
              final int? color = newTagColors[e.key];
              tagId = color == null
                  ? await getOrCreateTagByName(e.key)
                  : await createTag(e.key, color);
            }
            await _upsertAssignmentWithTime(kind, entryKey, tagId, e.value);
            changed = true;
          }
          if (localTomb.containsKey(e.key)) {
            await _clearTagTombstone(entryKey, tombstoneKind, e.key);
            changed = true;
          }
        }
        for (final MapEntry<String, int> e in merged.tombstones.entries) {
          if (localAdded.containsKey(e.key)) {
            final int? tagId = await _tagIdByName(e.key);
            if (tagId != null) await _deleteAssignment(kind, entryKey, tagId);
            changed = true;
          }
          if (localTomb[e.key] != e.value) {
            await _upsertTagTombstone(entryKey, tombstoneKind, e.key, e.value);
            changed = true;
          }
        }
        return changed;
      });

  /// LWW-element-set：把远端标签快照合并进书 [bookKey] 本地状态。
  Future<void> mergeRemoteBookTags(
    String bookKey, {
    required Map<String, int> remoteAddedAt,
    Map<String, int> remoteTombstones = const <String, int>{},
  }) =>
      mergeRemoteTagClocks(TagHostKind.epub, bookKey,
          remoteAddedAt: remoteAddedAt, remoteTombstones: remoteTombstones);

  /// LWW-element-set：把远端标签快照合并进视频 [videoBookUid] 本地状态。
  Future<void> mergeRemoteVideoTags(
    String videoBookUid, {
    required Map<String, int> remoteAddedAt,
    Map<String, int> remoteTombstones = const <String, int>{},
  }) =>
      mergeRemoteTagClocks(TagHostKind.video, videoBookUid,
          remoteAddedAt: remoteAddedAt, remoteTombstones: remoteTombstones);

  // ── media_privacy_flags（v122 作品级私密标记）─────────────────────

  /// 把宿主设为 / 取消私密：只推进对应那只时钟（[at] 缺省取当前时刻），另一只原样
  /// 保留，互联合并才能按 LWW 裁决并发的设 / 取消。
  Future<void> setMediaPrivate(
    TagHostKind kind,
    String entryKey,
    bool private, {
    int? at,
  }) =>
      transaction(() async {
        final int now = at ?? DateTime.now().millisecondsSinceEpoch;
        final MediaPrivacyClock current = await mediaPrivacyClock(
          kind,
          entryKey,
        );
        await into(mediaPrivacyFlags).insertOnConflictUpdate(
          MediaPrivacyFlagsCompanion.insert(
            mediaKind: kind.dbValue,
            entryKey: entryKey,
            privateAt: Value(private ? now : current.privateAt),
            clearedAt: Value(private ? current.clearedAt : now),
          ),
        );
      });

  /// 宿主当前的私密时钟（没有行 = 两只戳都为 null）。
  Future<MediaPrivacyClock> mediaPrivacyClock(
    TagHostKind kind,
    String entryKey,
  ) async {
    final MediaPrivacyFlagRow? row = await (select(mediaPrivacyFlags)
          ..where((t) =>
              t.mediaKind.equals(kind.dbValue) & t.entryKey.equals(entryKey)))
        .getSingleOrNull();
    return (privateAt: row?.privateAt, clearedAt: row?.clearedAt);
  }

  Future<bool> isMediaPrivate(TagHostKind kind, String entryKey) async =>
      isPrivateByClock(await mediaPrivacyClock(kind, entryKey));

  /// 某宿主种类当前是私密的全部 entryKey（一趟批查）。
  Future<Set<String>> privateEntryKeys(TagHostKind kind) async => <String>{
        for (final MapEntry<String, MediaPrivacyClock> e
            in (await allPrivacyClocksForKind(kind)).entries)
          if (isPrivateByClock(e.value)) e.key,
      };

  /// 某宿主种类全部私密时钟（含已取消的），供互联标签同步构建本机清单。
  Future<Map<String, MediaPrivacyClock>> allPrivacyClocksForKind(
    TagHostKind kind,
  ) async {
    final List<MediaPrivacyFlagRow> rows = await (select(mediaPrivacyFlags)
          ..where((t) => t.mediaKind.equals(kind.dbValue)))
        .get();
    return <String, MediaPrivacyClock>{
      for (final MediaPrivacyFlagRow r in rows)
        r.entryKey: (privateAt: r.privateAt, clearedAt: r.clearedAt),
    };
  }

  /// 把对端私密时钟并入宿主（逐戳取大）。**只在合并结果与本机不同时写库**，返回
  /// 是否改了：理由同 [mergeRemoteTagClocks]（表变更观察者会被无变化的写自激）。
  Future<bool> mergeRemotePrivacyClock(
    TagHostKind kind,
    String entryKey,
    MediaPrivacyClock remote,
  ) =>
      transaction(() async {
        final MediaPrivacyClock local = await mediaPrivacyClock(
          kind,
          entryKey,
        );
        final MediaPrivacyClock merged = mergePrivacyClocks(local, remote);
        if (merged == local) return false;
        await into(mediaPrivacyFlags).insertOnConflictUpdate(
          MediaPrivacyFlagsCompanion.insert(
            mediaKind: kind.dbValue,
            entryKey: entryKey,
            privateAt: Value(merged.privateAt),
            clearedAt: Value(merged.clearedAt),
          ),
        );
        return true;
      });

  Future<int?> _tagIdByName(String name) async {
    final BookTagRow? row = await (select(bookTags)
          ..where((t) => t.name.equals(name))
          ..limit(1))
        .getSingleOrNull();
    return row?.id;
  }

  /// Sparse per-book reader preferences, including reset tombstones for sync.
  Future<MangaReaderOverrideRow?> getMangaReaderOverride(String bookUid) =>
      (select(mangaReaderOverrides)..where((t) => t.bookUid.equals(bookUid)))
          .getSingleOrNull();

  Future<List<MangaReaderOverrideRow>> getAllMangaReaderOverrides() =>
      select(mangaReaderOverrides).get();

  Stream<MangaReaderOverrideRow?> watchMangaReaderOverride(String bookUid) =>
      (select(mangaReaderOverrides)..where((t) => t.bookUid.equals(bookUid)))
          .watchSingleOrNull();

  /// 只改其中**几个键**，其余覆盖原样保留。
  ///
  /// [setMangaReaderOverride] 是**整行替换**语义（给设置面板用：它每次传的是合并
  /// 后的完整 map）。顶栏那种「只切阅读模式」的局部改动必须走这条，否则用户在面板
  /// 里调好的 scaleType / cropBorders / tapZones / background / zoomStart 等会被一
  /// 次点击整片抹掉——而且这行带着新的 `updatedAt`，会作为权威全量快照经 sidecar 与
  /// 互联清单发出，LWW 把**对端**的完整覆盖也一并擦掉。
  Future<void> patchMangaReaderOverride(
    String bookUid,
    Map<String, Object?> patch,
  ) async {
    final MangaReaderOverrideRow? previous =
        await getMangaReaderOverride(bookUid);
    final Map<String, Object?> merged = <String, Object?>{};
    if (previous != null && !previous.deleted) {
      try {
        final Object? decoded = jsonDecode(previous.overridesJson);
        if (decoded is Map) merged.addAll(decoded.cast<String, Object?>());
      } on FormatException {
        // 坏 JSON 当没有覆盖：补丁照常落地，坏值不再传播。
      }
    }
    merged.addAll(patch);
    await setMangaReaderOverride(bookUid, merged);
  }

  Future<void> setMangaReaderOverride(
    String bookUid,
    Map<String, Object?> overrides,
  ) => transaction(() async {
    if (bookUid.isEmpty ||
        await (select(epubBooks)..where((t) => t.uid.equals(bookUid)))
                .getSingleOrNull() ==
            null) {
      throw ArgumentError.value(bookUid, 'bookUid', 'Unknown book');
    }
    final Map<String, Object?> sparse = Map<String, Object?>.from(overrides)
      ..removeWhere((String key, Object? value) => value == null);
    final MangaReaderOverrideRow? previous =
        await getMangaReaderOverride(bookUid);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await into(mangaReaderOverrides).insertOnConflictUpdate(
      MangaReaderOverrideRow(
        bookUid: bookUid,
        overridesJson: jsonEncode(sparse),
        updatedAt: previous != null && previous.updatedAt >= now
            ? previous.updatedAt + 1
            : now,
        deleted: sparse.isEmpty,
      ),
    );
  });

  Future<bool> mergeMangaReaderOverride(
    String bookUid, {
    required Map<String, Object?> overrides,
    required int updatedAt,
    required bool deleted,
  }) => transaction(() async {
    if (bookUid.isEmpty ||
        updatedAt < 0 ||
        await (select(epubBooks)..where((t) => t.uid.equals(bookUid)))
                .getSingleOrNull() ==
            null) {
      return false;
    }
    final MangaReaderOverrideRow? current =
        await getMangaReaderOverride(bookUid);
    if (current != null && current.updatedAt >= updatedAt) return false;
    final Map<String, Object?> sparse = Map<String, Object?>.from(overrides)
      ..removeWhere((String key, Object? value) => value == null);
    await into(mangaReaderOverrides).insertOnConflictUpdate(
      MangaReaderOverrideRow(
        bookUid: bookUid,
        overridesJson: jsonEncode(deleted ? <String, Object?>{} : sparse),
        updatedAt: updatedAt,
        deleted: deleted || sparse.isEmpty,
      ),
    );
    return true;
  });

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

  /// 撤销书 [bookUid] 图片 [imageKey] 的揭开状态（插图册长按「恢复遮罩」）。删行而不是
  /// 写一条「未揭开」标记：本表的语义就是「在册即已揭开」，补一个否定态会让同一事实有
  /// 两种表示，同步与迁移都得再判一次。行不存在是正常入参（幂等）。
  Future<void> unmarkImageRevealed(String bookUid, String imageKey) =>
      (delete(revealedImages)
            ..where((t) =>
                t.bookUid.equals(bookUid) & t.imageKey.equals(imageKey)))
          .go();

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

  /// 记一条删除墓碑（本地删资产时调；重复删同键 upsert 刷新 deletedAt，重置发布状态
  /// 与云盘文件夹处置状态）。
  ///
  /// [cloudFolderName]：书墓碑的云盘书文件夹名（`sanitizeTtuFilename(书名)`，删除时
  /// 按当时的书名取）。墓碑键可能是对端键 / 别名，不等于文件夹名；只有记下了它，云通道
  /// 才会去删云盘上的书文件夹。其它资产 / 拿不到书名时留 null。
  Future<void> writeSyncDeletionTombstone(
          String mediaType, String itemKey, int deletedAt,
          {String? cloudFolderName}) =>
      into(syncDeletionTombstones).insertOnConflictUpdate(
          SyncDeletionTombstoneRow(
              mediaType: mediaType,
              itemKey: itemKey,
              deletedAt: deletedAt,
              remotePublishedAt: 0,
              cloudFolderName:
                  (cloudFolderName == null || cloudFolderName.isEmpty)
                      ? null
                      : cloudFolderName,
              cloudFolderState: TombstoneCloudFolderState.pending.dbValue));

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

  /// 某种资产的删除墓碑，按 itemKey → deletedAt（远端清单剔除本端已删条目用）。
  Future<Map<String, int>> getSyncDeletionDeletedAtByKey(
      String mediaType) async {
    return <String, int>{
      for (final SyncDeletionTombstoneRow row
          in await getSyncDeletionTombstonesOfType(mediaType))
        row.itemKey: row.deletedAt,
    };
  }

  /// 记下某墓碑的云盘书文件夹处置结论（v142，[TombstoneCloudFolderState]）。只在真的
  /// 删掉了（[TombstoneCloudFolderState.deleted]）或核实云盘上本就没有
  /// （[TombstoneCloudFolderState.absent]）时调；删失败保持未处置，下一轮重试。
  Future<void> markSyncDeletionCloudFolderState(String mediaType,
          String itemKey, TombstoneCloudFolderState state) =>
      (update(syncDeletionTombstones)
            ..where((t) =>
                t.mediaType.equals(mediaType) & t.itemKey.equals(itemKey)))
          .write(SyncDeletionTombstonesCompanion(
              cloudFolderState: Value(state.dbValue)));

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

  // ── Profile 分区（v105：统计按 Profile 隔离）────────────────────
  // 住这一层而不是 _FushiDbStatistics：删除原语在 _FushiDbContentMisc、写入 /
  // 读取在 _FushiDbStatistics，mixin 只能向下看，公共解析点必须在两者之下。

  Future<String?> _prefValueOf(String key) async {
    final PreferenceRow? row =
        await (select(preferences)..where((t) => t.key.equals(key)))
            .getSingleOrNull();
    return row?.value;
  }

  /// 当前激活的 Profile id（统计分区键的**唯一**解析点）。
  ///
  /// 读 `active_profile_id` 偏好并验证该 Profile 还在；不在 / 缺失时退到最早建的
  /// Profile（与 fushi 层 `ensureDefaultProfile` 的兜底同序）；库里一个 Profile
  /// 都没有时返回 0——只在纯 DB 测试里出现（app 启动即 `ensureDefaultProfile`），
  /// 此时写入盖 0、读取滤 0，测试里写读自洽。**不在这里建 Profile**：建
  /// Profile 必须连带快照设置（`snapshotCurrentSettings`，在 fushi 层），DB 层
  /// 造一个空快照的 Profile 会让下次 `applyProfile` 把全部偏好剪光。
  Future<int> resolveActiveProfileId() async {
    final String? raw = await _prefValueOf(kActiveProfileIdPrefKey);
    final int fromPref = int.tryParse(raw ?? '') ?? -1;
    if (fromPref > 0 && await getProfileById(fromPref) != null) {
      return fromPref;
    }
    final List<ProfileRow> all = await getAllProfiles();
    return all.isEmpty ? 0 : all.first.id;
  }

  /// legacy 统计家族归属的 Profile id（[kStatLegacyProfileIdPrefKey]）；null =
  /// 无归属 = 对所有 Profile 可见。
  Future<int?> getStatLegacyProfileId() async {
    final String? raw = await _prefValueOf(kStatLegacyProfileIdPrefKey);
    final int? id = int.tryParse(raw ?? '');
    return id != null && id > 0 ? id : null;
  }

  /// legacy 统计行对 [profileId] 是否可见（读取面与「清空全部」的 legacy 删行
  /// 共用同一判据：看不见的历史不能被另一个 Profile 的清空连带删掉）。
  Future<bool> legacyStatsVisibleTo(int profileId) async {
    final int? owner = await getStatLegacyProfileId();
    return owner == null || owner == profileId;
  }

  /// 缺席 `profileId` 的段补上当前激活 Profile（写入方不用知道 Profile）。
  Future<StudySegmentsCompanion> _stampStudySegmentProfile(
    StudySegmentsCompanion row,
  ) async =>
      row.profileId.present
          ? row
          : row.copyWith(profileId: Value(await resolveActiveProfileId()));

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

  // ── language profiles ────────────────────────────────────────────
  // 键是**归一化后**的语言标签（`normalizeLanguageBinding`），不是内容语言列里
  // 的原始 BCP-47 串。归一在 fushi 侧的 ProfileRepository 做，这层只存取。
  Future<List<LanguageProfileRow>> getAllLanguageProfiles() =>
      select(languageProfiles).get();

  Future<LanguageProfileRow?> getLanguageProfile(String languageTag) =>
      (select(languageProfiles)
            ..where((t) => t.languageTag.equals(languageTag)))
          .getSingleOrNull();

  Future<void> setLanguageProfile(String languageTag, int profileId) =>
      into(languageProfiles).insertOnConflictUpdate(
        LanguageProfilesCompanion.insert(
          languageTag: languageTag,
          profileId: profileId,
        ),
      );

  Future<int> deleteLanguageProfile(String languageTag) =>
      (delete(languageProfiles)..where((t) => t.languageTag.equals(languageTag)))
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

  /// 一次取回某维度的全部基线（assetKey → baseVersion）。
  ///
  /// 互联进度 sweep 每轮要看每个条目的基线与「待确认」基线，逐条
  /// [getSyncBaseline] 是 N+1；整轮先用这里一条查询读齐，在内存里判定。
  Future<Map<String, int>> getSyncBaselinesForDimension(
    String dimension,
  ) async {
    final List<SyncBaselineRow> rows = await (select(
      syncBaselines,
    )..where((t) => t.dimension.equals(dimension))).get();
    return <String, int>{
      for (final SyncBaselineRow row in rows) row.assetKey: row.baseVersion,
    };
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

  /// 删掉某资产某维度的基线行（无记录时无操作）。
  Future<void> deleteSyncBaseline(String assetKey, String dimension) =>
      (delete(syncBaselines)
            ..where((t) =>
                t.assetKey.equals(assetKey) & t.dimension.equals(dimension)))
          .go();
}

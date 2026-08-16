// 库结构：来源库 / Mihon / 互联对端 / 系列 / 书架 / 合集 / 墓碑 / cue / SRT / 阅读位置（God 类拆分 2026-08：part+mixin，仓库 reader_fushi
// part 先例；mixin 是真类成员——可被测试子类 override、虚分派正常
// （extension 方案在此翻车过）；私有 mixin 不进公共 API 面。
part of 'database.dart';

mixin _FushiDbLibrary on _$FushiDatabase, _FushiDbTagsSync {
  // ── media_sources ───────────────────────────────────────────────
  // TODO-817：网络/本地来源库 CRUD。configJson 绝不裸存明文密码（本地恒 NULL，
  // 网络只存凭据引用键，密码本体 M3 才落）。

  /// 插入一条来源，返回自增 id。
  Future<int> insertMediaSource(MediaSourcesCompanion source) =>
      into(mediaSources).insert(source);

  /// 全部来源，按 sortOrder 升序、id 升序（列表稳定排序）。
  Future<List<MediaSourceRow>> getAllMediaSources() => (select(mediaSources)
        ..orderBy([
          (t) => OrderingTerm(expression: t.sortOrder),
          (t) => OrderingTerm(expression: t.id),
        ]))
      .get();

  /// 按媒体种类（'video' | 'book'）过滤，仍按 sortOrder、id 升序。
  Future<List<MediaSourceRow>> getMediaSourcesByKind(String mediaKind) =>
      (select(mediaSources)
            ..where((t) => t.mediaKind.equals(mediaKind))
            ..orderBy([
              (t) => OrderingTerm(expression: t.sortOrder),
              (t) => OrderingTerm(expression: t.id),
            ]))
          .get();

  /// 按 id 取单条来源（不存在返回 null）。
  Future<MediaSourceRow?> getMediaSourceById(int id) =>
      (select(mediaSources)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// 删除来源：依赖 FK onDelete:setNull，归属本来源的 video_books / epub_books
  /// 自动把 source_id 归 NULL（条目保留，不连坐删）。返回删除行数。
  Future<int> deleteMediaSource(int id) =>
      (delete(mediaSources)..where((t) => t.id.equals(id))).go();

  /// 回写一次扫描结果（媒体数 / 时间 / 失败原因）。
  Future<void> updateMediaSourceScanResult({
    required int id,
    required int mediaCount,
    required DateTime lastScannedAt,
    String? lastScanError,
  }) =>
      (update(mediaSources)..where((t) => t.id.equals(id))).write(
        MediaSourcesCompanion(
          mediaCount: Value(mediaCount),
          lastScannedAt: Value(lastScannedAt),
          lastScanError: Value(lastScanError),
        ),
      );

  /// 统计某来源当前**累计拥有**的媒体条目数（TODO-1036）。
  ///
  /// [mediaCount] 列记的是「上次扫描新增条目数」（去重跳过的已存在书不计），
  /// 不能当总数显示。这里直接 COUNT 反向指向本来源的 epub_books / video_books
  /// 行：[mediaKind]=='book' → epub_books，'video' → video_books，
  /// 'manga' → epub_books 中 `format='manga'` 的漫画行（漫画与书是不同的
  /// MediaSources 行，sourceId 天然互不污染；format 过滤只是把值域契约显式化），
  /// 其它种类返回 0。
  Future<int> countMediaBySourceId(int sourceId, String mediaKind) async {
    final Expression<int> cnt = countAll();
    if (mediaKind == 'book') {
      final TypedResult row = await (selectOnly(epubBooks)
            ..where(epubBooks.sourceId.equals(sourceId))
            ..addColumns(<Expression<Object>>[cnt]))
          .getSingle();
      return row.read(cnt) ?? 0;
    }
    if (mediaKind == 'manga') {
      final TypedResult row = await (selectOnly(epubBooks)
            ..where(epubBooks.sourceId.equals(sourceId) &
                epubBooks.format.equals('manga'))
            ..addColumns(<Expression<Object>>[cnt]))
          .getSingle();
      return row.read(cnt) ?? 0;
    }
    if (mediaKind == 'video') {
      final TypedResult row = await (selectOnly(videoBooks)
            ..where(videoBooks.sourceId.equals(sourceId))
            ..addColumns(<Expression<Object>>[cnt]))
          .getSingle();
      return row.read(cnt) ?? 0;
    }
    return 0;
  }

  /// 更新来源显示名。
  Future<void> updateMediaSourceLabel(int id, String label) =>
      (update(mediaSources)..where((t) => t.id.equals(id)))
          .write(MediaSourcesCompanion(label: Value(label)));

  /// 更新来源排序权重（来源库 UI 拖拽重排后逐行回写，与 [getAllMediaSources] /
  /// [getMediaSourcesByKind] 的 orderBy(sortOrder, id) 对齐）。只写 sortOrder 列，
  /// 不动其它字段。
  Future<void> updateMediaSourceSortOrder(int id, int sortOrder) =>
      (update(mediaSources)..where((t) => t.id.equals(id)))
          .write(MediaSourcesCompanion(sortOrder: Value(sortOrder)));

  // ── Mihon manga extensions (v63) ───────────────────────────────

  Future<List<MangaExtensionStoreRow>> getMangaExtensionStores() =>
      (select(mangaExtensionStores)
            ..orderBy([
              (t) => OrderingTerm(expression: t.sortOrder),
              (t) => OrderingTerm(expression: t.indexUrl),
            ]))
          .get();

  Future<void> upsertMangaExtensionStore(MangaExtensionStoresCompanion store) =>
      into(mangaExtensionStores).insertOnConflictUpdate(store);

  Future<int> deleteMangaExtensionStore(String indexUrl) =>
      (delete(mangaExtensionStores)..where((t) => t.indexUrl.equals(indexUrl)))
          .go();

  Future<List<MangaExtensionRow>> getMangaExtensions() =>
      (select(mangaExtensions)
            ..orderBy([
              (t) => OrderingTerm(expression: t.name),
              (t) => OrderingTerm(expression: t.packageName),
            ]))
          .get();

  Future<MangaExtensionRow?> getMangaExtension(String packageName) =>
      (select(mangaExtensions)..where((t) => t.packageName.equals(packageName)))
          .getSingleOrNull();

  Future<void> upsertMangaExtension(MangaExtensionsCompanion extension) =>
      into(mangaExtensions).insertOnConflictUpdate(extension);

  Future<void> setMangaExtensionEnabled(String packageName, bool enabled) =>
      (update(mangaExtensions)..where((t) => t.packageName.equals(packageName)))
          .write(MangaExtensionsCompanion(enabled: Value(enabled)));

  Future<void> deleteMangaExtension(String packageName) =>
      transaction(() async {
        await (delete(mangaSourcePreferences)
              ..where((t) => t.extensionPackage.equals(packageName)))
            .go();
        await (delete(mangaOnlineSources)
              ..where((t) => t.extensionPackage.equals(packageName)))
            .go();
        await (delete(mangaExtensions)
              ..where((t) => t.packageName.equals(packageName)))
            .go();
      });

  Future<List<MangaOnlineSourceRow>> getMangaOnlineSources() =>
      (select(mangaOnlineSources)
            ..orderBy([
              (t) => OrderingTerm(
                    expression: t.pinned,
                    mode: OrderingMode.desc,
                  ),
              (t) => OrderingTerm(expression: t.sortOrder),
              (t) => OrderingTerm(expression: t.name),
            ]))
          .get();

  Future<void> replaceMangaOnlineSources(
    String packageName,
    Iterable<MangaOnlineSourcesCompanion> sources,
  ) =>
      transaction(() async {
        final List<MangaOnlineSourceRow> previous =
            await (select(mangaOnlineSources)
                  ..where((t) => t.extensionPackage.equals(packageName)))
                .get();
        final Map<String, MangaOnlineSourceRow> settings =
            <String, MangaOnlineSourceRow>{
          for (final MangaOnlineSourceRow row in previous) row.sourceId: row,
        };
        await (delete(mangaOnlineSources)
              ..where((t) => t.extensionPackage.equals(packageName)))
            .go();
        for (final MangaOnlineSourcesCompanion source in sources) {
          final String? sourceId =
              source.sourceId.present ? source.sourceId.value : null;
          final MangaOnlineSourceRow? old =
              sourceId == null ? null : settings[sourceId];
          await into(mangaOnlineSources).insert(
            source.copyWith(
              enabled: old == null ? source.enabled : Value(old.enabled),
              pinned: old == null ? source.pinned : Value(old.pinned),
              sortOrder: old == null ? source.sortOrder : Value(old.sortOrder),
            ),
          );
        }
      });

  Future<void> updateMangaOnlineSourceSettings({
    required String extensionPackage,
    required String sourceId,
    bool? enabled,
    bool? pinned,
    int? sortOrder,
  }) =>
      (update(mangaOnlineSources)
            ..where((t) =>
                t.extensionPackage.equals(extensionPackage) &
                t.sourceId.equals(sourceId)))
          .write(
        MangaOnlineSourcesCompanion(
          enabled: enabled == null ? const Value.absent() : Value(enabled),
          pinned: pinned == null ? const Value.absent() : Value(pinned),
          sortOrder:
              sortOrder == null ? const Value.absent() : Value(sortOrder),
        ),
      );

  Future<List<MangaSourcePreferenceRow>> getMangaSourcePreferences(
    String extensionPackage,
    String sourceId,
  ) =>
      (select(mangaSourcePreferences)
            ..where((t) =>
                t.extensionPackage.equals(extensionPackage) &
                t.sourceId.equals(sourceId))
            ..orderBy([(t) => OrderingTerm(expression: t.preferenceKey)]))
          .get();

  Future<void> upsertMangaSourcePreference(
          MangaSourcePreferencesCompanion preference) =>
      into(mangaSourcePreferences).insertOnConflictUpdate(preference);

  Future<void> clearMangaSourcePreferences(
    String extensionPackage,
    String sourceId,
  ) =>
      (delete(mangaSourcePreferences)
            ..where((t) =>
                t.extensionPackage.equals(extensionPackage) &
                t.sourceId.equals(sourceId)))
          .go();

  Future<List<MangaTrustedSignerRow>> getMangaTrustedSigners() =>
      select(mangaTrustedSigners).get();

  Future<bool> isMangaSignerTrusted(String fingerprint) async =>
      await (select(mangaTrustedSigners)
            ..where((t) => t.fingerprint.equals(fingerprint)))
          .getSingleOrNull() !=
      null;

  Future<void> trustMangaSigner(MangaTrustedSignersCompanion signer) =>
      into(mangaTrustedSigners).insertOnConflictUpdate(signer);

  // ── fushi_paired_peers (TODO-1017 阶段1) ────────────────────────
  // 互联 per-peer 授权凭据 CRUD。🔴 token 是敏感凭据（明文列存，方案待定），
  // 绝不写日志、绝不进 sync/backup 明文导出。

  /// 全部已配对对端，按 pairedAtMs 升序（配对先后稳定排序）、id 升序兜底同戳。
  Future<List<FushiPairedPeerRow>> getPairedPeers() => (select(fushiPairedPeers)
        ..orderBy([
          (t) => OrderingTerm(expression: t.pairedAtMs),
          (t) => OrderingTerm(expression: t.id),
        ]))
      .get();

  /// 按 peerId 幂等 upsert（存在则整行更新）。ON CONFLICT 目标必须显式指定
  /// [peerId]（非主键 id）：不指定时 drift 默认按主键 id 冲突，而 upsert 契约是
  /// 按 peerId 认定同一设备（id 自增每次不同），会误撞 peerId UNIQUE 抛错。
  /// 重复配对同一设备只更新其 token / deviceName / lastSeenIp，不新增行。
  Future<void> upsertPairedPeer(FushiPairedPeersCompanion peer) =>
      into(fushiPairedPeers).insert(peer,
          onConflict: DoUpdate((_) => peer, target: [fushiPairedPeers.peerId]));

  /// 吊销一台已配对设备（按 peerId 删行），返回删除的行数（0 = 无此对端）。
  Future<int> revokePairedPeer(String peerId) =>
      (delete(fushiPairedPeers)..where((t) => t.peerId.equals(peerId))).go();

  // ── series (TODO-616 A) ─────────────────────────────────────────
  /// 全部系列，按 sortOrder 升序、id 升序（卡片列表稳定排序）。
  Future<List<SeriesRow>> getAllSeries() => (select(series)
        ..orderBy([
          (t) => OrderingTerm(expression: t.sortOrder),
          (t) => OrderingTerm(expression: t.id),
        ]))
      .get();

  /// 新建系列，返回自增 id。createdAt 用当前毫秒戳，sortOrder 默认排到末尾
  /// （现有最大 sortOrder + 1，空表为 0）。
  Future<int> createSeries(String name) => transaction(() async {
        final int nextOrder = await _nextSeriesSortOrder();
        return into(series).insert(SeriesCompanion.insert(
          name: name,
          sortOrder: Value(nextOrder),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
      });

  Future<int> _nextSeriesSortOrder() async {
    final SeriesRow? last = await (select(series)
          ..orderBy([(t) => OrderingTerm.desc(t.sortOrder)])
          ..limit(1))
        .getSingleOrNull();
    return last == null ? 0 : last.sortOrder + 1;
  }

  /// 改系列名（只写 name 列）。
  Future<void> updateSeriesName(int id, String name) =>
      (update(series)..where((t) => t.id.equals(id)))
          .write(SeriesCompanion(name: Value(name)));

  /// 改系列卡片排序权重（拖拽重排后逐行回写，与 [getAllSeries] orderBy 对齐）。
  Future<void> updateSeriesSortOrder(int id, int sortOrder) =>
      (update(series)..where((t) => t.id.equals(id)))
          .write(SeriesCompanion(sortOrder: Value(sortOrder)));

  /// 删系列：依赖 FK onDelete:setNull，归属本系列的 shelf_entries 自动把 seriesId
  /// 归 NULL（成员散回书架，不连坐删条目）。返回删除行数。
  Future<int> deleteSeries(int id) =>
      (delete(series)..where((t) => t.id.equals(id))).go();

  // ── shelf_entries (TODO-616 B 排序 + A 归属) ─────────────────────
  /// 取单条目映射行（不存在返回 null）。
  Future<ShelfEntryRow?> getShelfEntry(MediaKind mediaType, String entryKey) =>
      (select(shelfEntries)
            ..where((t) =>
                t.mediaType.equals(mediaType.dbValue) &
                t.entryKey.equals(entryKey)))
          .getSingleOrNull();

  /// 全部映射行（渲染层一次性批量预取，内存 join 三表 + 远端列表，避免 N+1）。
  Future<List<ShelfEntryRow>> getAllShelfEntries() =>
      select(shelfEntries).get();

  /// 某系列下的全部成员映射行。
  Future<List<ShelfEntryRow>> getShelfEntriesBySeries(int seriesId) =>
      (select(shelfEntries)..where((t) => t.seriesId.equals(seriesId))).get();

  /// 拖拽回写排序权重，按需建行：已有行只改 sortOrder（**不动 seriesId**，部分
  /// 更新避免清空已有归属）；无行则插一条 seriesId=NULL 的新行。
  Future<void> upsertShelfOrder(
          MediaKind mediaType, String entryKey, int sortOrder) =>
      transaction(() async {
        final int updated = await (update(shelfEntries)
              ..where((t) =>
                  t.mediaType.equals(mediaType.dbValue) &
                  t.entryKey.equals(entryKey)))
            .write(ShelfEntriesCompanion(sortOrder: Value(sortOrder)));
        if (updated == 0) {
          await into(shelfEntries).insert(ShelfEntriesCompanion.insert(
            mediaType: mediaType.dbValue,
            entryKey: entryKey,
            sortOrder: Value(sortOrder),
          ));
        }
      });

  /// 批量回写排序权重（退出重排页时一次落盘）：单事务内逐条 update-or-insert，
  /// 避免逐条 [upsertShelfOrder] 的 N 次小事务开销。每个三元组
  /// `(mediaType, entryKey, sortOrder)` 语义同 [upsertShelfOrder]（只改 sortOrder
  /// 不动 seriesId，部分更新保归属）。
  Future<void> batchUpsertShelfOrder(
          List<({MediaKind mediaType, String entryKey, int sortOrder})>
              orders) =>
      transaction(() async {
        for (final ({MediaKind mediaType, String entryKey, int sortOrder}) o
            in orders) {
          final int updated = await (update(shelfEntries)
                ..where((t) =>
                    t.mediaType.equals(o.mediaType.dbValue) &
                    t.entryKey.equals(o.entryKey)))
              .write(ShelfEntriesCompanion(sortOrder: Value(o.sortOrder)));
          if (updated == 0) {
            await into(shelfEntries).insert(ShelfEntriesCompanion.insert(
              mediaType: o.mediaType.dbValue,
              entryKey: o.entryKey,
              sortOrder: Value(o.sortOrder),
            ));
          }
        }
      });

  /// 设/清条目归属系列（[seriesId] 为 null = 移出系列）。按需建行；已有行只改
  /// seriesId（**不动 sortOrder**，部分更新避免重置已有排序）。
  Future<void> setSeriesForEntry(
          MediaKind mediaType, String entryKey, int? seriesId) =>
      transaction(() async {
        final int updated = await (update(shelfEntries)
              ..where((t) =>
                  t.mediaType.equals(mediaType.dbValue) &
                  t.entryKey.equals(entryKey)))
            .write(ShelfEntriesCompanion(seriesId: Value(seriesId)));
        if (updated == 0) {
          await into(shelfEntries).insert(ShelfEntriesCompanion.insert(
            mediaType: mediaType.dbValue,
            entryKey: entryKey,
            seriesId: Value(seriesId),
          ));
        }
      });

  /// 幂等删一条目映射行（删 0 行不报错）。四个删书 DAO 方法的 transaction() 体内
  /// 同事务调用（TODO-616 §0🔴3），删 shelf_entry 与删书行真原子。
  Future<int> deleteShelfEntry(MediaKind mediaType, String entryKey) =>
      (delete(shelfEntries)
            ..where((t) =>
                t.mediaType.equals(mediaType.dbValue) &
                t.entryKey.equals(entryKey)))
          .go();

  // v83：migrateShelfEntryKey（远端书下载后 bookKey 漂移改键，TODO-616 §0🔴2）
  // 已删除——epub 域 entryKey 换稳定 uid 后导入时刻定死、不再漂移；且该路径在删
  // 除前已恒 no-op（唯一能建 downloadId 行的写入方早已随 shelf_reorder_page 消亡）。

  // ── media collections (统一合集：Jellyfin 式容器 + 成员引用) ─────────
  /// 合集两张表（media_collections / media_collection_items）的「数据变了」信号：
  /// 任一表写入即 emit（不带数据，消费方自行重载分组映射）。
  ///
  /// 库页的合集折叠映射是页级快照（进页拉一次），写入方却有很多：后台合集同步
  /// （互联 live 端点 / 云 __collections__ 清单）、备份导入、其它页面的合集编辑。
  /// 靠「每个写入路径各自记得通知页面」必然漏——BUG-1692 实证：互联合集同步落库
  /// 后视频页 _collectionsById 停在首帧快照，host 合集恒散卡直到重启。数据层单一
  /// 事件源让任何写入者天然覆盖，无需逐路登记。
  ///
  /// 用手动 [StreamController] + [tableUpdates]，**不用** drift keyed `.watch()`
  /// （取消订阅遗留 `Timer.run` 挂死 widget 测试，BUG-834，同
  /// [watchDashboardDataChanges] 范式）。
  Stream<void> watchCollectionTablesChanged() {
    late final StreamController<void> controller;
    StreamSubscription<void>? updatesSub;
    controller = StreamController<void>(
      onListen: () {
        updatesSub = tableUpdates(
          TableUpdateQuery
              .onAllTables(<ResultSetImplementation<dynamic, dynamic>>[
            mediaCollections,
            mediaCollectionItems,
          ]),
        ).listen((_) {
          if (!controller.isClosed) controller.add(null);
        });
      },
      onCancel: () async {
        await updatesSub?.cancel();
      },
    );
    return controller.stream;
  }

  /// 全部合集，按 sortOrder 升序、id 升序（卡片列表稳定排序，同 [getAllSeries] 范式）。
  Future<List<MediaCollectionRow>> getAllMediaCollections() =>
      (select(mediaCollections)
            ..orderBy([
              (t) => OrderingTerm(expression: t.sortOrder),
              (t) => OrderingTerm(expression: t.id),
            ]))
          .get();

  Future<MediaCollectionRow?> getMediaCollectionById(int id) =>
      (select(mediaCollections)..where((t) => t.id.equals(id)))
          .getSingleOrNull();

  /// 绑定/清除合集的 AniList 系列 id（schema v45，字幕批量下载用）。[anilistId] 为 null
  /// 时清除绑定（回退合集名现解析）。
  Future<void> setMediaCollectionAnilistId(int id, int? anilistId) =>
      (update(mediaCollections)..where((t) => t.id.equals(id))).write(
        MediaCollectionsCompanion(anilistId: Value<int?>(anilistId)),
      );

  /// 更新系列（合集）级音轨偏好（schema v52，恢复同系列音轨记忆）。[audioTrackId]
  /// 为 null 时清除（加载回退各集 per-book / libmpv 默认）。
  Future<void> updateMediaCollectionAudioTrackId(
          int id, String? audioTrackId) =>
      (update(mediaCollections)..where((t) => t.id.equals(id))).write(
        MediaCollectionsCompanion(audioTrackId: Value<String?>(audioTrackId)),
      );

  /// 更新系列（合集）级字幕调轴（音画延迟毫秒，schema v52，恢复同系列调轴记忆）。
  /// [delayMs] 为 null 时清除（加载回退各集 per-book / 0）。
  Future<void> updateMediaCollectionSubtitleDelayMs(int id, int? delayMs) =>
      (update(mediaCollections)..where((t) => t.id.equals(id))).write(
        MediaCollectionsCompanion(subtitleDelayMs: Value<int?>(delayMs)),
      );

  /// 更新系列（合集）级**副字幕**独立调轴（毫秒，schema v86，TODO-2837，同系列
  /// 副轨调轴记忆）。[delayMs] 为 null 时清除（加载回退各集 per-book；两层都
  /// null = 副字幕跟随主字幕调轴）。
  Future<void> updateMediaCollectionSecondarySubtitleDelayMs(
          int id, int? delayMs) =>
      (update(mediaCollections)..where((t) => t.id.equals(id))).write(
        MediaCollectionsCompanion(
            secondarySubtitleDelayMs: Value<int?>(delayMs)),
      );

  /// 新建合集，返回自增 id。sortOrder 默认排末尾（现有最大 +1，空表 0）。同事务清
  /// 同自然键的合集级删除墓碑（重建 = 撤销删除，仿插书清书墓碑 [insertEpubBook]
  /// 一律；不清成员墓碑——成员重加走 [addToCollection] 逐键清）。
  Future<int> createMediaCollection(String name,
          {String collectionType = 'collection'}) =>
      transaction(() async {
        // 先按自然键查重：已存在同 (name, collectionType) 行则复用其 id，绝不再造重复
        // 自然键行（否则同名两行让合集同步引擎每轮判不一致永不收敛，BUG 修复）。
        final MediaCollectionRow? existing =
            await getMediaCollectionByNaturalKey(name, collectionType);
        if (existing != null) return existing.id;
        final int nextOrder = await _nextMediaCollectionSortOrder();
        await (delete(collectionMemberTombstones)
              ..where((t) =>
                  t.collectionName.equals(name) &
                  t.collectionType.equals(collectionType) &
                  t.mediaType
                      .equals(FushiDatabase.collectionTombstoneSentinel) &
                  t.entryKey.equals(FushiDatabase.collectionTombstoneSentinel)))
            .go();
        return into(mediaCollections).insert(MediaCollectionsCompanion.insert(
          name: name,
          collectionType: Value(collectionType),
          sortOrder: Value(nextOrder),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
      });

  Future<int> _nextMediaCollectionSortOrder() async {
    final MediaCollectionRow? last = await (select(mediaCollections)
          ..orderBy([(t) => OrderingTerm.desc(t.sortOrder)])
          ..limit(1))
        .getSingleOrNull();
    return last == null ? 0 : last.sortOrder + 1;
  }

  /// 改合集名（改 name 列 + 维护跨端合集同步墓碑）。
  ///
  /// 跨端合集是成员/合集**并集**同步：只改 name 而不给旧自然键写合集级墓碑、不清新
  /// 键哨兵，会让「改一次名」在全网多出一个旧名副本永不自愈（旧名在对端并集里复活）。
  /// 故改名事务 = 改 name + 旧 (oldName,type) 清墓碑后写哨兵（同 deleteMediaCollection，
  /// 让对端删掉旧名副本）+ 清新 (name,type) 哨兵墓碑（同 createMediaCollection，
  /// 让新名不被自己旧删除墓碑秒杀）。改成同名(no-op)或目标 id 不存在时不动墓碑。
  Future<void> renameMediaCollection(int id, String name) =>
      transaction(() async {
        final MediaCollectionRow? col = await getMediaCollectionById(id);
        if (col == null || col.name == name) {
          await (update(mediaCollections)..where((t) => t.id.equals(id)))
              .write(MediaCollectionsCompanion(name: Value(name)));
          return;
        }
        final String oldName = col.name;
        final String type = col.collectionType;
        await (update(mediaCollections)..where((t) => t.id.equals(id)))
            .write(MediaCollectionsCompanion(name: Value(name)));
        // 旧 (oldName, type)：清其全部墓碑，只留合集级哨兵（镜像删除，让对端删旧名副本）。
        await (delete(collectionMemberTombstones)
              ..where((t) =>
                  t.collectionName.equals(oldName) &
                  t.collectionType.equals(type)))
            .go();
        await upsertCollectionMemberTombstone(
          collectionName: oldName,
          collectionType: type,
          mediaType: FushiDatabase.collectionTombstoneSentinel,
          entryKey: FushiDatabase.collectionTombstoneSentinel,
          deletedAt: DateTime.now().millisecondsSinceEpoch,
        );
        // 新 (name, type)：清其合集级哨兵墓碑（否则新名会被自己旧删除墓碑秒杀）。
        await (delete(collectionMemberTombstones)
              ..where((t) =>
                  t.collectionName.equals(name) &
                  t.collectionType.equals(type) &
                  t.mediaType
                      .equals(FushiDatabase.collectionTombstoneSentinel) &
                  t.entryKey.equals(FushiDatabase.collectionTombstoneSentinel)))
            .go();
      });

  /// 改合集卡排序权重（拖拽重排后逐行回写）。
  Future<void> updateMediaCollectionSortOrder(int id, int sortOrder) =>
      (update(mediaCollections)..where((t) => t.id.equals(id)))
          .write(MediaCollectionsCompanion(sortOrder: Value(sortOrder)));

  /// 设/清自定义封面成员（null = 回到自动推导）。
  Future<void> updateMediaCollectionCover(int id, String? coverSource) =>
      (update(mediaCollections)..where((t) => t.id.equals(id)))
          .write(MediaCollectionsCompanion(coverSource: Value(coverSource)));

  /// 设/清**合集自有**封面图路径（[MediaCollections.coverPath]，schema v61）。
  ///
  /// 与 [updateMediaCollectionCover] 是两回事：那个记「借哪个成员的封面」，这个记
  /// 合集自己那张图的绝对路径。null = 清掉、回落成员借用链。
  /// **只写 media_collections 一行**——不碰任何 [VideoBooks] 成员（BUG-1211）。
  Future<void> updateMediaCollectionCoverPath(int id, String? coverPath) =>
      (update(mediaCollections)..where((t) => t.id.equals(id)))
          .write(MediaCollectionsCompanion(coverPath: Value(coverPath)));

  /// 删合集：显式先删本合集全部成员引用行、再删合集（不依赖 FK cascade，测试/生产
  /// 一致；绝不删条目本身）。返回删除的合集行数。同事务写合集级删除墓碑（空哨兵行，
  /// schema v40 防对端并集同步复活），并清本合集残留成员墓碑（合集已删，成员墓碑
  /// 无意义；留着会误杀日后重建同名合集时对端的成员）。
  Future<int> deleteMediaCollection(int id) => transaction(() async {
        final MediaCollectionRow? col = await getMediaCollectionById(id);
        await (delete(mediaCollectionItems)
              ..where((t) => t.collectionId.equals(id)))
            .go();
        await deleteTagAssignmentsForHost(
            TagHostKind.collection, collectionTagEntryKey(id));
        final int deleted = await (delete(mediaCollections)
              ..where((t) => t.id.equals(id)))
            .go();
        if (col != null && deleted > 0) {
          await (delete(collectionMemberTombstones)
                ..where((t) =>
                    t.collectionName.equals(col.name) &
                    t.collectionType.equals(col.collectionType)))
              .go();
          await upsertCollectionMemberTombstone(
            collectionName: col.name,
            collectionType: col.collectionType,
            mediaType: FushiDatabase.collectionTombstoneSentinel,
            entryKey: FushiDatabase.collectionTombstoneSentinel,
            deletedAt: DateTime.now().millisecondsSinceEpoch,
          );
        }
        return deleted;
      });

  /// 某合集全部成员，按 sortIndex 升序、entryKey 升序、mediaType 升序（稳定播放/
  /// 展示序）。
  ///
  /// 三段排序键**恰好等于表的成员身份**（复合主键 `(collectionId, mediaType,
  /// entryKey)` 去掉已被 where 钉死的 collectionId）→ 全序，无并列。
  ///
  /// 末位 mediaType 段是**防御性**的，诚实说明其份量：只排到 entryKey 时，同一合集
  /// 里同 entryKey 的两个不同 mediaType 行（entryKey 是各域裸串——epub=bookKey /
  /// video=bookUid / game=galgames.id，命名空间不交叉是约定、不是 DB 约束）在
  /// sortIndex 也碰撞的情况下，次序就交给了查询计划。当前计划走复合主键索引扫描、
  /// 恰好已经是 mediaType 升序，所以补这一段**今天不改变任何可观测行为**——也因此
  /// 没有能检测其删除的行为测试，别为它编一个假绿守卫。写出来的理由是
  /// [reorderCollectionItems] 拿本查询的结果当槽位基准并**冻结**成永久的致密
  /// sortIndex：喂给冻结操作的读不该依赖计划的巧合。
  Future<List<MediaCollectionItemRow>> getCollectionItems(int collectionId) =>
      (select(mediaCollectionItems)
            ..where((t) => t.collectionId.equals(collectionId))
            ..orderBy([
              (t) => OrderingTerm(expression: t.sortIndex),
              (t) => OrderingTerm(expression: t.entryKey),
              (t) => OrderingTerm(expression: t.mediaType),
            ]))
          .get();

  /// 全部合集成员行（一次查询，供渲染层内存分组算组内 sortIndex，替代逐合集
  /// [getCollectionItems] 的 N+1）。按 collectionId、sortIndex、entryKey、mediaType
  /// 升序，与 [getCollectionItems] 同口径（含末位 mediaType 的全序兜底）——同一
  /// collectionId 的行连续且组内有序，调用方按
  /// [MediaCollectionItemRow.collectionId] 分组即等价于逐合集查。
  Future<List<MediaCollectionItemRow>> getAllCollectionItems() =>
      (select(mediaCollectionItems)
            ..orderBy([
              (t) => OrderingTerm(expression: t.collectionId),
              (t) => OrderingTerm(expression: t.sortIndex),
              (t) => OrderingTerm(expression: t.entryKey),
              (t) => OrderingTerm(expression: t.mediaType),
            ]))
          .get();

  /// `'<mediaType>|<entryKey>'` → 该条目所属的**最小** collectionId（折叠归属：库网格
  /// 里一条目折进 id 最小的合集卡；其余合集卡照常显示、详情页照常含该条目）。单查询
  /// GROUP BY MIN 避免 N+1。
  Future<Map<String, int>> getPrimaryCollectionIdByEntry() async {
    final List<QueryRow> rows = await customSelect(
      'SELECT media_type, entry_key, MIN(collection_id) AS cid '
      'FROM media_collection_items GROUP BY media_type, entry_key',
    ).get();
    return <String, int>{
      for (final QueryRow r in rows)
        '${r.read<String>('media_type')}|${r.read<String>('entry_key')}':
            r.read<int>('cid'),
    };
  }

  Future<int> _nextCollectionSortIndex(int collectionId) async {
    final MediaCollectionItemRow? last = await (select(mediaCollectionItems)
          ..where((t) => t.collectionId.equals(collectionId))
          ..orderBy([(t) => OrderingTerm.desc(t.sortIndex)])
          ..limit(1))
        .getSingleOrNull();
    return last == null ? 0 : last.sortIndex + 1;
  }

  /// 加条目进合集（尾插；重复成员 INSERT OR IGNORE 幂等）。同事务清同键成员墓碑
  /// （schema v40：重新加入 = 撤销移出——否则跨端同步的成员墓碑会把刚加回的成员
  /// 再删掉，防复活变成禁重加）。
  ///
  /// P5：本机已知种类的类型化入口；转移/合并对端未知种类走 [addToCollectionRaw]。
  Future<void> addToCollection(
          int collectionId, MediaKind mediaType, String entryKey) =>
      addToCollectionRaw(collectionId, mediaType.dbValue, entryKey);

  /// [addToCollection] 的裸串版：合集合并/转移把**现有成员行原样搬家**时用——
  /// 行值可能是对端未来新增的未知种类（或旧值域残留），tryParse 丢弃会静默丢
  /// 成员（Never break userspace）。新增本机成员一律走类型化 [addToCollection]。
  Future<void> addToCollectionRaw(
          int collectionId, String mediaType, String entryKey) =>
      transaction(() async {
        final int next = await _nextCollectionSortIndex(collectionId);
        await into(mediaCollectionItems).insert(
          MediaCollectionItemsCompanion.insert(
            collectionId: collectionId,
            mediaType: mediaType,
            entryKey: entryKey,
            sortIndex: Value(next),
          ),
          mode: InsertMode.insertOrIgnore,
        );
        final MediaCollectionRow? col =
            await getMediaCollectionById(collectionId);
        if (col != null) {
          await deleteCollectionMemberTombstone(
            collectionName: col.name,
            collectionType: col.collectionType,
            mediaType: mediaType,
            entryKey: await _tombstoneEntryKeyOf(mediaType, entryKey),
          );
        }
      });

  /// uid → bookKey 反向换算口（v83；resolveEpubBookUid 的对偶，住本 mixin 是
  /// 因为 on 链拓扑——misc mixin 在本 mixin 之上）。出 wire / 写 bookKey 域
  /// 墓碑前用。书不在库返回 null——透传行（远端 epub 的 entryKey 本就是对端
  /// bookKey）反查不上时直接沿用原值即闭环。
  Future<String?> resolveEpubBookKeyByUid(String uid) async {
    if (uid.isEmpty) return null;
    final String? bookKey = await (selectOnly(epubBooks)
          ..addColumns([epubBooks.bookKey])
          ..where(epubBooks.uid.equals(uid)))
        .map((r) => r.read(epubBooks.bookKey))
        .getSingleOrNull();
    return bookKey;
  }

  /// 成员墓碑键域归一（v83）：墓碑冻结在 **bookKey 域**（= wire 域）——它是
  /// 跨端防复活证据，必须在成员行消亡后仍可与对端（bookKey 键）直比。epub 成
  /// 员行键是本机 uid → 写/清墓碑前反查 bookKey；反查不上 = 透传行（原值本就
  /// 是对端 bookKey）照抄即闭环。非 epub 域键原样。
  Future<String> _tombstoneEntryKeyOf(String mediaType, String entryKey) async {
    if (mediaType != MediaKind.epub.dbValue) return entryKey;
    return await resolveEpubBookKeyByUid(entryKey) ?? entryKey;
  }

  /// 移出成员；移空后自动删该合集（沿用旧 removeEntryFromSeries 语义，避免留 0 成员
  /// 孤儿合集卡）。同事务写成员移出墓碑（schema v40：跨端合集同步是成员并集，无墓碑
  /// 则本端移出的成员会被对端并集复活）。移空自删**不**写合集级墓碑：用户意图只是
  /// 移出成员，合集在对端若还有其它成员应继续存在（成员墓碑已足够收敛）。
  ///
  /// P5：本机已知种类的类型化入口；按成员**行值**移出（可能未知种类）走
  /// [removeFromCollectionRaw]。
  Future<void> removeFromCollection(
          int collectionId, MediaKind mediaType, String entryKey) =>
      removeFromCollectionRaw(collectionId, mediaType.dbValue, entryKey);

  /// [removeFromCollection] 的裸串版：详情页按现有成员行移出时，行值可能是对端
  /// 未来新增的未知种类——必须能原样移出，tryParse 丢弃会让该成员永远移不掉。
  Future<void> removeFromCollectionRaw(
          int collectionId, String mediaType, String entryKey) =>
      transaction(() async {
        final MediaCollectionRow? col =
            await getMediaCollectionById(collectionId);
        await (delete(mediaCollectionItems)
              ..where((t) =>
                  t.collectionId.equals(collectionId) &
                  t.mediaType.equals(mediaType) &
                  t.entryKey.equals(entryKey)))
            .go();
        if (col != null) {
          await upsertCollectionMemberTombstone(
            collectionName: col.name,
            collectionType: col.collectionType,
            mediaType: mediaType,
            // v83：墓碑冻结 bookKey 域（见 [_tombstoneEntryKeyOf]）——uid 域
            // 墓碑会原样出 wire（本机 uid 泄漏）、对端匹配不上（移出不传播、
            // 本端下轮并集复活刚移出的成员）。
            entryKey: await _tombstoneEntryKeyOf(mediaType, entryKey),
            deletedAt: DateTime.now().millisecondsSinceEpoch,
          );
        }
        final List<MediaCollectionItemRow> remaining =
            await (select(mediaCollectionItems)
                  ..where((t) => t.collectionId.equals(collectionId)))
                .get();
        if (remaining.isEmpty) {
          await deleteTagAssignmentsForHost(
              TagHostKind.collection, collectionTagEntryKey(collectionId));
          await (delete(mediaCollections)
                ..where((t) => t.id.equals(collectionId)))
              .go();
        }
      });

  /// 合集内重排：[ordered] 表达**它点名的那批成员之间的新相对顺序**，本方法负责把它
  /// 合并回全表并把 sortIndex 回写成致密 `0..n-1`（退出重排页一次落盘）。同事务 bump
  /// 本合集 orderUpdatedAt = now（schema v40 跨端手动序整合集 LWW 的比较键，只有真实
  /// 人为改序走这里；同步应用对端顺序走 [setCollectionOrderUpdatedAt] 镜像对端时间戳，
  /// 绝不 bump now——否则同步会伪装成更新的人为改序）。
  ///
  /// BUG-1194 根因修复——**不变量归 DAO 所有，不是各调用方的自觉**：
  /// 合集详情页天然只渲染成员子集（视频详情页按 mediaType 只显示 video；书架网格详情页
  /// 按标签过滤），而 `media_collection_items.mediaType` 无 CHECK 约束、一个合集可混多种
  /// 种类（「加入合集」弹窗列全表不按种类过滤；合集同步/备份合并按 `(name, collectionType)`
  /// 自然键对齐并原样并入对端裸串 mediaType，两端各建同名合集同步一轮即混合）。旧实现
  /// 直接按 [ordered] 的下标写 sortIndex：调用方只要传子集，未点名的成员就留着旧
  /// sortIndex 与新写的致密 `0..n-1` **碰撞**，[getCollectionItems] 平手退化按 entryKey
  /// 排，用户在网格详情页排好的跨种类顺序被打乱，还随同事务 bump 的 orderUpdatedAt 以
  /// LWW 赢家身份推给全部对端。修在页面里治标——每个现有和将来的调用方都得自己记得
  /// 合并；修在这里治本：**传子集是合法用法**，未点名的成员由本方法保证留在原槽位。
  ///
  /// 顺带自愈：任何一次重排都把全表写成致密序，历史遗留的碰撞 sortIndex 就此消除。
  /// 合并规则（含并发移出/重复键的容错）见 [mergeCollectionOrder]。
  Future<void> reorderCollectionItems(
          int collectionId, List<CollectionMemberKey> ordered) =>
      _reorderCollectionItems(
        collectionId,
        ordered,
        bumpOrderUpdatedAt: true,
      );

  /// 自动整理合集成员顺序，不把机器扫描伪装成用户手动排序。
  ///
  /// 与 [reorderCollectionItems] 拥有相同的子集合并与致密 sortIndex 不变量，唯一
  /// 差别是不更新 `orderUpdatedAt`。来源扫描、迁移等确定性整理应走这里；交互式拖拽
  /// 仍必须走 [reorderCollectionItems]，让跨端 LWW 能识别真正的用户意图。
  Future<void> reorderCollectionItemsAutomatically(
          int collectionId, List<CollectionMemberKey> ordered) =>
      _reorderCollectionItems(
        collectionId,
        ordered,
        bumpOrderUpdatedAt: false,
      );

  Future<void> _reorderCollectionItems(
    int collectionId,
    List<CollectionMemberKey> ordered, {
    required bool bumpOrderUpdatedAt,
  }) =>
      transaction(() async {
        // 事务内取当前全表顺序作槽位基准（[getCollectionItems] 的
        // sortIndex→entryKey→mediaType 全序 = 用户此刻看到的顺序；那三段键就是成员
        // 身份，无并列，故本次冻结出的致密序确定、不随查询计划变）。
        final List<MediaCollectionItemRow> all =
            await getCollectionItems(collectionId);
        final List<CollectionMemberKey> merged = mergeCollectionOrder(
          all: <CollectionMemberKey>[
            for (final MediaCollectionItemRow r in all)
              (mediaType: r.mediaType, entryKey: r.entryKey),
          ],
          subset: ordered,
          keyOf: (CollectionMemberKey k) => k,
        );
        for (int i = 0; i < merged.length; i++) {
          await (update(mediaCollectionItems)
                ..where((t) =>
                    t.collectionId.equals(collectionId) &
                    t.mediaType.equals(merged[i].mediaType) &
                    t.entryKey.equals(merged[i].entryKey)))
              .write(MediaCollectionItemsCompanion(sortIndex: Value(i)));
        }
        if (bumpOrderUpdatedAt) {
          await (update(mediaCollections)
                ..where((t) => t.id.equals(collectionId)))
              .write(MediaCollectionsCompanion(
            orderUpdatedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ));
        }
      });

  /// 删条目时清其全部合集引用（逻辑外键无 DB cascade，删书路径主动调用）；被清空的
  /// 合集随之删除。
  Future<void> removeEntryFromAllCollections(
          MediaKind mediaType, String entryKey) =>
      transaction(() async {
        final List<MediaCollectionItemRow> affected =
            await (select(mediaCollectionItems)
                  ..where((t) =>
                      t.mediaType.equals(mediaType.dbValue) &
                      t.entryKey.equals(entryKey)))
                .get();
        if (affected.isEmpty) return;
        final Set<int> ids =
            affected.map((MediaCollectionItemRow e) => e.collectionId).toSet();
        await (delete(mediaCollectionItems)
              ..where((t) =>
                  t.mediaType.equals(mediaType.dbValue) &
                  t.entryKey.equals(entryKey)))
            .go();
        for (final int cid in ids) {
          final List<MediaCollectionItemRow> rem =
              await (select(mediaCollectionItems)
                    ..where((t) => t.collectionId.equals(cid)))
                  .get();
          if (rem.isEmpty) {
            await deleteTagAssignmentsForHost(
                TagHostKind.collection, collectionTagEntryKey(cid));
            await (delete(mediaCollections)..where((t) => t.id.equals(cid)))
                .go();
          }
        }
      });

  // ── collection tombstones (成员移出/合集删除墓碑, schema v40) ─────
  // 多端库联合视图 §2.3：合集跨端并集同步的防复活地基。表结构见
  // [CollectionMemberTombstones]（自然键 + 空哨兵行 = 合集级墓碑）。

  /// 全部墓碑行（成员移出 + 合集级哨兵），同步引擎构建本地清单用。
  Future<List<CollectionMemberTombstoneRow>>
      getAllCollectionMemberTombstones() =>
          select(collectionMemberTombstones).get();

  /// 按自然键取合集行（同步应用端把清单自然键解析回本地自增 id）。表无 (name,
  /// collectionType) 唯一约束（历史 schema），万一重名取 id 最小行，与
  /// [getPrimaryCollectionIdByEntry] 的折叠方向一致。
  Future<MediaCollectionRow?> getMediaCollectionByNaturalKey(
          String name, String collectionType) =>
      (select(mediaCollections)
            ..where((t) =>
                t.name.equals(name) & t.collectionType.equals(collectionType))
            ..orderBy([(t) => OrderingTerm(expression: t.id)])
            ..limit(1))
          .getSingleOrNull();

  /// upsert 一条墓碑（重复移出刷新 deletedAt，单行 LWW）。
  Future<void> upsertCollectionMemberTombstone({
    required String collectionName,
    required String collectionType,
    required String mediaType,
    required String entryKey,
    required int deletedAt,
  }) =>
      into(collectionMemberTombstones).insertOnConflictUpdate(
        CollectionMemberTombstonesCompanion.insert(
          collectionName: collectionName,
          collectionType: collectionType,
          mediaType: mediaType,
          entryKey: entryKey,
          deletedAt: deletedAt,
        ),
      );

  /// 删一条成员墓碑（重新加入清墓碑；不存在 no-op）。
  Future<void> deleteCollectionMemberTombstone({
    required String collectionName,
    required String collectionType,
    required String mediaType,
    required String entryKey,
  }) =>
      (delete(collectionMemberTombstones)
            ..where((t) =>
                t.collectionName.equals(collectionName) &
                t.collectionType.equals(collectionType) &
                t.mediaType.equals(mediaType) &
                t.entryKey.equals(entryKey)))
          .go();

  /// 同步应用端专用：把某合集自然键下的全部墓碑行整体替换成 [rows]（本地墓碑
  /// 镜像合并后清单；是否含合集级哨兵行由 rows 决定）。事务内先删后插，幂等。
  Future<void> replaceCollectionTombstonesFor(
    String collectionName,
    String collectionType,
    List<CollectionMemberTombstonesCompanion> rows,
  ) =>
      transaction(() async {
        await (delete(collectionMemberTombstones)
              ..where((t) =>
                  t.collectionName.equals(collectionName) &
                  t.collectionType.equals(collectionType)))
            .go();
        for (final CollectionMemberTombstonesCompanion row in rows) {
          await into(collectionMemberTombstones).insert(row);
        }
      });

  /// 同步应用端专用：orderUpdatedAt 镜像成清单里的值（不是 now——同步应用不是
  /// 人为改序，写 now 会让两端时间戳互相追赶、掩盖真正的手动序 LWW）。
  Future<void> setCollectionOrderUpdatedAt(int id, int orderUpdatedAtMs) =>
      (update(mediaCollections)..where((t) => t.id.equals(id))).write(
          MediaCollectionsCompanion(orderUpdatedAt: Value(orderUpdatedAtMs)));

  /// 同步应用端专用：按显式 sortIndex upsert 一条成员行（不走尾插、不清墓碑——
  /// 墓碑状态由清单镜像 [replaceCollectionTombstonesFor] 统一处理）。
  Future<void> upsertCollectionItemAt(
          int collectionId, String mediaType, String entryKey, int sortIndex) =>
      into(mediaCollectionItems).insertOnConflictUpdate(
        MediaCollectionItemsCompanion.insert(
          collectionId: collectionId,
          mediaType: mediaType,
          entryKey: entryKey,
          sortIndex: Value(sortIndex),
        ),
      );

  /// 同步应用端专用：删一条成员行（不写墓碑、不触发移空自删——空壳收尾由同步
  /// 应用端按合并后清单统一决定）。
  Future<void> deleteCollectionItemRaw(
          int collectionId, String mediaType, String entryKey) =>
      (delete(mediaCollectionItems)
            ..where((t) =>
                t.collectionId.equals(collectionId) &
                t.mediaType.equals(mediaType) &
                t.entryKey.equals(entryKey)))
          .go();

  /// 同步应用端专用：原样删除合集行 + 其全部成员引用行，**不写任何墓碑**——
  /// 墓碑状态由同步应用端按合并后清单镜像（对比用户路径
  /// [deleteMediaCollection] 会写 now 时间戳的合集级墓碑）。
  Future<void> deleteMediaCollectionRaw(int id) => transaction(() async {
        await (delete(mediaCollectionItems)
              ..where((t) => t.collectionId.equals(id)))
            .go();
        await deleteTagAssignmentsForHost(
            TagHostKind.collection, collectionTagEntryKey(id));
        await (delete(mediaCollections)..where((t) => t.id.equals(id))).go();
      });

  // ── audio cues ──────────────────────────────────────────────────
  // [bookKey] is the owner key: either an audiobook bookKey OR an srt_books.uid
  // (SRT books still key their cues on their own uid string).
  Future<List<AudioCueRow>> getCuesForChapter(
          String bookKey, String chapterHref) =>
      (select(audioCues)
            ..where((t) =>
                t.bookKey.equals(bookKey) & t.chapterHref.equals(chapterHref))
            ..orderBy([(t) => OrderingTerm.asc(t.sentenceIndex)]))
          .get();

  Future<List<AudioCueRow>> getCuesForBook(String bookKey) => (select(audioCues)
        ..where((t) => t.bookKey.equals(bookKey))
        ..orderBy([
          (t) => OrderingTerm.asc(t.audioFileIndex),
          (t) => OrderingTerm.asc(t.startMs),
          (t) => OrderingTerm.asc(t.sentenceIndex),
        ]))
      .get();

  Future<AudioCueRow?> findCue(
          String bookKey, String chapterHref, int sentenceIndex) =>
      (select(audioCues)
            ..where((t) =>
                t.bookKey.equals(bookKey) &
                t.chapterHref.equals(chapterHref) &
                t.sentenceIndex.equals(sentenceIndex)))
          .getSingleOrNull();

  Future<void> replaceCuesForBook(
          String bookKey, List<AudioCuesCompanion> cues) =>
      transaction(() async {
        await (delete(audioCues)..where((t) => t.bookKey.equals(bookKey))).go();
        await batch((b) {
          for (final c in cues) {
            b.insert(audioCues, c);
          }
        });
      });

  // ── srt books ───────────────────────────────────────────────────
  Future<List<SrtBookRow>> getAllSrtBooks() =>
      (select(srtBooks)..orderBy([(t) => OrderingTerm.desc(t.importedAt)]))
          .get();

  /// 监听有声书（SrtBooks）uid 集合，供书架有声书列表在任意导入路径落库后自动
  /// 刷新（同 [watchVideoBookUids]，把书籍从「每个导入点各自记得 invalidate」的
  /// 脆弱模式解放出来，BUG-793）。消费方按集合 `.distinct` 去重，纯列更新不触发。
  Stream<List<String>> watchSrtBookUids() =>
      select(srtBooks).map((SrtBookRow row) => row.uid).watch();

  Future<SrtBookRow?> getSrtBookByUid(String uid) =>
      (select(srtBooks)..where((t) => t.uid.equals(uid))).getSingleOrNull();

  Future<SrtBookRow?> getSrtBookByBookKey(String bookKey) =>
      (select(srtBooks)..where((t) => t.bookKey.equals(bookKey)))
          .getSingleOrNull();

  Future<void> upsertSrtBook(SrtBooksCompanion book) =>
      into(srtBooks).insertOnConflictUpdate(book);

  /// Deletes the SRT book row + its cues. Returns the number of srt_books rows
  /// actually removed (0 when [uid] matched no row) so batch deletion can count
  /// only genuine deletions instead of optimistically assuming success
  /// (BUG-439).
  Future<int> deleteSrtBookByUid(String uid) => transaction(() async {
        await (delete(audioCues)..where((t) => t.bookKey.equals(uid))).go();
        // TODO-616：同事务清 shelf_entry（mediaType='srt'、entryKey=uid）。
        await deleteShelfEntry(MediaKind.srt, uid);
        // v83 顺手修的历史缺口：srt 删除此前不清合集成员行（与 epub 同修，
        // 见 deleteEpubBook）。
        await removeEntryFromAllCollections(MediaKind.srt, uid);
        await deleteTagAssignmentsForHost(TagHostKind.srt, uid);
        return (delete(srtBooks)..where((t) => t.uid.equals(uid))).go();
      });

  // ── reader positions ────────────────────────────────────────────
  // v82 起键 = 书稳定 uid（epub 书 = epub_books.uid；非 epub 域沿用其既有
  // 稳定键）。调用方持 bookKey 时先经 resolveEpubBookUid 换算。
  Future<ReaderPositionRow?> getReaderPosition(String bookUid) =>
      (select(readerPositions)..where((t) => t.bookUid.equals(bookUid)))
          .getSingleOrNull();

  /// BUG-777: bulk read for the shelf's "last read at" map (bookUid ->
  /// updatedAt). One query instead of N per-book lookups.
  Future<List<ReaderPositionRow>> getAllReaderPositions() =>
      select(readerPositions).get();

  Future<void> upsertReaderPosition(ReaderPositionsCompanion pos) =>
      into(readerPositions).insert(
        pos,
        onConflict: DoUpdate(
          (old) => pos,
          target: [readerPositions.bookUid],
        ),
      );

  Future<int> deleteReaderPosition(String bookUid) =>
      (delete(readerPositions)..where((t) => t.bookUid.equals(bookUid))).go();
}

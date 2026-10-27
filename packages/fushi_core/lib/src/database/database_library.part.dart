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

  /// 还指向来源 [sourceId] 的下载订阅数与未整理完的下载任务数（BUG-2755）。
  ///
  /// 删来源前据此决定要不要让用户选迁移目标：FK setNull 会把这些行的
  /// `target_source_id` 静默清空，订阅从此每轮报「目标来源不可用」、在途任务
  /// 整理时报「受管来源不存在」。「未整理完」= 未完成且仍在
  /// [kVideoDownloadSourceRebindableStages]（文件还没落进来源目录）。
  Future<({int subscriptions, int pendingJobs})>
      countVideoDownloadReferencesToSource(int sourceId) async {
    final Expression<int> subscriptionCount =
        videoDownloadSubscriptions.subscriptionId.count();
    final TypedResult subscriptionRow =
        await (selectOnly(videoDownloadSubscriptions)
              ..addColumns(<Expression<Object>>[subscriptionCount])
              ..where(
                  videoDownloadSubscriptions.targetSourceId.equals(sourceId)))
            .getSingle();
    final Expression<int> jobCount = videoDownloadJobs.jobId.count();
    final TypedResult jobRow = await (selectOnly(videoDownloadJobs)
          ..addColumns(<Expression<Object>>[jobCount])
          ..where(_pendingVideoDownloadJobsOfSource(sourceId)))
        .getSingle();
    return (
      subscriptions: subscriptionRow.read(subscriptionCount) ?? 0,
      pendingJobs: jobRow.read(jobCount) ?? 0,
    );
  }

  /// 被下载管线管理的合集 id（任一下载任务或下载订阅指向它）。这类合集的集序
  /// 不是用户写出来的，而是「按集号」派生的（合集同步平手时据此重算，BUG-2941）。
  Future<Set<int>> downloadManagedCollectionIds() async {
    final List<int?> fromJobs =
        await (selectOnly(videoDownloadJobs, distinct: true)
              ..addColumns(<Expression<Object>>[videoDownloadJobs.collectionId])
              ..where(videoDownloadJobs.collectionId.isNotNull()))
            .map((TypedResult r) => r.read(videoDownloadJobs.collectionId))
            .get();
    final List<int?> fromSubscriptions =
        await (selectOnly(videoDownloadSubscriptions, distinct: true)
              ..addColumns(<Expression<Object>>[
                videoDownloadSubscriptions.collectionId
              ])
              ..where(videoDownloadSubscriptions.collectionId.isNotNull()))
            .map((TypedResult r) =>
                r.read(videoDownloadSubscriptions.collectionId))
            .get();
    return <int>{
      for (final int? id in <int?>[...fromJobs, ...fromSubscriptions])
        if (id != null) id,
    };
  }

  Expression<bool> _pendingVideoDownloadJobsOfSource(int sourceId) =>
      videoDownloadJobs.targetSourceId.equals(sourceId) &
      videoDownloadJobs.lifecycle
          .equals(VideoDownloadJobLifecycle.completed)
          .not() &
      videoDownloadJobs.stage.isIn(kVideoDownloadSourceRebindableStages);

  /// 删除来源：依赖 FK onDelete:setNull，归属本来源的 video_books / epub_books
  /// 自动把 source_id 归 NULL（条目保留，不连坐删）。返回删除行数。
  ///
  /// BUG-2755：视频下载的订阅与未整理完的任务也经 FK 指向来源。
  /// - [migrateVideoDownloadsTo] 非 null：同一事务里把订阅与未整理完任务改写到
  ///   该来源（必须是另一个视频来源，否则抛 [ArgumentError]，什么都不删）；
  /// - 否则 [disableVideoDownloadSubscriptions] 为 true 时停用这些订阅（FK 随后把
  ///   目标清空），免得它们每轮检查都报「目标来源不可用」。
  Future<int> deleteMediaSource(
    int id, {
    int? migrateVideoDownloadsTo,
    bool disableVideoDownloadSubscriptions = false,
  }) =>
      transaction(() async {
        final MediaSourceRow? source = await getMediaSourceById(id);
        final int nowAt = DateTime.now().millisecondsSinceEpoch;
        if (migrateVideoDownloadsTo != null) {
          final MediaSourceRow? target =
              await getMediaSourceById(migrateVideoDownloadsTo);
          if (migrateVideoDownloadsTo == id ||
              target == null ||
              target.mediaKind != 'video') {
            throw ArgumentError.value(
              migrateVideoDownloadsTo,
              'migrateVideoDownloadsTo',
              'must be another video source',
            );
          }
          await (update(videoDownloadSubscriptions)
                ..where((t) => t.targetSourceId.equals(id)))
              .write(VideoDownloadSubscriptionsCompanion(
            targetSourceId: Value<int?>(migrateVideoDownloadsTo),
            updatedAt: Value<int>(nowAt),
          ));
          await (update(videoDownloadJobs)
                ..where((_) => _pendingVideoDownloadJobsOfSource(id)))
              .write(VideoDownloadJobsCompanion(
            targetSourceId: Value<int?>(migrateVideoDownloadsTo),
            updatedAt: Value<int>(nowAt),
          ));
        } else if (disableVideoDownloadSubscriptions) {
          await (update(videoDownloadSubscriptions)
                ..where((t) => t.targetSourceId.equals(id) & t.enabled))
              .write(VideoDownloadSubscriptionsCompanion(
            enabled: const Value<bool>(false),
            updatedAt: Value<int>(nowAt),
          ));
        }
        if (source != null && source.mediaKind == 'video') {
          // 来源设置可能刚改过还没重扫；FK 清空 sourceId 前保留最终组织选择。
          await (update(videoBooks)..where((t) => t.sourceId.equals(id))).write(
            VideoBooksCompanion(
              videoGroupingMode: Value(source.videoGroupingMode),
            ),
          );
        }
        return (delete(mediaSources)..where((t) => t.id.equals(id))).go();
      });

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

  /// 整列改写来源的 configJson（目前只用于 iOS 书签过期后回写新书签，见
  /// `SourceFolderAccess`）。调用方负责经 `encodeSourceConfig` 白名单编码。
  Future<void> updateMediaSourceConfigJson(int id, String? configJson) =>
      (update(mediaSources)..where((t) => t.id.equals(id)))
          .write(MediaSourcesCompanion(configJson: Value(configJson)));

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

  /// [mediaKind] 为 null 时不分片（全量）；传 `'manga'` / `'anime'` 只取该生态
  /// 的仓库（v107，两个生态共用三张表按 media_kind 列分片）。
  Future<List<MangaExtensionStoreRow>> getMangaExtensionStores({
    String? mediaKind,
  }) =>
      (select(mangaExtensionStores)
            ..where((t) => mediaKind == null
                ? const Constant(true)
                : t.mediaKind.equals(mediaKind))
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

  Future<List<MangaExtensionRow>> getMangaExtensions({String? mediaKind}) =>
      (select(mangaExtensions)
            ..where((t) => mediaKind == null
                ? const Constant(true)
                : t.mediaKind.equals(mediaKind))
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

  Future<List<MangaOnlineSourceRow>> getMangaOnlineSources({
    String? mediaKind,
  }) =>
      (select(mangaOnlineSources)
            ..where((t) => mediaKind == null
                ? const Constant(true)
                : t.mediaKind.equals(mediaKind))
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
  /// 靠「每个写入路径各自记得通知页面」必然漏——BUG-1699 实证：互联合集同步落库
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

  /// 「加入合集」候选：只列与条目 ([kind], [entryKey]) **同一库页域**的合集
  /// （[CollectionShelfDomain]：书架 / 漫画库 / 视频库 / 游戏库），排序同
  /// [getAllMediaCollections]。
  ///
  /// BUG-2974：合集表不带种类列，「加入合集」弹窗此前直接取全部合集，书的列表里
  /// 混着视频的合集。合集的域由成员推导（任一成员在本域即算本域合集）；epub 成员按
  /// `epub_books.format` 再分书 / 漫画（成员键是 uid，旧行可能仍是 bookKey，两种
  /// 都认）。空合集（无成员、无从归属）不列出。
  Future<List<MediaCollectionRow>> getMediaCollectionsForEntryDomain(
    MediaKind kind,
    String entryKey,
  ) async {
    final bool isManga = (await _mangaEntryKeys()).contains(entryKey);
    return getMediaCollectionsInDomain(
      collectionShelfDomainOf(kind, isManga: isManga),
    );
  }

  /// 属于库页域 [target] 的全部合集（任一成员落在该域即算），排序同
  /// [getAllMediaCollections]；空合集不列出。「加入合集」候选与「管理合集」页共用。
  Future<List<MediaCollectionRow>> getMediaCollectionsInDomain(
    CollectionShelfDomain target,
  ) async {
    final Set<String> mangaKeys = await _mangaEntryKeys();
    CollectionShelfDomain domainOf(MediaKind k, String key) =>
        collectionShelfDomainOf(k, isManga: mangaKeys.contains(key));
    final Set<int> inDomain = <int>{};
    for (final MediaCollectionItemRow item in await getAllCollectionItems()) {
      final MediaKind? memberKind = MediaKind.tryParse(item.mediaType);
      if (memberKind == null) continue;
      if (domainOf(memberKind, item.entryKey) == target) {
        inDomain.add(item.collectionId);
      }
    }
    return <MediaCollectionRow>[
      for (final MediaCollectionRow c in await getAllMediaCollections())
        if (inDomain.contains(c.id)) c,
    ];
  }

  /// 漫画格式 epub 行的成员键（uid 与旧 bookKey 都收），供按域分书 / 漫画。
  Future<Set<String>> _mangaEntryKeys() async {
    final Set<String> mangaKeys = <String>{};
    for (final EpubBookRow row in await (select(epubBooks)
          ..where((t) => t.format.equals(BookFormat.manga.dbValue)))
        .get()) {
      if (row.uid.isNotEmpty) mangaKeys.add(row.uid);
      mangaKeys.add(row.bookKey);
    }
    return mangaKeys;
  }


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

  /// 更新系列（合集）级默认字幕语言代码（`ja` / `en` …，schema v91）。
  /// [language] 为 null 时清除（加载回退视频内容语言链 `resolveContentLanguage`，
  /// 绝不是 ja）。
  Future<void> updateMediaCollectionSubtitleLanguage(
          int id, String? language) =>
      (update(mediaCollections)..where((t) => t.id.equals(id))).write(
        MediaCollectionsCompanion(subtitleLanguage: Value<String?>(language)),
      );

  /// 更新系列（合集）级偏好的字幕版本组键（`subtitle_version_groups.dart` 的
  /// 分组键，schema v89）。[releaseGroup] 为 null 时清除（加载走默认选轨）。
  Future<void> updateMediaCollectionSubtitleReleaseGroup(
          int id, String? releaseGroup) =>
      (update(mediaCollections)..where((t) => t.id.equals(id))).write(
        MediaCollectionsCompanion(
            subtitleReleaseGroup: Value<String?>(releaseGroup)),
      );

  /// 新建合集，返回自增 id。sortOrder 默认排末尾（现有最大 +1，空表 0）。同事务清
  /// 同自然键的合集级删除墓碑（重建 = 撤销删除，仿插书清书墓碑 [insertEpubBook]
  /// 一律；不清成员墓碑——成员重加走 [addToCollection] 逐键清）。
  ///
  /// [origin] / [organizeKey]：整理器（规则归组、AI 整理）建合集时标明来源与分组键
  /// （schema v124）；复用已有同名合集时**不**改它们（已有合集的来源归它自己）。
  Future<int> createMediaCollection(String name,
          {String collectionType = 'collection',
          CollectionOrigin origin = CollectionOrigin.user,
          String? organizeKey}) =>
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
          origin: Value(origin.dbValue),
          organizeKey: Value(organizeKey),
        ));
      });

  /// 用户接手整理器管着的合集（schema v124，spec §5.1）：`ai` / `rule` → `user`，
  /// 永不回退。用户写入口（加减成员、改名、手动排序、合并）都经这里；整理器、同步、
  /// 扫描等自动路径传 `userIntent: false` 绕开。已是 `user` / `folder` 的不动。
  Future<void> _claimCollectionForUser(int id) => customUpdate(
        'UPDATE media_collections SET origin = ? '
        "WHERE id = ? AND origin IN ('ai', 'rule')",
        variables: <Variable<Object>>[
          Variable<String>(CollectionOrigin.user.dbValue),
          Variable<int>(id),
        ],
        updates: {mediaCollections},
      );

  /// 写整理身份（同步应用端 / 整理器专用）：来源、分组键、别名原样落库。
  Future<void> setMediaCollectionOrganizeState(
    int id, {
    required CollectionOrigin origin,
    required String? organizeKey,
    required Set<String> organizeAliases,
  }) =>
      (update(mediaCollections)..where((t) => t.id.equals(id))).write(
        MediaCollectionsCompanion(
          origin: Value(origin.dbValue),
          organizeKey: Value(organizeKey),
          organizeAliases: Value(encodeOrganizeAliases(organizeAliases)),
        ),
      );

  /// 合并时让目标合集吸收 [source] 的分组身份（spec §8.3）：源的键与别名并进目标
  /// 别名；目标还没有键时取两者里的规范键。必须在删源合集**之前**调——删除墓碑上
  /// 的键落在某个活合集的别名里，才不会被读成「用户拒绝」。
  Future<void> absorbOrganizeIdentity({
    required int targetId,
    required MediaCollectionRow source,
  }) =>
      transaction(() async {
        final MediaCollectionRow? target = await getMediaCollectionById(
          targetId,
        );
        if (target == null) return;
        final Set<String> sourceAliases =
            decodeOrganizeAliases(source.organizeAliases);
        if (source.organizeKey == null && sourceAliases.isEmpty) return;
        final ({String? key, Set<String> aliases}) merged =
            mergeOrganizeIdentity(
          keyA: target.organizeKey,
          aliasesA: decodeOrganizeAliases(target.organizeAliases),
          keyB: source.organizeKey,
          aliasesB: sourceAliases,
        );
        // 目标已有自己的键时保持它为主键（展示与刮削都跟着它），源键只进别名。
        final String? key = target.organizeKey ?? merged.key;
        await (update(mediaCollections)..where((t) => t.id.equals(targetId)))
            .write(MediaCollectionsCompanion(
          organizeKey: Value(key),
          organizeAliases: Value(encodeOrganizeAliases(
            <String>{...merged.aliases, if (merged.key != null) merged.key!}
              ..remove(key),
          )),
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
  Future<void> renameMediaCollection(int id, String name,
          {bool userIntent = true}) =>
      transaction(() async {
        if (userIntent) await _claimCollectionForUser(id);
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

  /// 私密合集（v122 `media_privacy_flags`）的成员离开它之前，把私密落到成员自己
  /// 身上（fail-closed）。成员的私密原本只是「在私密合集里」继承来的：合集被删 /
  /// 合并解散 / 按季或按 AniDB 作品拆走 / 成员被移出时，继承随成员关系一起消失，
  /// 那部作品就会在下一轮排行榜上传、Bangumi 推送里静默变回公开——其中 AniDB 拆分
  /// 是刮削后台自动做的，用户根本没表达过「公开」。取消私密只认用户在作品自己的私密
  /// 开关上拨回去。合集本身不私密时什么都不做；成员已私密的不重写（不推进时钟）。
  Future<void> _carryCollectionPrivacyToMembers(
    int collectionId,
    Iterable<({String mediaType, String entryKey})> leaving,
  ) async {
    if (!await isMediaPrivate(
      TagHostKind.collection,
      collectionTagEntryKey(collectionId),
    )) {
      return;
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final (:String mediaType, :String entryKey) in leaving) {
      final MediaKind? kind = MediaKind.tryParse(mediaType);
      // 对端未知种类：本机没有对应宿主、也没有出站路径，无从落标记。
      if (kind == null) continue;
      // EPUB 成员键 v83 起是 uid，私密标记键是 bookKey；反查不上 = 透传行（原值
      // 本就是 bookKey），照抄。
      final String hostKey = kind == MediaKind.epub
          ? (await resolveEpubBookKeyByUid(entryKey) ?? entryKey)
          : entryKey;
      final TagHostKind host = tagHostKindOfMediaKind(kind);
      if (await isMediaPrivate(host, hostKey)) continue;
      await setMediaPrivate(host, hostKey, true, at: now);
    }
  }

  /// 删合集：显式先删本合集全部成员引用行、再删合集（不依赖 FK cascade，测试/生产
  /// 一致；绝不删条目本身）。返回删除的合集行数。同事务写合集级删除墓碑（空哨兵行，
  /// schema v40 防对端并集同步复活），并清本合集残留成员墓碑（合集已删，成员墓碑
  /// 无意义；留着会误杀日后重建同名合集时对端的成员）。
  ///
  /// [deletedAt]（缺省 now）：合集级墓碑时刻。整理收敛在同步基线推进后删败方时传
  /// 「严格晚于基线」的值——同毫秒的墓碑会被下一轮判成旧闻（v124）。
  ///
  /// [organizeMerged]：整理器把它并进别的合集时传 true（删除哨兵记下「并掉」，不算
  /// 用户拒绝这个分组）。
  ///
  /// [userIntent]（默认 true）：用户删的整理器合集，删除哨兵记下它的分组键集合（主键 +
  /// 吸收过的别名）= 用户拒绝了这个分组，任何设备上的 AI 都不再建。自动路径（刮削拆分、
  /// 导入清理…）删合集不是用户表态，传 false 只写普通删除墓碑、不记键。
  Future<int> deleteMediaCollection(int id,
          {int? deletedAt,
          bool organizeMerged = false,
          bool userIntent = true}) =>
      transaction(() async {
        final MediaCollectionRow? col = await getMediaCollectionById(id);
        await _carryCollectionPrivacyToMembers(
          id,
          <({String mediaType, String entryKey})>[
            for (final MediaCollectionItemRow m in await getCollectionItems(id))
              (mediaType: m.mediaType, entryKey: m.entryKey),
          ],
        );
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
            deletedAt: deletedAt ?? DateTime.now().millisecondsSinceEpoch,
            // v124：带上分组键——键若已被别的活合集吸收（合并）就只是去向记录，
            // 否则就是用户拒绝了这个分组（spec §5.2）。
            organizeKey: organizeMerged || userIntent
                ? _deadOrganizeKeySet(col)
                : null,
            organizeMerged: organizeMerged,
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

  /// 首页 dashboard 专用：**只为本机库里还存在的条目**（视频 / EPUB / SRT 书 /
  /// 游戏）一次查出折叠归属主合集（与 [getPrimaryCollectionIdByEntry] 同口径的
  /// MIN(collection_id)）及其在该主合集里的组内 sortIndex。
  ///
  /// 为什么不直接 [getPrimaryCollectionIdByEntry] + [getAllCollectionItems]：两者
  /// 都是全表物化。成员表可以远大于本机库——在线源 / 播放列表合集会把成百上千个
  /// 本机并不存在的集数挂进成员表（实测开发库 3160 个合集、84,735 行成员，本机
  /// 视频只有 216 个），首页为了几十张卡把八万多行跨 isolate 搬进 Dart 再建两张
  /// Map，单这两步就是 640–950 ms，正是首屏「内容出来得慢」的大头。这里先在
  /// SQL 侧按本机条目收窄，再按主键 (collection_id, media_type, entry_key) 回查
  /// sortIndex，结果行数 = 本机已入合集的条目数。
  ///
  /// EPUB 成员键 v83 起是 `epub_books.uid`，旧行可能仍是 bookKey，两种都收。
  /// 键形同 [getPrimaryCollectionIdByEntry]：`'<mediaType>|<entryKey>'`。
  Future<Map<String, ({int collectionId, int sortIndex})>>
      getLocalPrimaryCollectionMembership() async {
    final List<QueryRow> rows = await customSelect(
      'SELECT i.media_type, i.entry_key, i.collection_id, i.sort_index '
      'FROM ('
      '  SELECT media_type, entry_key, MIN(collection_id) AS cid '
      '  FROM media_collection_items '
      "  WHERE (media_type = 'video' "
      '         AND entry_key IN (SELECT book_uid FROM video_books)) '
      "     OR (media_type = 'epub' "
      '         AND (entry_key IN (SELECT uid FROM epub_books) '
      '              OR entry_key IN (SELECT book_key FROM epub_books))) '
      "     OR (media_type = 'srt' "
      '         AND entry_key IN (SELECT uid FROM srt_books)) '
      "     OR (media_type = 'game' "
      '         AND entry_key IN (SELECT CAST(id AS TEXT) FROM galgames)) '
      '  GROUP BY media_type, entry_key'
      ') p '
      'JOIN media_collection_items i '
      '  ON i.collection_id = p.cid '
      ' AND i.media_type = p.media_type '
      ' AND i.entry_key = p.entry_key',
      readsFrom: {
        mediaCollectionItems,
        videoBooks,
        epubBooks,
        srtBooks,
        galgames,
      },
    ).get();
    return <String, ({int collectionId, int sortIndex})>{
      for (final QueryRow r in rows)
        '${r.read<String>('media_type')}|${r.read<String>('entry_key')}': (
          collectionId: r.read<int>('collection_id'),
          sortIndex: r.read<int>('sort_index'),
        ),
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

  /// 持久化合集专用书键映射。首次有效绑定是 canonical，不抢占其它存量书。
  Future<void> setCollectionBookAlias(String localUid, String remoteKey) =>
      transaction(() async {
        if (localUid.isEmpty || remoteKey.isEmpty) return;
        final EpubBookRow? book = await (select(epubBooks)
              ..where((t) => t.uid.equals(localUid)))
            .getSingleOrNull();
        if (book == null) return;
        await customUpdate(
          'DELETE FROM collection_book_aliases WHERE NOT EXISTS '
          '(SELECT 1 FROM epub_books WHERE epub_books.uid = collection_book_aliases.local_uid)',
          updates: {collectionBookAliases},
        );
        await into(collectionBookAliases).insert(
          CollectionBookAliasesCompanion.insert(localUid: localUid, remoteKey: remoteKey),
          mode: InsertMode.insertOrIgnore,
        );
      });

  /// 只返回父书仍存在的 remoteKey → 本地 UID 映射。
  Future<Map<String, String>> getCollectionBookAliases() async {
    final List<QueryRow> rows = await customSelect(
      'SELECT a.remote_key, a.local_uid FROM collection_book_aliases a '
      'INNER JOIN epub_books b ON b.uid = a.local_uid',
      readsFrom: {collectionBookAliases, epubBooks},
    ).get();
    return <String, String>{
      for (final QueryRow row in rows)
        row.read<String>('remote_key'): row.read<String>('local_uid'),
    };
  }

  /// 「从所有设备删除」这本书时墓碑该写的键：从对端下载、本机落地键与对端不同的
  /// 书（[CollectionBookAliases] 记着对端键，见 RemoteCollectionAdoptionService）写
  /// **对端键**，否则推给 host 认不出、对端消费也对不上（BUG-3443 同类）；其余照旧
  /// 本机 bookKey。必须在删书行**之前**调（[deleteEpubBook] 会级联删掉别名）。
  Future<String> syncDeletionBookKeyOf(String bookKey) async {
    final QueryRow? row = await customSelect(
      'SELECT a.remote_key FROM collection_book_aliases a '
      'INNER JOIN epub_books b ON b.uid = a.local_uid '
      'WHERE b.book_key = ? LIMIT 1',
      variables: [Variable<String>(bookKey)],
      readsFrom: {collectionBookAliases, epubBooks},
    ).getSingleOrNull();
    final String? remoteKey = row?.read<String>('remote_key');
    return remoteKey == null || remoteKey.isEmpty ? bookKey : remoteKey;
  }

  /// 对端书键 → 本机 bookKey（只含父书仍在的别名），供删除墓碑消费端把对端键
  /// 墓碑换算到本机行上。
  Future<Map<String, String>> getPeerToLocalBookKeys() async {
    final List<QueryRow> rows = await customSelect(
      'SELECT a.remote_key, b.book_key FROM collection_book_aliases a '
      'INNER JOIN epub_books b ON b.uid = a.local_uid',
      readsFrom: {collectionBookAliases, epubBooks},
    ).get();
    return <String, String>{
      for (final QueryRow row in rows)
        row.read<String>('remote_key'): row.read<String>('book_key'),
    };
  }

  /// 收养 DTO 携带的主合集成员；远端刷新没有撤销删除或覆盖手动排序的权限。
  /// 返回自然键对应的最小合集 ID；任一身份被墓碑阻止时返回 null。
  /// 占位提升和去重在同一事务完成，不产生用户删除墓碑。
  Future<int?> adoptRemoteCollectionMember({
    required String name,
    required String collectionType,
    required MediaKind mediaType,
    required String remoteEntryKey,
    required int sortIndex,
    String? localEntryKey,
  }) => transaction(() async {
    if (await hasCollectionDeletionTombstone(name, collectionType)) {
      return null;
    }
    final Set<String> keys = <String>{remoteEntryKey};
    if (localEntryKey != null) {
      keys.add(localEntryKey);
      keys.add(await _tombstoneEntryKeyOf(mediaType.dbValue, localEntryKey));
      // Older EPUB removals used the actual local bookKey before a remote
      // alias was known. Keep respecting that domain as well.
      if (mediaType == MediaKind.epub) {
        final EpubBookRow? book = await (select(
          epubBooks,
        )..where((t) => t.uid.equals(localEntryKey))).getSingleOrNull();
        if (book != null) keys.add(book.bookKey);
      }
    }
    final CollectionMemberTombstoneRow? removed =
        await (select(collectionMemberTombstones)
              ..where(
                (t) =>
                    t.collectionName.equals(name) &
                    t.collectionType.equals(collectionType) &
                    t.mediaType.equals(mediaType.dbValue) &
                    t.entryKey.isIn(keys),
              )
              ..limit(1))
            .getSingleOrNull();
    if (removed != null) return null;

    final MediaCollectionRow? existing = await getMediaCollectionByNaturalKey(
      name,
      collectionType,
    );
    final int collectionId =
        existing?.id ??
        await into(mediaCollections).insert(
          MediaCollectionsCompanion.insert(
            name: name,
            collectionType: Value(collectionType),
            sortOrder: Value(await _nextMediaCollectionSortOrder()),
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
    final String targetKey = localEntryKey ?? remoteEntryKey;
    final List<MediaCollectionItemRow> members =
        await (select(mediaCollectionItems)..where(
              (t) =>
                  t.collectionId.equals(collectionId) &
                  t.mediaType.equals(mediaType.dbValue) &
                  t.entryKey.isIn(<String>{remoteEntryKey, targetKey}),
            ))
            .get();
    MediaCollectionItemRow? placeholder;
    bool targetExists = false;
    for (final MediaCollectionItemRow member in members) {
      if (member.entryKey == remoteEntryKey) placeholder = member;
      if (member.entryKey == targetKey) targetExists = true;
    }
    if (!targetExists) {
      final int index =
          placeholder?.sortIndex ??
          ((existing?.orderUpdatedAt ?? 0) == 0
              ? sortIndex
              : await _nextCollectionSortIndex(collectionId));
      await into(mediaCollectionItems).insert(
        MediaCollectionItemsCompanion.insert(
          collectionId: collectionId,
          mediaType: mediaType.dbValue,
          entryKey: targetKey,
          sortIndex: Value(index),
        ),
        mode: InsertMode.insertOrIgnore,
      );
    }
    if (targetKey != remoteEntryKey && placeholder != null) {
      await deleteCollectionItemRaw(
        collectionId,
        mediaType.dbValue,
        remoteEntryKey,
      );
    }
    return collectionId;
  });

  /// 加条目进合集（尾插；重复成员 INSERT OR IGNORE 幂等）。同事务清同键成员墓碑
  /// （schema v40：重新加入 = 撤销移出——否则跨端同步的成员墓碑会把刚加回的成员
  /// 再删掉，防复活变成禁重加）。
  ///
  /// P5：本机已知种类的类型化入口；转移/合并对端未知种类走 [addToCollectionRaw]。
  ///
  /// [userIntent]（默认 true）：用户加成员即接手整理器管着的合集（v124
  /// [_claimCollectionForUser]）。规则归组、AI 整理、同步、扫描等自动路径传 false。
  Future<void> addToCollection(
          int collectionId, MediaKind mediaType, String entryKey,
          {bool userIntent = true}) =>
      addToCollectionRaw(collectionId, mediaType.dbValue, entryKey,
          userIntent: userIntent);

  /// [addToCollection] 的裸串版：合集合并/转移把**现有成员行原样搬家**时用——
  /// 行值可能是对端未来新增的未知种类（或旧值域残留），tryParse 丢弃会静默丢
  /// 成员（Never break userspace）。新增本机成员一律走类型化 [addToCollection]。
  Future<void> addToCollectionRaw(
          int collectionId, String mediaType, String entryKey,
          {bool userIntent = true}) =>
      transaction(() async {
        if (userIntent) await _claimCollectionForUser(collectionId);
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
  /// 成员行键 → 与 [collectionMemberTombstoneKeysFor] 可直比的墓碑键
  /// （`mediaType NUL 墓碑域 entryKey`）。
  Future<String> collectionMemberTombstoneKeyOf(
    String mediaType,
    String entryKey,
  ) async =>
      '$mediaType\u0000${await _tombstoneEntryKeyOf(mediaType, entryKey)}';

  /// 某合集自然键下的全部成员移出墓碑键（`mediaType NUL entryKey`，墓碑域）。
  /// 合并 / 整理把成员并进来前用它跳过用户移出过的成员。
  Future<Set<String>> collectionMemberTombstoneKeysFor(
    String collectionName,
    String collectionType,
  ) async =>
      <String>{
        for (final CollectionMemberTombstoneRow t
            in await (select(collectionMemberTombstones)
                  ..where((t) =>
                      t.collectionName.equals(collectionName) &
                      t.collectionType.equals(collectionType)))
                .get())
          if (t.mediaType.isNotEmpty && t.entryKey.isNotEmpty)
            '${t.mediaType}\u0000${t.entryKey}',
      };

  /// 被用户拒绝的整理分组键（spec §5.2 / §8.5）：带键、不是「并掉」的合集级删除
  /// 哨兵里，键不在任何活合集的 organizeKey / organizeAliases 里的那些。
  Future<Set<String>> getRejectedOrganizeKeys() async =>
      (await getRejectedOrganizeGroups()).keys.toSet();

  /// 被用户拒绝的分组键 → 当时的合集名。哨兵上的键是**集合**（被删合集的主键 + 吸收过
  /// 的别名，[encodeOrganizeAliases] 编码），集合里每个键都算拒绝——另一台设备的 AI
  /// 用另一种原名算出别名里的那个键时，同样不再建。
  ///
  /// 「允许再次建议」不在这里清：同步会把对端仍带着键的哨兵写回来。它是设备本地的放行
  /// 名单（app 偏好），由调用方从结果里减掉；放行后再建出的同键活合集让这个键从「拒绝」
  /// 里自然消失（下面的 live 判据），并经同步传到每台设备。
  Future<Map<String, String>> getRejectedOrganizeGroups() async {
    final Set<String> live = <String>{};
    for (final MediaCollectionRow c in await select(mediaCollections).get()) {
      if (c.organizeKey != null) live.add(c.organizeKey!);
      live.addAll(decodeOrganizeAliases(c.organizeAliases));
    }
    final Map<String, String> out = <String, String>{};
    for (final CollectionMemberTombstoneRow t
        in await (select(collectionMemberTombstones)
              ..where((t) =>
                  t.mediaType
                      .equals(FushiDatabase.collectionTombstoneSentinel) &
                  t.entryKey.equals(FushiDatabase.collectionTombstoneSentinel) &
                  t.organizeKey.isNotNull() &
                  t.organizeMerged.equals(false)))
            .get()) {
      for (final String k in decodeOrganizeAliases(t.organizeKey)) {
        if (!live.contains(k)) out.putIfAbsent(k, () => t.collectionName);
      }
    }
    return out;
  }

  /// 删除哨兵上要记的分组键集合（主键 + 别名，编码成一个字符串）；都没有 → null。
  static String? _deadOrganizeKeySet(MediaCollectionRow col) {
    final Set<String> keys = <String>{
      if (col.organizeKey != null) col.organizeKey!,
      ...decodeOrganizeAliases(col.organizeAliases),
    };
    return keys.isEmpty ? null : encodeOrganizeAliases(keys);
  }

  Future<String> _tombstoneEntryKeyOf(String mediaType, String entryKey) async {
    if (mediaType != MediaKind.epub.dbValue) return entryKey;
    final EpubBookRow? book = await (select(
      epubBooks,
    )..where((t) => t.uid.equals(entryKey))).getSingleOrNull();
    if (book == null) return entryKey;
    final CollectionBookAliasRow? alias = await (select(collectionBookAliases)
          ..where((t) => t.localUid.equals(entryKey)))
        .getSingleOrNull();
    if (alias != null) return alias.remoteKey;
    return collectionBookWireKey(
      bookKey: book.bookKey,
      sourceMetadata: book.sourceMetadata,
    );
  }

  /// 移出成员；移空后自动删该合集（沿用旧 removeEntryFromSeries 语义，避免留 0 成员
  /// 孤儿合集卡）。同事务写成员移出墓碑（schema v40：跨端合集同步是成员并集，无墓碑
  /// 则本端移出的成员会被对端并集复活）。移空自删**不**写合集级墓碑：用户意图只是
  /// 移出成员，合集在对端若还有其它成员应继续存在（成员墓碑已足够收敛）。
  ///
  /// P5：本机已知种类的类型化入口；按成员**行值**移出（可能未知种类）走
  /// [removeFromCollectionRaw]。
  Future<void> removeFromCollection(
          int collectionId, MediaKind mediaType, String entryKey,
          {bool userIntent = true}) =>
      removeFromCollectionRaw(collectionId, mediaType.dbValue, entryKey,
          userIntent: userIntent);

  /// [removeFromCollection] 的裸串版：详情页按现有成员行移出时，行值可能是对端
  /// 未来新增的未知种类——必须能原样移出，tryParse 丢弃会让该成员永远移不掉。
  Future<void> removeFromCollectionRaw(
          int collectionId, String mediaType, String entryKey,
          {bool userIntent = true}) =>
      transaction(() async {
        if (userIntent) await _claimCollectionForUser(collectionId);
        final MediaCollectionRow? col =
            await getMediaCollectionById(collectionId);
        await _carryCollectionPrivacyToMembers(
          collectionId,
          <({String mediaType, String entryKey})>[
            (mediaType: mediaType, entryKey: entryKey),
          ],
        );
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
        // 手动排序 = 用户接手（v124）；自动整理序不接手。
        if (bumpOrderUpdatedAt) await _claimCollectionForUser(collectionId);
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
      removeEntriesFromAllCollections(mediaType, <String>[entryKey]);

  /// [removeEntryFromAllCollections] 的批量版（BUG-2754：批量删视频一次清完，
  /// 不再每条一个事务）。语义逐条等价：先删这些条目的全部成员行，再把因此变空
  /// 的合集连同其标签映射删掉。`IN (...)` 按块走，避开 999 绑定变量上限。
  Future<void> removeEntriesFromAllCollections(
          MediaKind mediaType, Iterable<String> entryKeys) =>
      transaction(() async {
        final List<String> keys = entryKeys.toSet().toList(growable: false);
        if (keys.isEmpty) return;
        final Set<int> ids = <int>{};
        for (final List<String> chunk
            in _chunkForSqlVariables<String>(keys, _kVideoDeleteChunkSize)) {
          final List<MediaCollectionItemRow> affected =
              await (select(mediaCollectionItems)
                    ..where((t) =>
                        t.mediaType.equals(mediaType.dbValue) &
                        t.entryKey.isIn(chunk)))
                  .get();
          if (affected.isEmpty) continue;
          ids.addAll(
              affected.map((MediaCollectionItemRow e) => e.collectionId));
          await (delete(mediaCollectionItems)
                ..where((t) =>
                    t.mediaType.equals(mediaType.dbValue) &
                    t.entryKey.isIn(chunk)))
              .go();
        }
        if (ids.isEmpty) return;
        final Set<int> stillPopulated = <int>{};
        for (final List<int> chunk in _chunkForSqlVariables<int>(
            ids.toList(growable: false), _kVideoDeleteChunkSize)) {
          final List<MediaCollectionItemRow> remaining =
              await (select(mediaCollectionItems)
                    ..where((t) => t.collectionId.isIn(chunk)))
                  .get();
          stillPopulated.addAll(
              remaining.map((MediaCollectionItemRow e) => e.collectionId));
        }
        for (final int cid in ids.difference(stillPopulated)) {
          await deleteTagAssignmentsForHost(
              TagHostKind.collection, collectionTagEntryKey(cid));
          await (delete(mediaCollections)..where((t) => t.id.equals(cid)))
              .go();
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

  /// 该自然键是否存在**合集级**删除墓碑（空哨兵行）。
  ///
  /// BUG-1739：扫描/自动归组等**非用户显式**的合集创建路径用它判「用户删过
  /// 这个合集」——有墓碑就不自动重建，否则删除会被下一次来源重扫按自然键
  /// 原样撤销（用户视角＝「合集无法删除」）。用户显式重建仍走
  /// [createMediaCollection]（清墓碑 = 撤销删除），两种意图各有一个入口。
  Future<bool> hasCollectionDeletionTombstone(
    String name,
    String collectionType,
  ) async =>
      await (select(collectionMemberTombstones)
            ..where((t) =>
                t.collectionName.equals(name) &
                t.collectionType.equals(collectionType) &
                t.mediaType.equals(FushiDatabase.collectionTombstoneSentinel) &
                t.entryKey.equals(FushiDatabase.collectionTombstoneSentinel))
            ..limit(1))
          .getSingleOrNull() !=
      null;

  /// upsert 一条墓碑（重复移出刷新 deletedAt，单行 LWW）。
  Future<void> upsertCollectionMemberTombstone({
    required String collectionName,
    required String collectionType,
    required String mediaType,
    required String entryKey,
    required int deletedAt,
    String? organizeKey,
    bool organizeMerged = false,
  }) =>
      into(collectionMemberTombstones).insertOnConflictUpdate(
        CollectionMemberTombstonesCompanion.insert(
          collectionName: collectionName,
          collectionType: collectionType,
          mediaType: mediaType,
          entryKey: entryKey,
          deletedAt: deletedAt,
          // v125：本机亲手移出 / 删除的进库时刻就是 deletedAt——显式清空，免得 upsert
          // 撞上同键旧行时沿用旧的同步进库戳（早于新 deletedAt，对端会误判旧闻）。
          publishedAt: const Value<int?>(null),
          organizeKey: Value(organizeKey),
          organizeMerged: Value(organizeMerged),
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
        await _carryCollectionPrivacyToMembers(
          id,
          <({String mediaType, String entryKey})>[
            for (final MediaCollectionItemRow m in await getCollectionItems(id))
              (mediaType: m.mediaType, entryKey: m.entryKey),
          ],
        );
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

  /// 冲突解析与 `insertOnConflictUpdate` 相同（按主键 `id`），只多一条 v118 规则：
  /// `localAddedAt`（本机开始拥有的时刻）插入时未携带 → now，冲突转更新时**永不
  /// 改写**——整行 save 是编辑，不是重新拥有（语义见 [FushiDatabase.insertEpubBook]）。
  Future<void> upsertSrtBook(SrtBooksCompanion book) => into(srtBooks).insert(
        book.localAddedAt.present
            ? book
            : book.copyWith(
                localAddedAt:
                    Value<int?>(DateTime.now().millisecondsSinceEpoch)),
        onConflict: DoUpdate(
            (_) => book.copyWith(localAddedAt: const Value<int?>.absent())),
      );

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
        // v137：远端音频绑定同事务清（逻辑外键，没有级联）。
        await (delete(remoteAudioBindings)
              ..where((t) => t.srtBookUid.equals(uid)))
            .go();
        return (delete(srtBooks)..where((t) => t.uid.equals(uid))).go();
      });

  // ── remote audio bindings（v137，设备本地）─────────────────────────
  Future<RemoteAudioBindingRow?> getRemoteAudioBinding(String srtBookUid) =>
      (select(remoteAudioBindings)
            ..where((t) => t.srtBookUid.equals(srtBookUid)))
          .getSingleOrNull();

  Future<List<RemoteAudioBindingRow>> getAllRemoteAudioBindings() =>
      select(remoteAudioBindings).get();

  /// 按 [RemoteAudioBindingsCompanion.srtBookUid] 插入或整行覆盖。
  Future<void> upsertRemoteAudioBinding(RemoteAudioBindingsCompanion row) =>
      into(remoteAudioBindings).insertOnConflictUpdate(row);

  /// 只改进度同步的时刻列（`local_progress_at` / `server_progress_at` /
  /// `progress_synced_at`，v138）。不读改写整行：本机写入时间与「对齐」两路回调
  /// 并发落库，整行覆盖会互相盖掉对方刚写的列。没有这行（绑定已删）时是空操作。
  Future<void> updateRemoteAudioProgressMarks(
    String srtBookUid, {
    int? localProgressAt,
    int? serverProgressAt,
    int? progressSyncedAt,
  }) async {
    final RemoteAudioBindingsCompanion marks = RemoteAudioBindingsCompanion(
      localProgressAt: localProgressAt == null
          ? const Value<int?>.absent()
          : Value<int?>(localProgressAt),
      serverProgressAt: serverProgressAt == null
          ? const Value<int?>.absent()
          : Value<int?>(serverProgressAt),
      progressSyncedAt: progressSyncedAt == null
          ? const Value<int?>.absent()
          : Value<int?>(progressSyncedAt),
    );
    await (update(remoteAudioBindings)
          ..where((t) => t.srtBookUid.equals(srtBookUid)))
        .write(marks);
  }

  Future<int> deleteRemoteAudioBinding(String srtBookUid) =>
      (delete(remoteAudioBindings)
            ..where((t) => t.srtBookUid.equals(srtBookUid)))
          .go();

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

  /// 「比较后写入」（BUG-3537）：仅当 `bookUid` 的本地行时间戳仍等于
  /// [expectedUpdatedAt] 时才 upsert [pos]，返回是否写入。无行按 0 比较（与
  /// 同步层把「无记录」读成 0 时间戳的口径一致）。
  ///
  /// 出站同步（云导入 / 互联 client 落地）在「读本地 → 等网络 → 写本地」之间会被
  /// 别的写者插队：本机作为互联 host 时对端的进度 PUT（只持同步状态窄锁，不再排在
  /// 整轮同步锁后）、本机阅读器自己存进度。决策时读到的时间戳若已被改写，说明
  /// 本地有了更新的事实，旧决策作废——放弃这次落地，交给下一轮重新判定，绝不能
  /// 用决策时的旧值盖掉。重读与写入在同一个事务里：drift 在事务进行中把事务外
  /// 的语句排到其后，中间不会再有写者插进来。
  Future<bool> upsertReaderPositionIfUnchanged(
    ReaderPositionsCompanion pos, {
    required int expectedUpdatedAt,
  }) =>
      transaction(() async {
        final ReaderPositionRow? current =
            await getReaderPosition(pos.bookUid.value);
        if ((current?.updatedAt ?? 0) != expectedUpdatedAt) return false;
        await upsertReaderPosition(pos);
        return true;
      });

  Future<int> deleteReaderPosition(String bookUid) =>
      (delete(readerPositions)..where((t) => t.bookUid.equals(bookUid))).go();
}

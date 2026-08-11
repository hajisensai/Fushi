// 视频域：刮削资料 / 元数据 / 相关作品 / 图组 / 下载流水线（God 类拆分 2026-08：part+mixin，仓库 reader_fushi
// part 先例；mixin 是真类成员——可被测试子类 override、虚分派正常
// （extension 方案在此翻车过）；私有 mixin 不进公共 API 面。
part of 'database.dart';

mixin _FushiDbVideoDomain
    on _$FushiDatabase, _FushiDbLibrary, _FushiDbTagsSync {
  // ── video_scrape_meta（条目刮削资料，v54）─────────────────────────

  /// 写入/覆盖一本视频的刮削资料（bookUid 主键，重刮即覆盖）。
  Future<void> upsertVideoScrapeMeta(VideoScrapeMetaCompanion meta) =>
      into(videoScrapeMeta).insertOnConflictUpdate(meta);

  /// 取单本刮削资料；未刮过返回 null。
  Future<VideoScrapeMetaRow?> getVideoScrapeMeta(String bookUid) =>
      (select(videoScrapeMeta)
            ..where(($VideoScrapeMetaTable t) => t.bookUid.equals(bookUid)))
          .getSingleOrNull();

  /// 已刮削过的 bookUid 集合。自动刮削扫描用它一次性排除已刮的，避免逐本查询
  /// （N+1）。返回 Set 供 O(1) 判断。
  Future<Set<String>> scrapedVideoBookUids() async {
    final List<VideoScrapeMetaRow> rows = await select(videoScrapeMeta).get();
    return <String>{
      for (final VideoScrapeMetaRow r in rows) r.bookUid,
    };
  }

  /// 删除单本刮削资料（用户「重新刮削」前先清，或纠错后作废）。
  Future<void> deleteVideoScrapeMeta(String bookUid) => (delete(videoScrapeMeta)
        ..where(($VideoScrapeMetaTable t) => t.bookUid.equals(bookUid)))
      .go();

  /// 全量条目刮削资料（TODO-2486 视频首页年份筛选）。库页一次拉全表内存建
  /// uid → 行映射，替代逐本 [getVideoScrapeMeta] 的 N+1。
  Future<List<VideoScrapeMetaRow>> getAllVideoScrapeMeta() =>
      select(videoScrapeMeta).get();

  // ── collection_scrape_meta（合集级刮削资料，schema v64 / BUG-1310）────────

  /// 写入/覆盖合集刮削资料（同 collectionId 覆盖，重刮即替换）。
  Future<void> upsertCollectionScrapeMeta(CollectionScrapeMetaCompanion meta) =>
      into(collectionScrapeMeta).insertOnConflictUpdate(meta);

  /// 取合集刮削资料；未刮过返回 null（详情页据此回落到「只有标题 + 进度」的旧形态）。
  Future<CollectionScrapeMetaRow?> getCollectionScrapeMeta(int collectionId) =>
      (select(collectionScrapeMeta)
            ..where(($CollectionScrapeMetaTable t) =>
                t.collectionId.equals(collectionId)))
          .getSingleOrNull();

  /// 监听单个合集的刮削资料。详情页据此在刮削落库后自动重建 hero，无需手动刷新
  /// （与合集封面同一次写入事务，用户点「使用」后资料与背景图一起出现）。
  Stream<CollectionScrapeMetaRow?> watchCollectionScrapeMeta(
          int collectionId) =>
      (select(collectionScrapeMeta)
            ..where(($CollectionScrapeMetaTable t) =>
                t.collectionId.equals(collectionId)))
          .watchSingleOrNull();

  /// 全量合集刮削资料（TODO-2486 视频首页 hero 轮播：backdrop / 简介 / airDate）。
  /// 首页一次拉全表内存建 collectionId → 行映射，替代逐合集查询的 N+1。
  Future<List<CollectionScrapeMetaRow>> getAllCollectionScrapeMeta() =>
      select(collectionScrapeMeta).get();

  /// 删除合集刮削资料（「重新刮削」前先清，或纠错后作废）。
  Future<void> deleteCollectionScrapeMeta(int collectionId) =>
      (delete(collectionScrapeMeta)
            ..where(($CollectionScrapeMetaTable t) =>
                t.collectionId.equals(collectionId)))
          .go();

  // ── collection_relations（合集相关作品，schema v66 / TODO-2484）──────

  /// 整体替换某合集的相关作品边（重刮即替换）。
  ///
  /// 事务内 delete + insert 而非逐条 upsert：关系列表来自源的一次完整响应，
  /// 逐条 upsert 会留下上次刮削已不存在的残边（源侧撤销的关联永远删不掉）。
  Future<void> replaceCollectionRelations(
    int collectionId,
    List<CollectionRelationsCompanion> relations,
  ) =>
      transaction(() async {
        await (delete(collectionRelations)
              ..where(($CollectionRelationsTable t) =>
                  t.collectionId.equals(collectionId)))
            .go();
        for (final CollectionRelationsCompanion c in relations) {
          await into(collectionRelations).insert(c);
        }
      });

  /// 按展示顺序（sortIndex → id）列出某合集的相关作品。
  Future<List<CollectionRelationRow>> getCollectionRelations(
    int collectionId,
  ) =>
      (select(collectionRelations)
            ..where(($CollectionRelationsTable t) =>
                t.collectionId.equals(collectionId))
            ..orderBy([
              ($CollectionRelationsTable t) =>
                  OrderingTerm(expression: t.sortIndex),
              ($CollectionRelationsTable t) => OrderingTerm(expression: t.id),
            ]))
          .get();

  /// 监听某合集的相关作品（详情页据此在刮削落库后自动出现该区块）。
  Stream<List<CollectionRelationRow>> watchCollectionRelations(
    int collectionId,
  ) =>
      (select(collectionRelations)
            ..where(($CollectionRelationsTable t) =>
                t.collectionId.equals(collectionId))
            ..orderBy([
              ($CollectionRelationsTable t) =>
                  OrderingTerm(expression: t.sortIndex),
              ($CollectionRelationsTable t) => OrderingTerm(expression: t.id),
            ]))
          .watch();

  /// 删除某合集的全部相关作品边（「重新刮削」前先清，或纠错后作废）。
  Future<void> deleteCollectionRelations(int collectionId) =>
      (delete(collectionRelations)
            ..where(($CollectionRelationsTable t) =>
                t.collectionId.equals(collectionId)))
          .go();

  /// 升级绑定：把一条纯刮削目标边绑定为本地合集（[targetCollectionId] 传 null
  /// 即解绑退回纯刮削态）。
  Future<void> bindCollectionRelationTarget(
    int relationId,
    int? targetCollectionId,
  ) =>
      (update(collectionRelations)
            ..where(($CollectionRelationsTable t) => t.id.equals(relationId)))
          .write(CollectionRelationsCompanion(
        targetCollectionId: Value<int?>(targetCollectionId),
      ));

  /// 反查：已把 (source, subjectId) 刮成资料的本地合集 id 列表（抓取层用它把
  /// 「纯刮削目标」自动升级绑定为本地合集）。
  Future<List<int>> collectionIdsByScrapeSubject(
    String source,
    String subjectId,
  ) async {
    final List<CollectionScrapeMetaRow> rows =
        await (select(collectionScrapeMeta)
              ..where(($CollectionScrapeMetaTable t) =>
                  t.source.equals(source) & t.subjectId.equals(subjectId)))
            .get();
    return <int>[for (final CollectionScrapeMetaRow r in rows) r.collectionId];
  }

  // ── media_images（媒体附加图组，schema v68 / Jellyfin 图组对齐）──────

  /// 整体替换某合集的附加图组（重刮即替换；空列表 = 清空）。
  ///
  /// 事务内 delete + insert（与 [replaceCollectionRelations] 同理由）：图组来自
  /// 源的一次完整响应，逐条 upsert 会留下上次刮削已不存在的残图行。
  Future<void> replaceMediaImagesForCollection(
    int collectionId,
    List<MediaImagesCompanion> images,
  ) =>
      transaction(() async {
        await (delete(mediaImages)
              ..where(
                  ($MediaImagesTable t) => t.collectionId.equals(collectionId)))
            .go();
        for (final MediaImagesCompanion c in images) {
          await into(mediaImages).insert(c);
        }
      });

  /// 整体替换某视频的附加图组（散装电影刮削用；空列表 = 清空）。
  Future<void> replaceMediaImagesForBook(
    String bookUid,
    List<MediaImagesCompanion> images,
  ) =>
      transaction(() async {
        await (delete(mediaImages)
              ..where(($MediaImagesTable t) => t.bookUid.equals(bookUid)))
            .go();
        for (final MediaImagesCompanion c in images) {
          await into(mediaImages).insert(c);
        }
      });

  /// 某合集的附加图组（kind 组内按 position 升序，backdrop 轮换序即此序）。
  Future<List<MediaImageRow>> getMediaImagesForCollection(int collectionId) =>
      (select(mediaImages)
            ..where(
                ($MediaImagesTable t) => t.collectionId.equals(collectionId))
            ..orderBy([
              ($MediaImagesTable t) => OrderingTerm(expression: t.kind),
              ($MediaImagesTable t) => OrderingTerm(expression: t.position),
            ]))
          .get();

  /// 某视频的附加图组。
  Future<List<MediaImageRow>> getMediaImagesForBook(String bookUid) =>
      (select(mediaImages)
            ..where(($MediaImagesTable t) => t.bookUid.equals(bookUid))
            ..orderBy([
              ($MediaImagesTable t) => OrderingTerm(expression: t.kind),
              ($MediaImagesTable t) => OrderingTerm(expression: t.position),
            ]))
          .get();

  /// 全表附加图组（库页/首页批量预取，替代逐归属查询的 N+1；调用方按
  /// collectionId / bookUid 内存分组）。
  Future<List<MediaImageRow>> getAllMediaImages() => (select(mediaImages)
        ..orderBy([
          ($MediaImagesTable t) => OrderingTerm(expression: t.kind),
          ($MediaImagesTable t) => OrderingTerm(expression: t.position),
        ]))
      .get();

  // ── video metadata（schema v69 / 来源规范刮削）────────────────────

  /// 新增或更新一部规范作品并返回稳定行 id。调用方必须提供 collectionId/bookUid
  /// 之一；DB CHECK 再锁死「恰好一个」的最终不变量。
  Future<int> upsertVideoMetadataWork(
    VideoMetadataWorksCompanion work,
  ) async {
    final List<Column<Object>> conflictTarget;
    if (work.collectionId.present && work.collectionId.value != null) {
      conflictTarget = <Column<Object>>[videoMetadataWorks.collectionId];
    } else if (work.bookUid.present && work.bookUid.value != null) {
      conflictTarget = <Column<Object>>[videoMetadataWorks.bookUid];
    } else if (work.id.present) {
      conflictTarget = <Column<Object>>[videoMetadataWorks.id];
    } else {
      throw ArgumentError(
        'VideoMetadataWorksCompanion must identify a collection or book',
      );
    }
    await into(videoMetadataWorks).insert(
      work,
      onConflict: DoUpdate(
        (_) => work,
        target: conflictTarget,
      ),
    );
    if (work.collectionId.present && work.collectionId.value != null) {
      final VideoMetadataWorkRow? row =
          await getVideoMetadataWorkByCollection(work.collectionId.value!);
      if (row != null) return row.id;
    }
    if (work.bookUid.present && work.bookUid.value != null) {
      final VideoMetadataWorkRow? row =
          await getVideoMetadataWorkByBook(work.bookUid.value!);
      if (row != null) return row.id;
    }
    if (work.id.present) {
      final VideoMetadataWorkRow? row = await (select(videoMetadataWorks)
            ..where(($VideoMetadataWorksTable t) => t.id.equals(work.id.value)))
          .getSingleOrNull();
      if (row != null) return row.id;
    }
    throw StateError('upserted video metadata work cannot be read back');
  }

  Future<VideoMetadataWorkRow?> getVideoMetadataWorkByCollection(
    int collectionId,
  ) =>
      (select(videoMetadataWorks)
            ..where(($VideoMetadataWorksTable t) =>
                t.collectionId.equals(collectionId)))
          .getSingleOrNull();

  Future<VideoMetadataWorkRow?> getVideoMetadataWorkByBook(String bookUid) =>
      (select(videoMetadataWorks)
            ..where(($VideoMetadataWorksTable t) => t.bookUid.equals(bookUid)))
          .getSingleOrNull();

  Future<VideoMetadataWorkRow?> getVideoMetadataWorkById(int workId) =>
      (select(videoMetadataWorks)
            ..where(($VideoMetadataWorksTable t) => t.id.equals(workId)))
          .getSingleOrNull();

  /// Resolves a canonical work from the confirmed provider identity used by
  /// discovery/download subscriptions. Only work-level identities qualify;
  /// season/episode/person identities may reuse the same external id without
  /// owning the collection that contains local episodes.
  Future<VideoMetadataWorkRow?> getVideoMetadataWorkByProviderIdentity({
    required String provider,
    required String externalId,
  }) async {
    final List<VideoMetadataProviderIdentityRow> identities =
        await (select(videoMetadataProviderIdentities)
              ..where(($VideoMetadataProviderIdentitiesTable t) =>
                  t.workId.isNotNull() &
                  t.provider.equals(provider) &
                  t.externalId.equals(externalId))
              ..orderBy(<OrderingTerm Function(
                $VideoMetadataProviderIdentitiesTable,
              )>[
                ($VideoMetadataProviderIdentitiesTable t) =>
                    OrderingTerm.desc(t.isPrimary),
                ($VideoMetadataProviderIdentitiesTable t) =>
                    OrderingTerm(expression: t.identityKey),
              ]))
            .get();
    final int? workId = identities.isEmpty ? null : identities.first.workId;
    return workId == null ? null : getVideoMetadataWorkById(workId);
  }

  Future<List<VideoMetadataWorkRow>> getAllVideoMetadataWorks() =>
      (select(videoMetadataWorks)
            ..orderBy(<OrderingTerm Function($VideoMetadataWorksTable)>[
              ($VideoMetadataWorksTable t) => OrderingTerm(expression: t.id),
            ]))
          .get();

  Future<int> upsertVideoMetadataSeason(
    VideoMetadataSeasonsCompanion season,
  ) async {
    if (!season.workId.present || !season.seasonNumber.present) {
      throw ArgumentError('season requires workId and seasonNumber');
    }
    await into(videoMetadataSeasons).insert(
      season,
      onConflict: DoUpdate(
        (_) => season,
        target: <Column<Object>>[
          videoMetadataSeasons.workId,
          videoMetadataSeasons.seasonNumber,
        ],
      ),
    );
    final VideoMetadataSeasonRow row = await (select(videoMetadataSeasons)
          ..where(($VideoMetadataSeasonsTable t) =>
              t.workId.equals(season.workId.value) &
              t.seasonNumber.equals(season.seasonNumber.value)))
        .getSingle();
    return row.id;
  }

  /// 用一次完整源响应替换作品的季集合；同季号走 UPSERT 保留 id 与下游绑定，源已
  /// 不再返回的季才删除。
  Future<void> replaceVideoMetadataSeasons(
    int workId,
    List<VideoMetadataSeasonsCompanion> seasons,
  ) =>
      transaction(() async {
        final Set<int> numbers = <int>{};
        for (final VideoMetadataSeasonsCompanion season in seasons) {
          if (!season.seasonNumber.present) {
            throw ArgumentError('seasonNumber must be present');
          }
          numbers.add(season.seasonNumber.value);
          final VideoMetadataSeasonsCompanion normalized =
              season.copyWith(workId: Value<int>(workId));
          await into(videoMetadataSeasons).insert(
            normalized,
            onConflict: DoUpdate(
              (_) => normalized,
              target: <Column<Object>>[
                videoMetadataSeasons.workId,
                videoMetadataSeasons.seasonNumber,
              ],
            ),
          );
        }
        final DeleteStatement<$VideoMetadataSeasonsTable,
            VideoMetadataSeasonRow> statement = delete(videoMetadataSeasons)
          ..where(($VideoMetadataSeasonsTable t) {
            final Expression<bool> owner = t.workId.equals(workId);
            return numbers.isEmpty
                ? owner
                : owner & t.seasonNumber.isNotIn(numbers);
          });
        await statement.go();
      });

  Future<List<VideoMetadataSeasonRow>> getVideoMetadataSeasons(int workId) =>
      (select(videoMetadataSeasons)
            ..where(($VideoMetadataSeasonsTable t) => t.workId.equals(workId))
            ..orderBy(<OrderingTerm Function($VideoMetadataSeasonsTable)>[
              ($VideoMetadataSeasonsTable t) =>
                  OrderingTerm(expression: t.seasonNumber),
            ]))
          .get();

  Future<List<VideoMetadataSeasonRow>> getAllVideoMetadataSeasons() =>
      (select(videoMetadataSeasons)
            ..orderBy(<OrderingTerm Function($VideoMetadataSeasonsTable)>[
              ($VideoMetadataSeasonsTable t) =>
                  OrderingTerm(expression: t.workId),
              ($VideoMetadataSeasonsTable t) =>
                  OrderingTerm(expression: t.seasonNumber),
            ]))
          .get();

  Future<int> upsertVideoMetadataEpisode(
    VideoMetadataEpisodesCompanion episode,
  ) async {
    if (!episode.seasonId.present || !episode.episodeNumber.present) {
      throw ArgumentError('episode requires seasonId and episodeNumber');
    }
    await into(videoMetadataEpisodes).insert(
      episode,
      onConflict: DoUpdate(
        (_) => episode,
        target: <Column<Object>>[
          videoMetadataEpisodes.seasonId,
          videoMetadataEpisodes.episodeNumber,
        ],
      ),
    );
    final VideoMetadataEpisodeRow row = await (select(videoMetadataEpisodes)
          ..where(($VideoMetadataEpisodesTable t) =>
              t.seasonId.equals(episode.seasonId.value) &
              t.episodeNumber.equals(episode.episodeNumber.value)))
        .getSingle();
    return row.id;
  }

  /// 用一次完整源响应替换某季分集；同集号走 UPSERT，因此重复刮削不会令本地
  /// bookUid 绑定或 sidecar owner 无谓漂移。
  Future<void> replaceVideoMetadataEpisodes(
    int seasonId,
    List<VideoMetadataEpisodesCompanion> episodes,
  ) =>
      transaction(() async {
        final Set<int> numbers = <int>{};
        for (final VideoMetadataEpisodesCompanion episode in episodes) {
          if (!episode.episodeNumber.present) {
            throw ArgumentError('episodeNumber must be present');
          }
          numbers.add(episode.episodeNumber.value);
          final VideoMetadataEpisodesCompanion normalized =
              episode.copyWith(seasonId: Value<int>(seasonId));
          await into(videoMetadataEpisodes).insert(
            normalized,
            onConflict: DoUpdate(
              (_) => normalized,
              target: <Column<Object>>[
                videoMetadataEpisodes.seasonId,
                videoMetadataEpisodes.episodeNumber,
              ],
            ),
          );
        }
        final DeleteStatement<$VideoMetadataEpisodesTable,
            VideoMetadataEpisodeRow> statement = delete(videoMetadataEpisodes)
          ..where(($VideoMetadataEpisodesTable t) {
            final Expression<bool> owner = t.seasonId.equals(seasonId);
            return numbers.isEmpty
                ? owner
                : owner & t.episodeNumber.isNotIn(numbers);
          });
        await statement.go();
      });

  Future<List<VideoMetadataEpisodeRow>> getVideoMetadataEpisodes(
    int seasonId,
  ) =>
      (select(videoMetadataEpisodes)
            ..where(
                ($VideoMetadataEpisodesTable t) => t.seasonId.equals(seasonId))
            ..orderBy(<OrderingTerm Function($VideoMetadataEpisodesTable)>[
              ($VideoMetadataEpisodesTable t) =>
                  OrderingTerm(expression: t.episodeNumber),
            ]))
          .get();

  Future<List<VideoMetadataEpisodeRow>> getAllVideoMetadataEpisodes() =>
      (select(videoMetadataEpisodes)
            ..orderBy(<OrderingTerm Function($VideoMetadataEpisodesTable)>[
              ($VideoMetadataEpisodesTable t) =>
                  OrderingTerm(expression: t.seasonId),
              ($VideoMetadataEpisodesTable t) =>
                  OrderingTerm(expression: t.episodeNumber),
            ]))
          .get();

  Future<VideoMetadataEpisodeRow?> getVideoMetadataEpisodeByBook(
    String bookUid,
  ) =>
      (select(videoMetadataEpisodes)
            ..where(
                ($VideoMetadataEpisodesTable t) => t.bookUid.equals(bookUid)))
          .getSingleOrNull();

  Future<void> upsertVideoMetadataPeople(
    List<VideoMetadataPeopleCompanion> people,
  ) =>
      batch((Batch batch) {
        batch.insertAllOnConflictUpdate(videoMetadataPeople, people);
      });

  Future<VideoMetadataPersonRow?> getVideoMetadataPerson(String personKey) =>
      (select(videoMetadataPeople)
            ..where(
                ($VideoMetadataPeopleTable t) => t.personKey.equals(personKey)))
          .getSingleOrNull();

  Future<void> upsertVideoMetadataCharacters(
    List<VideoMetadataCharactersCompanion> characters,
  ) =>
      batch((Batch batch) {
        batch.insertAllOnConflictUpdate(videoMetadataCharacters, characters);
      });

  Future<VideoMetadataCharacterRow?> getVideoMetadataCharacter(
    String characterKey,
  ) =>
      (select(videoMetadataCharacters)
            ..where(($VideoMetadataCharactersTable t) =>
                t.characterKey.equals(characterKey)))
          .getSingleOrNull();

  /// 整体替换单一 owner 的 provider identities。五种 owner 必须恰好提供一个。
  Future<void> replaceVideoMetadataProviderIdentities({
    int? workId,
    int? seasonId,
    int? episodeId,
    String? personKey,
    String? characterKey,
    required List<VideoMetadataProviderIdentitiesCompanion> identities,
  }) {
    _requireOneVideoMetadataOwner(
      workId: workId,
      seasonId: seasonId,
      episodeId: episodeId,
      personKey: personKey,
      characterKey: characterKey,
    );
    return transaction(() async {
      final DeleteStatement<$VideoMetadataProviderIdentitiesTable,
              VideoMetadataProviderIdentityRow> statement =
          delete(videoMetadataProviderIdentities);
      if (workId != null) {
        statement.where(($VideoMetadataProviderIdentitiesTable t) =>
            t.workId.equals(workId));
      } else if (seasonId != null) {
        statement.where(($VideoMetadataProviderIdentitiesTable t) =>
            t.seasonId.equals(seasonId));
      } else if (episodeId != null) {
        statement.where(($VideoMetadataProviderIdentitiesTable t) =>
            t.episodeId.equals(episodeId));
      } else if (personKey != null) {
        statement.where(($VideoMetadataProviderIdentitiesTable t) =>
            t.personKey.equals(personKey));
      } else {
        statement.where(($VideoMetadataProviderIdentitiesTable t) =>
            t.characterKey.equals(characterKey!));
      }
      await statement.go();
      for (final VideoMetadataProviderIdentitiesCompanion identity
          in identities) {
        await into(videoMetadataProviderIdentities).insertOnConflictUpdate(
          identity.copyWith(
            workId: Value<int?>(workId),
            seasonId: Value<int?>(seasonId),
            episodeId: Value<int?>(episodeId),
            personKey: Value<String?>(personKey),
            characterKey: Value<String?>(characterKey),
          ),
        );
      }
    });
  }

  Future<List<VideoMetadataProviderIdentityRow>>
      getVideoMetadataProviderIdentities({
    int? workId,
    int? seasonId,
    int? episodeId,
    String? personKey,
    String? characterKey,
  }) {
    _requireOneVideoMetadataOwner(
      workId: workId,
      seasonId: seasonId,
      episodeId: episodeId,
      personKey: personKey,
      characterKey: characterKey,
    );
    final SimpleSelectStatement<$VideoMetadataProviderIdentitiesTable,
            VideoMetadataProviderIdentityRow> query =
        select(videoMetadataProviderIdentities);
    if (workId != null) {
      query.where(
          ($VideoMetadataProviderIdentitiesTable t) => t.workId.equals(workId));
    } else if (seasonId != null) {
      query.where(($VideoMetadataProviderIdentitiesTable t) =>
          t.seasonId.equals(seasonId));
    } else if (episodeId != null) {
      query.where(($VideoMetadataProviderIdentitiesTable t) =>
          t.episodeId.equals(episodeId));
    } else if (personKey != null) {
      query.where(($VideoMetadataProviderIdentitiesTable t) =>
          t.personKey.equals(personKey));
    } else {
      query.where(($VideoMetadataProviderIdentitiesTable t) =>
          t.characterKey.equals(characterKey!));
    }
    query.orderBy(<OrderingTerm Function(
      $VideoMetadataProviderIdentitiesTable,
    )>[
      ($VideoMetadataProviderIdentitiesTable t) =>
          OrderingTerm.desc(t.isPrimary),
      ($VideoMetadataProviderIdentitiesTable t) =>
          OrderingTerm(expression: t.provider),
    ]);
    return query.get();
  }

  Future<void> replaceVideoMetadataRawSnapshots(
    String identityKey,
    List<VideoMetadataRawSnapshotsCompanion> snapshots,
  ) =>
      transaction(() async {
        await (delete(videoMetadataRawSnapshots)
              ..where(($VideoMetadataRawSnapshotsTable t) =>
                  t.identityKey.equals(identityKey)))
            .go();
        for (final VideoMetadataRawSnapshotsCompanion snapshot in snapshots) {
          await into(videoMetadataRawSnapshots).insert(
            snapshot.copyWith(identityKey: Value<String>(identityKey)),
          );
        }
      });

  Future<List<VideoMetadataRawSnapshotRow>> getVideoMetadataRawSnapshots(
    String identityKey,
  ) =>
      (select(videoMetadataRawSnapshots)
            ..where(($VideoMetadataRawSnapshotsTable t) =>
                t.identityKey.equals(identityKey))
            ..orderBy(<OrderingTerm Function($VideoMetadataRawSnapshotsTable)>[
              ($VideoMetadataRawSnapshotsTable t) =>
                  OrderingTerm(expression: t.snapshotKind),
            ]))
          .get();

  /// Terms 是全局去重词典，replace 只替换本作品映射，不会删除其它作品仍引用的词。
  Future<void> replaceVideoMetadataTermsForWork({
    required int workId,
    required List<VideoMetadataTermsCompanion> terms,
    required List<VideoMetadataWorkTermsCompanion> mappings,
  }) =>
      transaction(() async {
        for (final VideoMetadataTermsCompanion term in terms) {
          await into(videoMetadataTerms).insertOnConflictUpdate(term);
        }
        await (delete(videoMetadataWorkTerms)
              ..where(
                  ($VideoMetadataWorkTermsTable t) => t.workId.equals(workId)))
            .go();
        for (final VideoMetadataWorkTermsCompanion mapping in mappings) {
          await into(videoMetadataWorkTerms).insert(
            mapping.copyWith(workId: Value<int>(workId)),
          );
        }
      });

  Future<List<VideoMetadataTermRow>> getVideoMetadataTermsForWork(
    int workId,
  ) async {
    final JoinedSelectStatement<HasResultSet, dynamic> query =
        select(videoMetadataTerms).join(<Join<HasResultSet, dynamic>>[
      innerJoin(
        videoMetadataWorkTerms,
        videoMetadataWorkTerms.termKey.equalsExp(videoMetadataTerms.termKey),
      ),
    ])
          ..where(videoMetadataWorkTerms.workId.equals(workId))
          ..orderBy(<OrderingTerm>[
            OrderingTerm(expression: videoMetadataWorkTerms.sortOrder),
            OrderingTerm(expression: videoMetadataTerms.name),
          ]);
    final List<TypedResult> rows = await query.get();
    return <VideoMetadataTermRow>[
      for (final TypedResult row in rows) row.readTable(videoMetadataTerms),
    ];
  }

  /// 整体替换 work / season / episode 之一的职员表。人物与角色实体需先 upsert。
  Future<void> replaceVideoMetadataCredits({
    int? workId,
    int? seasonId,
    int? episodeId,
    required List<VideoMetadataCreditsCompanion> credits,
  }) {
    _requireOneVideoMetadataOwner(
      workId: workId,
      seasonId: seasonId,
      episodeId: episodeId,
    );
    return transaction(() async {
      final DeleteStatement<$VideoMetadataCreditsTable, VideoMetadataCreditRow>
          statement = delete(videoMetadataCredits);
      if (workId != null) {
        statement
            .where(($VideoMetadataCreditsTable t) => t.workId.equals(workId));
      } else if (seasonId != null) {
        statement.where(
            ($VideoMetadataCreditsTable t) => t.seasonId.equals(seasonId));
      } else {
        statement.where(
            ($VideoMetadataCreditsTable t) => t.episodeId.equals(episodeId!));
      }
      await statement.go();
      for (final VideoMetadataCreditsCompanion credit in credits) {
        await into(videoMetadataCredits).insert(
          credit.copyWith(
            workId: Value<int?>(workId),
            seasonId: Value<int?>(seasonId),
            episodeId: Value<int?>(episodeId),
          ),
        );
      }
    });
  }

  Future<List<VideoMetadataCreditRow>> getVideoMetadataCredits({
    int? workId,
    int? seasonId,
    int? episodeId,
  }) {
    _requireOneVideoMetadataOwner(
      workId: workId,
      seasonId: seasonId,
      episodeId: episodeId,
    );
    final SimpleSelectStatement<$VideoMetadataCreditsTable,
        VideoMetadataCreditRow> query = select(videoMetadataCredits);
    if (workId != null) {
      query.where(($VideoMetadataCreditsTable t) => t.workId.equals(workId));
    } else if (seasonId != null) {
      query
          .where(($VideoMetadataCreditsTable t) => t.seasonId.equals(seasonId));
    } else {
      query.where(
          ($VideoMetadataCreditsTable t) => t.episodeId.equals(episodeId!));
    }
    query.orderBy(<OrderingTerm Function($VideoMetadataCreditsTable)>[
      ($VideoMetadataCreditsTable t) => OrderingTerm(expression: t.sortOrder),
      ($VideoMetadataCreditsTable t) => OrderingTerm(expression: t.id),
    ]);
    return query.get();
  }

  /// 整体替换 work / season / episode / person / character 之一的图片候选集。
  Future<void> replaceVideoMetadataImages({
    int? workId,
    int? seasonId,
    int? episodeId,
    String? personKey,
    String? characterKey,
    required List<VideoMetadataImagesCompanion> images,
  }) {
    _requireOneVideoMetadataOwner(
      workId: workId,
      seasonId: seasonId,
      episodeId: episodeId,
      personKey: personKey,
      characterKey: characterKey,
    );
    return transaction(() async {
      final DeleteStatement<$VideoMetadataImagesTable, VideoMetadataImageRow>
          statement = delete(videoMetadataImages);
      if (workId != null) {
        statement
            .where(($VideoMetadataImagesTable t) => t.workId.equals(workId));
      } else if (seasonId != null) {
        statement.where(
            ($VideoMetadataImagesTable t) => t.seasonId.equals(seasonId));
      } else if (episodeId != null) {
        statement.where(
            ($VideoMetadataImagesTable t) => t.episodeId.equals(episodeId));
      } else if (personKey != null) {
        statement.where(
            ($VideoMetadataImagesTable t) => t.personKey.equals(personKey));
      } else {
        statement.where(($VideoMetadataImagesTable t) =>
            t.characterKey.equals(characterKey!));
      }
      await statement.go();
      for (final VideoMetadataImagesCompanion image in images) {
        await into(videoMetadataImages).insert(
          image.copyWith(
            workId: Value<int?>(workId),
            seasonId: Value<int?>(seasonId),
            episodeId: Value<int?>(episodeId),
            personKey: Value<String?>(personKey),
            characterKey: Value<String?>(characterKey),
          ),
        );
      }
    });
  }

  Future<List<VideoMetadataImageRow>> getVideoMetadataImages({
    int? workId,
    int? seasonId,
    int? episodeId,
    String? personKey,
    String? characterKey,
  }) {
    _requireOneVideoMetadataOwner(
      workId: workId,
      seasonId: seasonId,
      episodeId: episodeId,
      personKey: personKey,
      characterKey: characterKey,
    );
    final SimpleSelectStatement<$VideoMetadataImagesTable,
        VideoMetadataImageRow> query = select(videoMetadataImages);
    if (workId != null) {
      query.where(($VideoMetadataImagesTable t) => t.workId.equals(workId));
    } else if (seasonId != null) {
      query.where(($VideoMetadataImagesTable t) => t.seasonId.equals(seasonId));
    } else if (episodeId != null) {
      query.where(
          ($VideoMetadataImagesTable t) => t.episodeId.equals(episodeId));
    } else if (personKey != null) {
      query.where(
          ($VideoMetadataImagesTable t) => t.personKey.equals(personKey));
    } else {
      query.where(($VideoMetadataImagesTable t) =>
          t.characterKey.equals(characterKey!));
    }
    query.orderBy(<OrderingTerm Function($VideoMetadataImagesTable)>[
      ($VideoMetadataImagesTable t) => OrderingTerm(expression: t.kind),
      ($VideoMetadataImagesTable t) => OrderingTerm(expression: t.position),
      ($VideoMetadataImagesTable t) => OrderingTerm(expression: t.id),
    ]);
    return query.get();
  }

  /// 整体替换一部作品的在线附件，同时保留扫描器绑定的本地附件。
  Future<void> replaceOnlineVideoMetadataExtras(
    int workId,
    List<VideoMetadataExtrasCompanion> extras,
  ) =>
      transaction(() async {
        await (delete(videoMetadataExtras)
              ..where(($VideoMetadataExtrasTable t) =>
                  t.workId.equals(workId) & t.sourceKind.equals('online')))
            .go();
        for (final VideoMetadataExtrasCompanion extra in extras) {
          await into(videoMetadataExtras).insertOnConflictUpdate(
            extra.copyWith(workId: Value<int>(workId)),
          );
        }
      });

  /// 新增或更新本地附件；同一个 VideoBook 只能绑定一部作品。
  Future<void> upsertVideoMetadataExtra(
    VideoMetadataExtrasCompanion extra,
  ) =>
      into(videoMetadataExtras).insertOnConflictUpdate(extra);

  Future<List<VideoMetadataExtraRow>> getVideoMetadataExtras(int workId) =>
      (select(videoMetadataExtras)
            ..where(($VideoMetadataExtrasTable t) => t.workId.equals(workId))
            ..orderBy(<OrderingTerm Function($VideoMetadataExtrasTable)>[
              ($VideoMetadataExtrasTable t) =>
                  OrderingTerm(expression: t.sortOrder),
              ($VideoMetadataExtrasTable t) =>
                  OrderingTerm(expression: t.title),
            ]))
          .get();

  Future<List<VideoMetadataImageRow>> getAllVideoMetadataImages() =>
      (select(videoMetadataImages)
            ..orderBy(<OrderingTerm Function($VideoMetadataImagesTable)>[
              ($VideoMetadataImagesTable t) => OrderingTerm(expression: t.id),
            ]))
          .get();

  Future<List<VideoMetadataExtraRow>> getAllVideoMetadataExtras() =>
      (select(videoMetadataExtras)
            ..orderBy(<OrderingTerm Function($VideoMetadataExtrasTable)>[
              ($VideoMetadataExtrasTable t) =>
                  OrderingTerm(expression: t.workId),
              ($VideoMetadataExtrasTable t) =>
                  OrderingTerm(expression: t.sortOrder),
            ]))
          .get();

  Future<VideoMetadataExtraRow?> getVideoMetadataExtraByBook(
    String bookUid,
  ) =>
      (select(videoMetadataExtras)
            ..where(($VideoMetadataExtrasTable t) => t.bookUid.equals(bookUid)))
          .getSingleOrNull();

  // ── video source scrape settings / runs / sidecar artifacts ───────

  Future<VideoSourceScrapeSettingRow?> getVideoSourceScrapeSettings(
    int sourceId,
  ) =>
      (select(videoSourceScrapeSettings)
            ..where(($VideoSourceScrapeSettingsTable t) =>
                t.sourceId.equals(sourceId)))
          .getSingleOrNull();

  Future<void> upsertVideoSourceScrapeSettings(
    VideoSourceScrapeSettingsCompanion settings,
  ) =>
      into(videoSourceScrapeSettings).insertOnConflictUpdate(settings);

  Future<int> insertVideoSourceScrapeRun(
    VideoSourceScrapeRunsCompanion run,
  ) =>
      into(videoSourceScrapeRuns).insert(run);

  Future<void> updateVideoSourceScrapeRun(
    int runId,
    VideoSourceScrapeRunsCompanion patch,
  ) =>
      (update(videoSourceScrapeRuns)
            ..where(($VideoSourceScrapeRunsTable t) => t.id.equals(runId)))
          .write(patch.copyWith(id: const Value<int>.absent()));

  Future<VideoSourceScrapeRunRow?> getVideoSourceScrapeRun(int runId) =>
      (select(videoSourceScrapeRuns)
            ..where(($VideoSourceScrapeRunsTable t) => t.id.equals(runId)))
          .getSingleOrNull();

  Future<List<VideoSourceScrapeRunRow>> getVideoSourceScrapeRuns({
    int? sourceId,
    int limit = 50,
  }) {
    final SimpleSelectStatement<$VideoSourceScrapeRunsTable,
        VideoSourceScrapeRunRow> query = select(videoSourceScrapeRuns);
    if (sourceId != null) {
      query.where(
          ($VideoSourceScrapeRunsTable t) => t.sourceId.equals(sourceId));
    }
    query
      ..orderBy(<OrderingTerm Function($VideoSourceScrapeRunsTable)>[
        ($VideoSourceScrapeRunsTable t) => OrderingTerm.desc(t.startedAt),
        ($VideoSourceScrapeRunsTable t) => OrderingTerm.desc(t.id),
      ])
      ..limit(limit);
    return query.get();
  }

  /// 进程异常退出不会经过 Flutter dispose；下次启动把遗留 running 任务诚实标成
  /// interrupted，避免任务面板永久显示正在运行。
  Future<int> interruptStaleVideoSourceScrapeRuns({int? finishedAt}) {
    final int now = finishedAt ?? DateTime.now().millisecondsSinceEpoch;
    return (update(videoSourceScrapeRuns)
          ..where(
              ($VideoSourceScrapeRunsTable t) => t.status.equals('running')))
        .write(VideoSourceScrapeRunsCompanion(
      status: const Value<String>('interrupted'),
      phase: const Value<String>('interrupted'),
      lastError: const Value<String>('应用在任务完成前退出'),
      updatedAt: Value<int>(now),
      finishedAt: Value<int?>(now),
    ));
  }

  Future<VideoSidecarArtifactRow?> getVideoSidecarArtifactByPath(
    String path,
  ) =>
      (select(videoSidecarArtifacts)
            ..where(($VideoSidecarArtifactsTable t) => t.path.equals(path)))
          .getSingleOrNull();

  Future<int> upsertVideoSidecarArtifact(
    VideoSidecarArtifactsCompanion artifact,
  ) async {
    if (!artifact.path.present) {
      throw ArgumentError('artifact path must be present');
    }
    await into(videoSidecarArtifacts).insert(
      artifact,
      onConflict: DoUpdate(
        (_) => artifact,
        target: <Column<Object>>[videoSidecarArtifacts.path],
      ),
    );
    final VideoSidecarArtifactRow row = await (select(videoSidecarArtifacts)
          ..where(($VideoSidecarArtifactsTable t) =>
              t.path.equals(artifact.path.value)))
        .getSingle();
    return row.id;
  }

  Future<List<VideoSidecarArtifactRow>> getVideoSidecarArtifacts({
    int? sourceId,
    int? runId,
  }) {
    final SimpleSelectStatement<$VideoSidecarArtifactsTable,
        VideoSidecarArtifactRow> query = select(videoSidecarArtifacts);
    if (sourceId != null) {
      query.where(
          ($VideoSidecarArtifactsTable t) => t.sourceId.equals(sourceId));
    }
    if (runId != null) {
      query.where(($VideoSidecarArtifactsTable t) => t.runId.equals(runId));
    }
    query.orderBy(<OrderingTerm Function($VideoSidecarArtifactsTable)>[
      ($VideoSidecarArtifactsTable t) => OrderingTerm(expression: t.path),
    ]);
    return query.get();
  }

  // ── durable video download pipeline（schema v78）──────────────────

  Future<void> upsertVideoDownloadJob(VideoDownloadJobsCompanion job) async {
    if (!job.jobId.present) {
      throw ArgumentError('video download job requires jobId');
    }
    await into(videoDownloadJobs).insert(
      job,
      onConflict: DoUpdate(
        (_) => job,
        target: <Column<Object>>[videoDownloadJobs.jobId],
      ),
    );
  }

  Future<VideoDownloadJobRow?> getVideoDownloadJob(String jobId) =>
      (select(videoDownloadJobs)
            ..where(($VideoDownloadJobsTable t) => t.jobId.equals(jobId)))
          .getSingleOrNull();

  Future<VideoDownloadJobRow?> findVideoDownloadJobByFingerprintAndTorrentHash(
    String fingerprint,
    String torrentHash,
  ) =>
      (select(videoDownloadJobs)
            ..where(($VideoDownloadJobsTable t) =>
                t.fingerprint.equals(fingerprint) &
                t.torrentHash.equals(torrentHash)))
          .getSingleOrNull();

  Future<List<VideoDownloadJobRow>> getVideoDownloadJobs() =>
      (select(videoDownloadJobs)
            ..orderBy(<OrderingTerm Function($VideoDownloadJobsTable)>[
              ($VideoDownloadJobsTable t) => OrderingTerm.desc(t.priority),
              ($VideoDownloadJobsTable t) => OrderingTerm.desc(t.createdAt),
              ($VideoDownloadJobsTable t) => OrderingTerm(expression: t.jobId),
            ]))
          .get();

  Stream<List<VideoDownloadJobRow>> watchVideoDownloadJobs() =>
      (select(videoDownloadJobs)
            ..orderBy(<OrderingTerm Function($VideoDownloadJobsTable)>[
              ($VideoDownloadJobsTable t) => OrderingTerm.desc(t.priority),
              ($VideoDownloadJobsTable t) => OrderingTerm.desc(t.createdAt),
              ($VideoDownloadJobsTable t) => OrderingTerm(expression: t.jobId),
            ]))
          .watch();

  Future<int> updateVideoDownloadJob(
    String jobId,
    VideoDownloadJobsCompanion patch,
  ) =>
      (update(videoDownloadJobs)
            ..where(($VideoDownloadJobsTable t) => t.jobId.equals(jobId)))
          .write(patch);

  Future<int> deleteVideoDownloadJob(String jobId) => (delete(videoDownloadJobs)
        ..where(($VideoDownloadJobsTable t) => t.jobId.equals(jobId)))
      .go();

  /// 原子领取下一条到期任务。lifecycle 保持 active；worker 是否正在处理完全由 lease
  /// 字段表达。lease 已过期即允许新进程接管，更新带完整 CAS 条件，两个 worker 不能
  /// 同时拿到同一任务。
  Future<VideoDownloadJobRow?> claimNextVideoDownloadJob({
    required String workerId,
    required int nowAt,
    required int leaseDurationMs,
  }) async {
    if (workerId.isEmpty) throw ArgumentError.value(workerId, 'workerId');
    if (leaseDurationMs <= 0) {
      throw ArgumentError.value(leaseDurationMs, 'leaseDurationMs');
    }
    final int claimExpiresAt = nowAt + leaseDurationMs;
    return transaction(() async {
      for (int attempt = 0; attempt < 4; attempt++) {
        final VideoDownloadJobRow? candidate = await (select(videoDownloadJobs)
              ..where(($VideoDownloadJobsTable t) {
                final Expression<bool> due =
                    t.lifecycle.equals(VideoDownloadJobLifecycle.active) &
                        (t.nextAttemptAt.isNull() |
                            t.nextAttemptAt.isSmallerOrEqualValue(nowAt));
                final Expression<bool> unclaimed = t.claimedBy.isNull();
                final Expression<bool> abandoned =
                    t.claimExpiresAt.isNotNull() &
                        t.claimExpiresAt.isSmallerOrEqualValue(nowAt);
                return due & (unclaimed | abandoned);
              })
              ..orderBy(<OrderingTerm Function($VideoDownloadJobsTable)>[
                ($VideoDownloadJobsTable t) => OrderingTerm.desc(t.priority),
                ($VideoDownloadJobsTable t) =>
                    OrderingTerm(expression: t.createdAt),
                ($VideoDownloadJobsTable t) =>
                    OrderingTerm(expression: t.jobId),
              ])
              ..limit(1))
            .getSingleOrNull();
        if (candidate == null) return null;

        final int changed = await (update(videoDownloadJobs)
              ..where(($VideoDownloadJobsTable t) {
                final Expression<bool> due =
                    t.lifecycle.equals(VideoDownloadJobLifecycle.active) &
                        (t.nextAttemptAt.isNull() |
                            t.nextAttemptAt.isSmallerOrEqualValue(nowAt));
                final Expression<bool> unclaimed = t.claimedBy.isNull();
                final Expression<bool> abandoned =
                    t.claimExpiresAt.isNotNull() &
                        t.claimExpiresAt.isSmallerOrEqualValue(nowAt);
                return t.jobId.equals(candidate.jobId) &
                    due &
                    (unclaimed | abandoned);
              }))
            .write(VideoDownloadJobsCompanion(
          nextAttemptAt: const Value<int?>(null),
          claimedBy: Value<String?>(workerId),
          claimExpiresAt: Value<int?>(claimExpiresAt),
          lastError: const Value<String?>(null),
          updatedAt: Value<int>(nowAt),
        ));
        if (changed == 1) return getVideoDownloadJob(candidate.jobId);
      }
      return null;
    });
  }

  Future<bool> renewVideoDownloadJobClaim({
    required String jobId,
    required String workerId,
    required int nowAt,
    required int leaseDurationMs,
  }) async {
    if (workerId.isEmpty) throw ArgumentError.value(workerId, 'workerId');
    if (leaseDurationMs <= 0) {
      throw ArgumentError.value(leaseDurationMs, 'leaseDurationMs');
    }
    final int changed = await (update(videoDownloadJobs)
          ..where(($VideoDownloadJobsTable t) =>
              t.jobId.equals(jobId) &
              t.lifecycle.equals(VideoDownloadJobLifecycle.active) &
              t.claimedBy.equals(workerId) &
              t.claimExpiresAt.isBiggerThanValue(nowAt)))
        .write(VideoDownloadJobsCompanion(
      claimExpiresAt: Value<int?>(nowAt + leaseDurationMs),
      updatedAt: Value<int>(nowAt),
    ));
    return changed == 1;
  }

  /// 当前 worker 失败后按 maxAttempts 决定继续 active 退避还是进入终态 failed。
  Future<bool> retryVideoDownloadJob({
    required String jobId,
    required String workerId,
    required String error,
    required int nowAt,
    required int nextAttemptAt,
  }) =>
      transaction(() async {
        final VideoDownloadJobRow? row = await getVideoDownloadJob(jobId);
        if (row == null ||
            row.lifecycle != VideoDownloadJobLifecycle.active ||
            row.claimedBy != workerId) {
          return false;
        }
        final int nextAttemptCount = row.attemptCount + 1;
        final bool exhausted = nextAttemptCount >= row.maxAttempts;
        final int changed = await (update(videoDownloadJobs)
              ..where(($VideoDownloadJobsTable t) =>
                  t.jobId.equals(jobId) &
                  t.lifecycle.equals(VideoDownloadJobLifecycle.active) &
                  t.claimedBy.equals(workerId)))
            .write(VideoDownloadJobsCompanion(
          lifecycle: Value<String>(exhausted
              ? VideoDownloadJobLifecycle.failed
              : VideoDownloadJobLifecycle.active),
          attemptCount: Value<int>(nextAttemptCount),
          nextAttemptAt: Value<int?>(exhausted ? null : nextAttemptAt),
          claimedBy: const Value<String?>(null),
          claimExpiresAt: const Value<int?>(null),
          lastError: Value<String?>(error),
          updatedAt: Value<int>(nowAt),
          completedAt: Value<int?>(exhausted ? nowAt : null),
        ));
        return changed == 1;
      });

  Future<bool> completeVideoDownloadJob({
    required String jobId,
    required String workerId,
    required int completedAt,
  }) async {
    final int changed = await (update(videoDownloadJobs)
          ..where(($VideoDownloadJobsTable t) =>
              t.jobId.equals(jobId) &
              t.lifecycle.equals(VideoDownloadJobLifecycle.active) &
              t.claimedBy.equals(workerId)))
        .write(VideoDownloadJobsCompanion(
      lifecycle: const Value<String>(VideoDownloadJobLifecycle.completed),
      stageProgress: const Value<double>(1.0),
      nextAttemptAt: const Value<int?>(null),
      claimedBy: const Value<String?>(null),
      claimExpiresAt: const Value<int?>(null),
      lastError: const Value<String?>(null),
      updatedAt: Value<int>(completedAt),
      completedAt: Value<int?>(completedAt),
    ));
    return changed == 1;
  }

  /// CAS 推进到下一业务阶段并释放 lease，让调度器立即领取下一阶段。lifecycle 不随
  /// 阶段切换；只有 completed/failed/cancelled 等生命周期 API 才改它。
  ///
  /// [resetAttempts] defaults to true because reaching a new stage is real
  /// progress. A caller that only regains ground it already held (re-adding a
  /// backend task that disappeared) passes false, otherwise the retry budget
  /// is refunded on every lap of a stuck cycle and no attempt limit can ever
  /// be reached.
  Future<bool> advanceVideoDownloadJobStage({
    required String jobId,
    required String workerId,
    required String stage,
    required int nowAt,
    double? progress,
    String? backendTaskId,
    String? torrentHash,
    String? observedSavePath,
    String? targetRelativeRoot,
    bool resetAttempts = true,
  }) async {
    final int changed = await (update(videoDownloadJobs)
          ..where(($VideoDownloadJobsTable t) =>
              t.jobId.equals(jobId) &
              t.lifecycle.equals(VideoDownloadJobLifecycle.active) &
              t.claimedBy.equals(workerId)))
        .write(VideoDownloadJobsCompanion(
      stage: Value<String>(stage),
      stageProgress: progress == null
          ? const Value<double>.absent()
          : Value<double>(progress),
      backendTaskId: backendTaskId == null
          ? const Value<String?>.absent()
          : Value<String?>(backendTaskId),
      torrentHash: torrentHash == null
          ? const Value<String?>.absent()
          : Value<String?>(torrentHash),
      observedSavePath: observedSavePath == null
          ? const Value<String?>.absent()
          : Value<String?>(observedSavePath),
      targetRelativeRoot: targetRelativeRoot == null
          ? const Value<String?>.absent()
          : Value<String?>(targetRelativeRoot),
      attemptCount:
          resetAttempts ? const Value<int>(0) : const Value<int>.absent(),
      nextAttemptAt: Value<int?>(nowAt),
      claimedBy: const Value<String?>(null),
      claimExpiresAt: const Value<int?>(null),
      lastError: const Value<String?>(null),
      updatedAt: Value<int>(nowAt),
    ));
    return changed == 1;
  }

  /// 需要用户处理的可恢复状态。保持 stage 原样，释放 lease，避免后台继续抢占。
  Future<bool> markVideoDownloadJobNeedsAttention({
    required String jobId,
    required String workerId,
    required String error,
    required int nowAt,
  }) async {
    final int changed = await (update(videoDownloadJobs)
          ..where(($VideoDownloadJobsTable t) =>
              t.jobId.equals(jobId) &
              t.lifecycle.equals(VideoDownloadJobLifecycle.active) &
              t.claimedBy.equals(workerId)))
        .write(VideoDownloadJobsCompanion(
      lifecycle: const Value<String>(VideoDownloadJobLifecycle.needsAttention),
      nextAttemptAt: const Value<int?>(null),
      claimedBy: const Value<String?>(null),
      claimExpiresAt: const Value<int?>(null),
      lastError: Value<String?>(error),
      updatedAt: Value<int>(nowAt),
    ));
    return changed == 1;
  }

  /// Explicit user retry. Only recoverable terminal/actionable states may
  /// become active; a running or completed job is never silently rewound.
  Future<bool> retryVideoDownloadJobByUser({
    required String jobId,
    required int nowAt,
    bool rewindToEnqueue = false,
  }) async {
    final int changed = await (update(videoDownloadJobs)
          ..where(($VideoDownloadJobsTable t) =>
              t.jobId.equals(jobId) &
              t.lifecycle.isIn(<String>[
                VideoDownloadJobLifecycle.needsAttention,
                VideoDownloadJobLifecycle.failed,
              ])))
        .write(VideoDownloadJobsCompanion(
      lifecycle: const Value<String>(VideoDownloadJobLifecycle.active),
      stage: rewindToEnqueue
          ? const Value<String>(VideoDownloadJobStage.enqueue)
          : const Value<String>.absent(),
      stageProgress: rewindToEnqueue
          ? const Value<double>(0)
          : const Value<double>.absent(),
      backendTaskId: rewindToEnqueue
          ? const Value<String?>(null)
          : const Value<String?>.absent(),
      attemptCount: const Value<int>(0),
      nextAttemptAt: Value<int?>(nowAt),
      claimedBy: const Value<String?>(null),
      claimExpiresAt: const Value<int?>(null),
      lastError: const Value<String?>(null),
      completedAt: const Value<int?>(null),
      updatedAt: Value<int>(nowAt),
    ));
    return changed == 1;
  }

  /// Explicit user resume. A cancelled job is paused durable state, not a
  /// failed retry: preserve its current stage when the backend task still
  /// exists, or rewind only when the embedded fast-resume entry disappeared.
  Future<bool> resumeCancelledVideoDownloadJobByUser({
    required String jobId,
    required int nowAt,
    bool rewindToEnqueue = false,
  }) async {
    final int changed = await (update(videoDownloadJobs)
          ..where(($VideoDownloadJobsTable t) =>
              t.jobId.equals(jobId) &
              t.lifecycle.equals(VideoDownloadJobLifecycle.cancelled)))
        .write(VideoDownloadJobsCompanion(
      lifecycle: const Value<String>(VideoDownloadJobLifecycle.active),
      stage: rewindToEnqueue
          ? const Value<String>(VideoDownloadJobStage.enqueue)
          : const Value<String>.absent(),
      stageProgress: rewindToEnqueue
          ? const Value<double>(0)
          : const Value<double>.absent(),
      backendTaskId: rewindToEnqueue
          ? const Value<String?>(null)
          : const Value<String?>.absent(),
      attemptCount: const Value<int>(0),
      nextAttemptAt: Value<int?>(nowAt),
      claimedBy: const Value<String?>(null),
      claimExpiresAt: const Value<int?>(null),
      lastError: const Value<String?>(null),
      completedAt: const Value<int?>(null),
      updatedAt: Value<int>(nowAt),
    ));
    return changed == 1;
  }

  /// The embedded engine can lose a task when its fast-resume snapshot is
  /// missing after an unclean process exit. Rewind the claimed durable job so
  /// the original resource selection is resolved and enqueued again.
  ///
  /// A rewind is a retry, not a fresh start: it consumes one attempt and turns
  /// into [VideoDownloadJobLifecycle.failed] once the budget is exhausted.
  /// Without that cap a task the engine can never hold (full disk, invalid
  /// torrent, a fast-resume entry that never survives a round) re-enqueues
  /// itself forever while the surface reports an eternally running job.
  /// [error] stays visible as `lastError` so the loop is diagnosable while it
  /// is still retrying.
  Future<bool> rewindVideoDownloadJobToEnqueue({
    required String jobId,
    required String workerId,
    required String error,
    required int nowAt,
    required int nextAttemptAt,
  }) =>
      transaction(() async {
        final VideoDownloadJobRow? row = await getVideoDownloadJob(jobId);
        if (row == null ||
            row.lifecycle != VideoDownloadJobLifecycle.active ||
            row.claimedBy != workerId) {
          return false;
        }
        final int nextAttemptCount = row.attemptCount + 1;
        final bool exhausted = nextAttemptCount >= row.maxAttempts;
        final int changed = await (update(videoDownloadJobs)
              ..where(($VideoDownloadJobsTable t) =>
                  t.jobId.equals(jobId) &
                  t.lifecycle.equals(VideoDownloadJobLifecycle.active) &
                  t.claimedBy.equals(workerId)))
            .write(VideoDownloadJobsCompanion(
          lifecycle: Value<String>(exhausted
              ? VideoDownloadJobLifecycle.failed
              : VideoDownloadJobLifecycle.active),
          stage: const Value<String>(VideoDownloadJobStage.enqueue),
          stageProgress: const Value<double>(0),
          backendTaskId: const Value<String?>(null),
          attemptCount: Value<int>(nextAttemptCount),
          nextAttemptAt: Value<int?>(exhausted ? null : nextAttemptAt),
          claimedBy: const Value<String?>(null),
          claimExpiresAt: const Value<int?>(null),
          lastError: Value<String?>(error),
          completedAt: Value<int?>(exhausted ? nowAt : null),
          updatedAt: Value<int>(nowAt),
        ));
        return changed == 1;
      });

  /// Explicit user cancellation. Files and backend tasks are deliberately not
  /// deleted here; the app layer pauses a matching backend task first when the
  /// backend exposes that capability.
  Future<bool> cancelVideoDownloadJobByUser({
    required String jobId,
    required int nowAt,
  }) async {
    final int changed = await (update(videoDownloadJobs)
          ..where(($VideoDownloadJobsTable t) =>
              t.jobId.equals(jobId) &
              t.lifecycle.isIn(<String>[
                VideoDownloadJobLifecycle.active,
                VideoDownloadJobLifecycle.needsAttention,
                VideoDownloadJobLifecycle.failed,
              ])))
        .write(VideoDownloadJobsCompanion(
      lifecycle: const Value<String>(VideoDownloadJobLifecycle.cancelled),
      nextAttemptAt: const Value<int?>(null),
      claimedBy: const Value<String?>(null),
      claimExpiresAt: const Value<int?>(null),
      lastError: const Value<String?>(null),
      completedAt: Value<int?>(nowAt),
      updatedAt: Value<int>(nowAt),
    ));
    return changed == 1;
  }

  /// 不推进 stage 的主动让权；nextAttemptAt 为 null 表示立即可重领。
  Future<bool> releaseVideoDownloadJobClaim({
    required String jobId,
    required String workerId,
    required int nowAt,
    int? nextAttemptAt,
  }) async {
    final int changed = await (update(videoDownloadJobs)
          ..where(($VideoDownloadJobsTable t) =>
              t.jobId.equals(jobId) &
              t.lifecycle.equals(VideoDownloadJobLifecycle.active) &
              t.claimedBy.equals(workerId)))
        .write(VideoDownloadJobsCompanion(
      nextAttemptAt: Value<int?>(nextAttemptAt),
      claimedBy: const Value<String?>(null),
      claimExpiresAt: const Value<int?>(null),
      updatedAt: Value<int>(nowAt),
    ));
    return changed == 1;
  }

  Future<void> upsertVideoDownloadJobFile(
    VideoDownloadJobFilesCompanion file,
  ) async {
    if (!file.jobId.present || !file.originalRelativePath.present) {
      throw ArgumentError('download job file requires jobId and original path');
    }
    await into(videoDownloadJobFiles).insert(
      file,
      onConflict: DoUpdate(
        (_) => file,
        target: <Column<Object>>[
          videoDownloadJobFiles.jobId,
          videoDownloadJobFiles.originalRelativePath,
        ],
      ),
    );
  }

  Future<List<VideoDownloadJobFileRow>> getVideoDownloadJobFiles(
    String jobId,
  ) =>
      (select(videoDownloadJobFiles)
            ..where(($VideoDownloadJobFilesTable t) => t.jobId.equals(jobId))
            ..orderBy(<OrderingTerm Function($VideoDownloadJobFilesTable)>[
              ($VideoDownloadJobFilesTable t) =>
                  OrderingTerm(expression: t.backendFileIndex),
              ($VideoDownloadJobFilesTable t) =>
                  OrderingTerm(expression: t.originalRelativePath),
            ]))
          .get();

  Stream<List<VideoDownloadJobFileRow>> watchVideoDownloadJobFiles(
    String jobId,
  ) =>
      (select(videoDownloadJobFiles)
            ..where(($VideoDownloadJobFilesTable t) => t.jobId.equals(jobId))
            ..orderBy(<OrderingTerm Function($VideoDownloadJobFilesTable)>[
              ($VideoDownloadJobFilesTable t) =>
                  OrderingTerm(expression: t.backendFileIndex),
              ($VideoDownloadJobFilesTable t) =>
                  OrderingTerm(expression: t.originalRelativePath),
            ]))
          .watch();

  Future<int> updateVideoDownloadJobFile(
    int id,
    VideoDownloadJobFilesCompanion patch,
  ) =>
      (update(videoDownloadJobFiles)
            ..where(($VideoDownloadJobFilesTable t) => t.id.equals(id)))
          .write(patch);

  Future<int> deleteVideoDownloadJobFile(int id) =>
      (delete(videoDownloadJobFiles)
            ..where(($VideoDownloadJobFilesTable t) => t.id.equals(id)))
          .go();

  Future<void> replaceVideoDownloadJobFiles(
    String jobId,
    List<VideoDownloadJobFilesCompanion> files,
  ) =>
      transaction(() async {
        await (delete(videoDownloadJobFiles)
              ..where(($VideoDownloadJobFilesTable t) => t.jobId.equals(jobId)))
            .go();
        for (final VideoDownloadJobFilesCompanion file in files) {
          await into(videoDownloadJobFiles).insert(
            file.copyWith(jobId: Value<String>(jobId)),
          );
        }
      });

  Future<void> upsertVideoDownloadJobSubtitle(
    VideoDownloadJobSubtitlesCompanion subtitle,
  ) async {
    if (!subtitle.subtitleId.present) {
      throw ArgumentError('download job subtitle requires subtitleId');
    }
    await into(videoDownloadJobSubtitles).insert(
      subtitle,
      onConflict: DoUpdate(
        (_) => subtitle,
        target: <Column<Object>>[videoDownloadJobSubtitles.subtitleId],
      ),
    );
  }

  Future<List<VideoDownloadJobSubtitleRow>> getVideoDownloadJobSubtitles(
    String jobId,
  ) =>
      (select(videoDownloadJobSubtitles)
            ..where(
                ($VideoDownloadJobSubtitlesTable t) => t.jobId.equals(jobId))
            ..orderBy(<OrderingTerm Function($VideoDownloadJobSubtitlesTable)>[
              ($VideoDownloadJobSubtitlesTable t) =>
                  OrderingTerm(expression: t.season),
              ($VideoDownloadJobSubtitlesTable t) =>
                  OrderingTerm(expression: t.episode),
              ($VideoDownloadJobSubtitlesTable t) =>
                  OrderingTerm(expression: t.subtitleId),
            ]))
          .get();

  Stream<List<VideoDownloadJobSubtitleRow>> watchVideoDownloadJobSubtitles(
    String jobId,
  ) =>
      (select(videoDownloadJobSubtitles)
            ..where(
                ($VideoDownloadJobSubtitlesTable t) => t.jobId.equals(jobId))
            ..orderBy(<OrderingTerm Function($VideoDownloadJobSubtitlesTable)>[
              ($VideoDownloadJobSubtitlesTable t) =>
                  OrderingTerm(expression: t.season),
              ($VideoDownloadJobSubtitlesTable t) =>
                  OrderingTerm(expression: t.episode),
              ($VideoDownloadJobSubtitlesTable t) =>
                  OrderingTerm(expression: t.subtitleId),
            ]))
          .watch();

  Future<int> updateVideoDownloadJobSubtitle(
    String subtitleId,
    VideoDownloadJobSubtitlesCompanion patch,
  ) =>
      (update(videoDownloadJobSubtitles)
            ..where(($VideoDownloadJobSubtitlesTable t) =>
                t.subtitleId.equals(subtitleId)))
          .write(patch);

  Future<int> deleteVideoDownloadJobSubtitle(String subtitleId) =>
      (delete(videoDownloadJobSubtitles)
            ..where(($VideoDownloadJobSubtitlesTable t) =>
                t.subtitleId.equals(subtitleId)))
          .go();

  Future<void> upsertVideoDownloadSubscription(
    VideoDownloadSubscriptionsCompanion subscription,
  ) async {
    if (!subscription.subscriptionId.present) {
      throw ArgumentError('video download subscription requires id');
    }
    await into(videoDownloadSubscriptions).insert(
      subscription,
      onConflict: DoUpdate(
        (_) => subscription,
        target: <Column<Object>>[
          videoDownloadSubscriptions.subscriptionId,
        ],
      ),
    );
  }

  Future<VideoDownloadSubscriptionRow?> getVideoDownloadSubscription(
    String subscriptionId,
  ) =>
      (select(videoDownloadSubscriptions)
            ..where(($VideoDownloadSubscriptionsTable t) =>
                t.subscriptionId.equals(subscriptionId)))
          .getSingleOrNull();

  Future<List<VideoDownloadSubscriptionRow>> getVideoDownloadSubscriptions() =>
      (select(videoDownloadSubscriptions)
            ..orderBy(<OrderingTerm Function($VideoDownloadSubscriptionsTable)>[
              ($VideoDownloadSubscriptionsTable t) =>
                  OrderingTerm.desc(t.createdAt),
              ($VideoDownloadSubscriptionsTable t) =>
                  OrderingTerm(expression: t.subscriptionId),
            ]))
          .get();

  Stream<List<VideoDownloadSubscriptionRow>>
      watchVideoDownloadSubscriptions() => (select(videoDownloadSubscriptions)
            ..orderBy(<OrderingTerm Function($VideoDownloadSubscriptionsTable)>[
              ($VideoDownloadSubscriptionsTable t) =>
                  OrderingTerm.desc(t.createdAt),
              ($VideoDownloadSubscriptionsTable t) =>
                  OrderingTerm(expression: t.subscriptionId),
            ]))
          .watch();

  Future<int> updateVideoDownloadSubscription(
    String subscriptionId,
    VideoDownloadSubscriptionsCompanion patch,
  ) =>
      (update(videoDownloadSubscriptions)
            ..where(($VideoDownloadSubscriptionsTable t) =>
                t.subscriptionId.equals(subscriptionId)))
          .write(patch);

  Future<int> deleteVideoDownloadSubscription(String subscriptionId) =>
      (delete(videoDownloadSubscriptions)
            ..where(($VideoDownloadSubscriptionsTable t) =>
                t.subscriptionId.equals(subscriptionId)))
          .go();

  /// 原子领取一个到期订阅检查。订阅没有 job lifecycle/stage；enabled、nextCheckAt
  /// 与 lease 正交表达「是否调度 / 何时调度 / 谁正在调度」。
  Future<VideoDownloadSubscriptionRow?> claimNextVideoDownloadSubscription({
    required String workerId,
    required int nowAt,
    required int leaseDurationMs,
  }) async {
    if (workerId.isEmpty) throw ArgumentError.value(workerId, 'workerId');
    if (leaseDurationMs <= 0) {
      throw ArgumentError.value(leaseDurationMs, 'leaseDurationMs');
    }
    final int claimExpiresAt = nowAt + leaseDurationMs;
    return transaction(() async {
      for (int attempt = 0; attempt < 4; attempt++) {
        final VideoDownloadSubscriptionRow? candidate =
            await (select(videoDownloadSubscriptions)
                  ..where(($VideoDownloadSubscriptionsTable t) {
                    final Expression<bool> due = t.enabled.equals(true) &
                        (t.nextCheckAt.isNull() |
                            t.nextCheckAt.isSmallerOrEqualValue(nowAt));
                    final Expression<bool> unclaimed = t.claimedBy.isNull();
                    final Expression<bool> abandoned =
                        t.claimExpiresAt.isNotNull() &
                            t.claimExpiresAt.isSmallerOrEqualValue(nowAt);
                    return due & (unclaimed | abandoned);
                  })
                  ..orderBy(<OrderingTerm Function(
                      $VideoDownloadSubscriptionsTable)>[
                    ($VideoDownloadSubscriptionsTable t) =>
                        OrderingTerm(expression: t.nextCheckAt),
                    ($VideoDownloadSubscriptionsTable t) =>
                        OrderingTerm(expression: t.createdAt),
                    ($VideoDownloadSubscriptionsTable t) =>
                        OrderingTerm(expression: t.subscriptionId),
                  ])
                  ..limit(1))
                .getSingleOrNull();
        if (candidate == null) return null;

        final int changed = await (update(videoDownloadSubscriptions)
              ..where(($VideoDownloadSubscriptionsTable t) {
                final Expression<bool> due = t.enabled.equals(true) &
                    (t.nextCheckAt.isNull() |
                        t.nextCheckAt.isSmallerOrEqualValue(nowAt));
                final Expression<bool> unclaimed = t.claimedBy.isNull();
                final Expression<bool> abandoned =
                    t.claimExpiresAt.isNotNull() &
                        t.claimExpiresAt.isSmallerOrEqualValue(nowAt);
                return t.subscriptionId.equals(candidate.subscriptionId) &
                    due &
                    (unclaimed | abandoned);
              }))
            .write(VideoDownloadSubscriptionsCompanion(
          claimedBy: Value<String?>(workerId),
          claimExpiresAt: Value<int?>(claimExpiresAt),
          updatedAt: Value<int>(nowAt),
        ));
        if (changed == 1) {
          return getVideoDownloadSubscription(candidate.subscriptionId);
        }
      }
      return null;
    });
  }

  Future<bool> renewVideoDownloadSubscriptionClaim({
    required String subscriptionId,
    required String workerId,
    required int nowAt,
    required int leaseDurationMs,
  }) async {
    if (workerId.isEmpty) throw ArgumentError.value(workerId, 'workerId');
    if (leaseDurationMs <= 0) {
      throw ArgumentError.value(leaseDurationMs, 'leaseDurationMs');
    }
    final int changed = await (update(videoDownloadSubscriptions)
          ..where(($VideoDownloadSubscriptionsTable t) =>
              t.subscriptionId.equals(subscriptionId) &
              t.enabled.equals(true) &
              t.claimedBy.equals(workerId) &
              t.claimExpiresAt.isBiggerThanValue(nowAt)))
        .write(VideoDownloadSubscriptionsCompanion(
      claimExpiresAt: Value<int?>(nowAt + leaseDurationMs),
      updatedAt: Value<int>(nowAt),
    ));
    return changed == 1;
  }

  Future<bool> completeVideoDownloadSubscriptionCheck({
    required String subscriptionId,
    required String workerId,
    required int checkedAt,
    required int nextCheckAt,
    int? matchedAt,
    bool fulfillOneShot = false,
  }) async {
    final int changed = await (update(videoDownloadSubscriptions)
          ..where(($VideoDownloadSubscriptionsTable t) =>
              t.subscriptionId.equals(subscriptionId) &
              t.claimedBy.equals(workerId)))
        .write(VideoDownloadSubscriptionsCompanion(
      enabled: fulfillOneShot
          ? const Value<bool>(false)
          : const Value<bool>.absent(),
      nextCheckAt: Value<int?>(nextCheckAt),
      claimedBy: const Value<String?>(null),
      claimExpiresAt: const Value<int?>(null),
      retryCount: const Value<int>(0),
      lastCheckedAt: Value<int?>(checkedAt),
      lastMatchedAt: matchedAt == null
          ? const Value<int?>.absent()
          : Value<int?>(matchedAt),
      fulfilledAt:
          fulfillOneShot ? Value<int?>(checkedAt) : const Value<int?>.absent(),
      lastError: const Value<String?>(null),
      updatedAt: Value<int>(checkedAt),
    ));
    return changed == 1;
  }

  Future<bool> retryVideoDownloadSubscriptionCheck({
    required String subscriptionId,
    required String workerId,
    required String error,
    required int failedAt,
    required int nextCheckAt,
  }) =>
      transaction(() async {
        final VideoDownloadSubscriptionRow? row =
            await getVideoDownloadSubscription(subscriptionId);
        if (row == null || row.claimedBy != workerId) {
          return false;
        }
        final int changed = await (update(videoDownloadSubscriptions)
              ..where(($VideoDownloadSubscriptionsTable t) =>
                  t.subscriptionId.equals(subscriptionId) &
                  t.claimedBy.equals(workerId)))
            .write(VideoDownloadSubscriptionsCompanion(
          nextCheckAt: Value<int?>(nextCheckAt),
          claimedBy: const Value<String?>(null),
          claimExpiresAt: const Value<int?>(null),
          retryCount: Value<int>(row.retryCount + 1),
          lastCheckedAt: Value<int?>(failedAt),
          lastError: Value<String?>(error),
          updatedAt: Value<int>(failedAt),
        ));
        return changed == 1;
      });

  Future<void> upsertVideoDownloadSubscriptionItem(
    VideoDownloadSubscriptionItemsCompanion item,
  ) async {
    if (!item.subscriptionId.present ||
        !item.logicalItemKey.present ||
        !item.resourceProvider.present ||
        !item.selectedResourceId.present) {
      throw ArgumentError(
          'subscription item requires subscription and resource identity');
    }
    await into(videoDownloadSubscriptionItems).insert(
      item,
      onConflict: DoUpdate(
        (_) => item,
        target: <Column<Object>>[
          videoDownloadSubscriptionItems.subscriptionId,
          videoDownloadSubscriptionItems.logicalItemKey,
        ],
      ),
    );
  }

  Future<List<VideoDownloadSubscriptionItemRow>>
      getVideoDownloadSubscriptionItems(String subscriptionId) =>
          (select(videoDownloadSubscriptionItems)
                ..where(($VideoDownloadSubscriptionItemsTable t) =>
                    t.subscriptionId.equals(subscriptionId))
                ..orderBy(<OrderingTerm Function(
                    $VideoDownloadSubscriptionItemsTable)>[
                  ($VideoDownloadSubscriptionItemsTable t) =>
                      OrderingTerm(expression: t.season),
                  ($VideoDownloadSubscriptionItemsTable t) =>
                      OrderingTerm(expression: t.episode),
                  ($VideoDownloadSubscriptionItemsTable t) =>
                      OrderingTerm(expression: t.discoveredAt),
                ]))
              .get();

  Stream<List<VideoDownloadSubscriptionItemRow>>
      watchVideoDownloadSubscriptionItems(String subscriptionId) =>
          (select(videoDownloadSubscriptionItems)
                ..where(($VideoDownloadSubscriptionItemsTable t) =>
                    t.subscriptionId.equals(subscriptionId))
                ..orderBy(<OrderingTerm Function(
                    $VideoDownloadSubscriptionItemsTable)>[
                  ($VideoDownloadSubscriptionItemsTable t) =>
                      OrderingTerm(expression: t.season),
                  ($VideoDownloadSubscriptionItemsTable t) =>
                      OrderingTerm(expression: t.episode),
                  ($VideoDownloadSubscriptionItemsTable t) =>
                      OrderingTerm(expression: t.discoveredAt),
                ]))
              .watch();

  Future<int> updateVideoDownloadSubscriptionItem(
    int id,
    VideoDownloadSubscriptionItemsCompanion patch,
  ) =>
      (update(videoDownloadSubscriptionItems)
            ..where(
                ($VideoDownloadSubscriptionItemsTable t) => t.id.equals(id)))
          .write(patch);

  Future<int> deleteVideoDownloadSubscriptionItem(int id) => (delete(
          videoDownloadSubscriptionItems)
        ..where(($VideoDownloadSubscriptionItemsTable t) => t.id.equals(id)))
      .go();

  /// 监听视频库 uid 集合。插入/删除行时发出更新后的 uid 列表；库页据此在任意
  /// 导入路径（页内 / 拖拽 / 外部「用 Fushi 打开」/ 远端下载）落库后自动重查，
  /// 无需每个调用点各自记得刷新（BUG-793）。注意 Drift 的表级失效会让纯列更新
  /// （封面回写、播放进度）也触发本流，故消费方按集合是否变化去重，避免自愈
  /// 写回引发的重刷环。
  /// BUG-793/BUG-834：监听 videoBooks 集合变化改用 [tableUpdates] 手动重查，而非 drift
  /// keyed `.watch()`。keyed 查询流在最后一个订阅取消时会安排一个缓存保留 `Timer.run`
  /// （drift 内部「多留一会缓存」优化）；真机上它下一拍即触发无害，但在 widget 测试里页面
  /// dispose 取消订阅后该 Timer 仍 pending，触发 flutter_test `!timersPending` 断言并让
  /// flutter_tester isolate 永不退出（BUG-834：所有挂载 HomeVideoPage 的 suite 挂死、
  /// CI 全量单测卡 60min）。[tableUpdates] 流不是 QueryStream、取消时不走 markAsClosed、
  /// 不安排该 Timer，故切走视频页不再遗留孤儿 async。消费方（`_onVideoUidsChanged`）按
  /// 集合去重，表内非集合变更（进度/封面回写）触发的额外重查无害。
  Stream<List<String>> watchVideoBookUids() {
    Future<List<String>> currentUids() async => (await select(videoBooks).get())
        .map((VideoBookRow row) => row.bookUid)
        .toList();
    late final StreamController<List<String>> controller;
    StreamSubscription<void>? updatesSub;
    controller = StreamController<List<String>>(
      onListen: () {
        // 初始 emit：等同旧 drift keyed `.watch()` 首发，库页首次加载不回归。
        currentUids().then((List<String> v) {
          if (!controller.isClosed) controller.add(v);
        });
        // 表级变更重查：BUG-793 自动刷新保留。
        updatesSub =
            tableUpdates(TableUpdateQuery.onTable(videoBooks)).listen((_) {
          currentUids().then((List<String> v) {
            if (!controller.isClosed) controller.add(v);
          });
        });
      },
      // BUG-834 follow-up：async* + `await for` 广播流的订阅 cancel() 永不完成，
      // 让 flutter_test 的 awaited tearDown 挂死超时。改为手动 StreamController，
      // onCancel 里 await 内层 listen 订阅的 cancel()（会正常完成），使取消收敛。
      onCancel: () async {
        await updatesSub?.cancel();
      },
    );
    return controller.stream;
  }

  /// 仅发出 video_books 表级更新通知，不改任何业务列。导入事务和 metadata apply
  /// 在写入多个关联表后可显式调用，让当前视频页统一重查；消费方仍按 uid 集合去重。
  void notifyVideoLibraryChanged() {
    notifyUpdates(<TableUpdate>{
      TableUpdate.onTable(videoBooks, kind: UpdateKind.update),
    });
  }

  /// 写播放断点。[playedAt] = 这个断点是**什么时候**留下的毫秒时刻（本机播放传
  /// now；远端进度回灌传对端的 `positionUpdatedAtMs`，别传 now——那会把「对方三天
  /// 前看的」冒充成「本机刚看的」，直接污染合集续播锚点）。
  ///
  /// 位置与时刻同一条 UPDATE 落库：不存在「有进度但没时刻」的中间态，
  /// [VideoBooks.lastPlayedAt] 的不变量由这里唯一保证（BUG-1542）。
  Future<void> updateVideoBookPosition(
    String bookUid,
    int positionMs, {
    required int playedAt,
  }) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(
        lastPositionMs: Value(positionMs),
        lastPlayedAt: Value<int?>(playedAt > 0 ? playedAt : null),
      ));

  Future<void> updateVideoBookEpisode(String bookUid, int episodeIndex) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(currentEpisode: Value(episodeIndex)));

  /// 回写整段播放列表 JSON（各集 positionMs 改变时持久化每集进度）。
  Future<void> updateVideoBookPlaylistJson(
          String bookUid, String playlistJson) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(playlistJson: Value(playlistJson)));

  /// 更新音画延迟（毫秒）：字幕 cue 同步偏移，跨重启保留。
  Future<void> updateVideoBookDelayMs(String bookUid, int delayMs) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(delayMs: Value(delayMs)));

  /// 更新用户选中的字幕源（外挂存路径；内嵌存 `embedded:<n>`；关闭存 null）。
  Future<void> updateVideoBookSubtitleSource(
          String bookUid, String? subtitleSource) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(subtitleSource: Value(subtitleSource)));

  /// 更新用户选中的副字幕源（TODO-857）：与 [updateVideoBookSubtitleSource] 同款
  /// 四态编码（外挂路径 / `embedded:<n>` / `off:` / null）。
  Future<void> updateVideoBookSecondarySubtitleSource(
          String bookUid, String? secondarySubtitleSource) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid))).write(
          VideoBooksCompanion(
              secondarySubtitleSource: Value(secondarySubtitleSource)));

  /// 更新用户选中的音轨 id（libmpv `AudioTrack.id`；清除存 null）。
  Future<void> updateVideoBookAudioTrackId(
          String bookUid, String? audioTrackId) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(audioTrackId: Value(audioTrackId)));

  /// 更新视频封面图绝对路径（用户在书架/视频库长按菜单手动设置）。
  Future<void> updateVideoBookCover(String bookUid, String coverPath) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(coverPath: Value(coverPath)));

  /// 清空视频封面图路径（回落到「无封面」占位）。
  ///
  /// 与 [updateVideoBookCover] 分开而不是给它塞 null：清空是**独立动作**（存量
  /// 子篇作品海报摘除，见 `member_cover_cleanup.dart`），可空参数会让「忘了传」
  /// 和「有意清空」在类型上无法区分。
  Future<void> clearVideoBookCover(String bookUid) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(const VideoBooksCompanion(coverPath: Value<String?>(null)));

  /// 更新视频/播放列表标题（用户在视频库长按菜单「重命名」）。title 列已存在，
  /// 无 schema 变更。
  Future<void> updateVideoBookTitle(String bookUid, String title) =>
      (update(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
          .write(VideoBooksCompanion(title: Value(title)));

  /// 删除视频书：标签映射（v77 起逻辑外键）与 audio_cues 的 bookKey 都不是 DB
  /// 外键（cue 的 owner key 对有声书/SRT/视频共用一个字符串，无法挂 FK），必须
  /// 在同一事务里显式清（BUG-276：否则删视频后 cue 行永久残留）。
  Future<void> deleteVideoBook(String bookUid) => transaction(() async {
        await (delete(audioCues)..where((t) => t.bookKey.equals(bookUid))).go();
        // TODO-616：同事务清 shelf_entry（mediaType='video'、entryKey=bookUid）。
        await deleteShelfEntry(MediaKind.video, bookUid);
        await deleteTagAssignmentsForHost(TagHostKind.video, bookUid);
        await (delete(videoBooks)..where((t) => t.bookUid.equals(bookUid)))
            .go();
      });
}

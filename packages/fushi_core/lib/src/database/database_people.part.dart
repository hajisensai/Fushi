// 作品图谱 L5（schema v135）：人物聚合页的读写内核 + 动画 ↔ 原作进度对应点。
// 表语义见 people_tables.dart；spec `docs/specs/2026-10-24-cross-media-links.md` §5 / §6。
part of 'database.dart';

/// [PersonIdentityBridges.source] 的已知值。
abstract final class PersonIdentityBridgeSource {
  /// Wikidata 桥接（纯缓存）。
  static const String wikidata = 'wikidata';

  /// 用户在人物页确认 / 否决「是同一人」。
  static const String manual = 'manual';
}

/// 视频侧一个人物的一条外部身份（`video_metadata_provider_identities` 的人物行）。
typedef VideoPersonIdentity = ({
  String personKey,
  String provider,
  String externalId,
});

/// 曲目署名 + 署名艺人行（人物页 / 曲目详情的人物列表用）。
typedef MusicCreditWithArtist = ({
  MusicTrackCreditRow credit,
  MusicArtistRow artist,
});

/// 一对 adaptation 端点（原作 → 改编）在对应点表里的身份。
typedef AdaptationProgressPair = ({
  String sourceKind,
  String sourceKey,
  String adaptationKind,
  String adaptationKey,
});

mixin _FushiDbPeople on _$FushiDatabase {
  // ── 游戏配音表缓存 ──────────────────────────────────────────────

  Future<GameVoiceCastRow?> getGameVoiceCast(String gameId) => (select(
    gameVoiceCasts,
  )..where((GameVoiceCasts t) => t.gameId.equals(gameId))).getSingleOrNull();

  Future<List<GameVoiceCastRow>> allGameVoiceCasts() =>
      select(gameVoiceCasts).get();

  /// 写一部游戏的配音表（同键覆盖：重新取得 / 换绑 VN）。
  Future<void> upsertGameVoiceCast(GameVoiceCastsCompanion row) =>
      into(gameVoiceCasts).insertOnConflictUpdate(row);

  // ── 人物身份桥 ──────────────────────────────────────────────────

  /// 全部桥（含 manual 墓碑——人物页要据此不再建议同一对）。
  Future<List<PersonIdentityBridgeRow>> allPersonIdentityBridges() =>
      select(personIdentityBridges).get();

  /// 落一轮 Wikidata 桥接结果：[equivalents] 的每个键是查询过的节点，值是同一
  /// Wikidata 条目上的其它节点（可空 = 查无结果）。同一键的旧 wikidata 行整组替换，
  /// 并写自环「查过」标记（[at] 是查询时刻，过期由调用方判断后重查）。
  Future<void> replaceWikidataPersonBridges(
    Map<String, Set<String>> equivalents, {
    required int at,
  }) => transaction(() async {
    for (final MapEntry<String, Set<String>> e in equivalents.entries) {
      await (delete(personIdentityBridges)..where(
            (PersonIdentityBridges t) =>
                t.subject.equals(e.key) &
                t.source.equals(PersonIdentityBridgeSource.wikidata),
          ))
          .go();
      for (final String object in <String>{e.key, ...e.value}) {
        await into(personIdentityBridges).insert(
          PersonIdentityBridgesCompanion.insert(
            subject: e.key,
            object: object,
            source: PersonIdentityBridgeSource.wikidata,
            createdAt: at,
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    }
  });

  /// 用户确认（[same] = true）或否决 / 取消合并（false，写墓碑）两节点是同一人。
  /// 两端按字典序规范化，(A, B) 与 (B, A) 落同一行。
  Future<void> setManualPersonBridge(
    String a,
    String b, {
    required bool same,
    required int at,
  }) {
    final bool ordered = a.compareTo(b) <= 0;
    return into(personIdentityBridges).insertOnConflictUpdate(
      PersonIdentityBridgesCompanion.insert(
        subject: ordered ? a : b,
        object: ordered ? b : a,
        source: PersonIdentityBridgeSource.manual,
        createdAt: at,
        deletedAt: Value<int?>(same ? null : at),
      ),
    );
  }

  /// 两节点之间的 manual 桥（含墓碑；两端按 [setManualPersonBridge] 同一规则规范化）。
  Future<PersonIdentityBridgeRow?> manualPersonBridge(String a, String b) {
    final bool ordered = a.compareTo(b) <= 0;
    final String subject = ordered ? a : b;
    final String object = ordered ? b : a;
    return (select(personIdentityBridges)..where(
          (PersonIdentityBridges t) =>
              t.subject.equals(subject) &
              t.object.equals(object) &
              t.source.equals(PersonIdentityBridgeSource.manual),
        ))
        .getSingleOrNull();
  }

  /// [setManualPersonBridge] 的反向（撤销「确认 / 否决同一人」）：把这一对的 manual
  /// 桥恢复成 [previous]（执行前读到的行，原样写回 `createdAt` / `deletedAt`）；
  /// [previous] 为 null = 执行前没有这一行，删掉。
  Future<void> restoreManualPersonBridge(
    String a,
    String b, {
    required PersonIdentityBridgeRow? previous,
  }) {
    final bool ordered = a.compareTo(b) <= 0;
    final String subject = ordered ? a : b;
    final String object = ordered ? b : a;
    if (previous == null) {
      return (delete(personIdentityBridges)..where(
            (PersonIdentityBridges t) =>
                t.subject.equals(subject) &
                t.object.equals(object) &
                t.source.equals(PersonIdentityBridgeSource.manual),
          ))
          .go();
    }
    return into(personIdentityBridges).insertOnConflictUpdate(
      PersonIdentityBridgesCompanion.insert(
        subject: subject,
        object: object,
        source: PersonIdentityBridgeSource.manual,
        createdAt: previous.createdAt,
        deletedAt: Value<int?>(previous.deletedAt),
      ),
    );
  }

  // ── 人物图的原料（视频 / 音乐）──────────────────────────────────

  /// 视频侧全部人物行（只取名字类字段由调用方决定；表本身不大）。
  Future<List<VideoMetadataPersonRow>> allVideoMetadataPeople() =>
      select(videoMetadataPeople).get();

  /// 视频侧全部人物的外部身份。
  Future<List<VideoPersonIdentity>> allVideoPersonIdentities() async {
    final List<VideoMetadataProviderIdentityRow> rows =
        await (select(videoMetadataProviderIdentities)..where(
              (VideoMetadataProviderIdentities t) => t.personKey.isNotNull(),
            ))
            .get();
    return <VideoPersonIdentity>[
      for (final VideoMetadataProviderIdentityRow r in rows)
        (
          personKey: r.personKey!,
          provider: r.provider,
          externalId: r.externalId,
        ),
    ];
  }

  /// 音乐侧全部艺人行。
  Future<List<MusicArtistRow>> allMusicArtists() => select(musicArtists).get();

  // ── 人物页明细 ──────────────────────────────────────────────────

  /// 这些人物的全部视频 credit（作品 / 季 / 集三级都在内）。
  Future<List<VideoMetadataCreditRow>> videoCreditsForPeople(
    Set<String> personKeys,
  ) {
    if (personKeys.isEmpty) {
      return Future<List<VideoMetadataCreditRow>>.value(
        const <VideoMetadataCreditRow>[],
      );
    }
    return (select(videoMetadataCredits)
          ..where((VideoMetadataCredits t) => t.personKey.isIn(personKeys))
          ..orderBy(<OrderClauseGenerator<VideoMetadataCredits>>[
            (VideoMetadataCredits t) => OrderingTerm.asc(t.sortOrder),
          ]))
        .get();
  }

  Future<List<VideoMetadataCharacterRow>> videoCharactersByKeys(
    Set<String> keys,
  ) {
    if (keys.isEmpty) {
      return Future<List<VideoMetadataCharacterRow>>.value(
        const <VideoMetadataCharacterRow>[],
      );
    }
    return (select(
      videoMetadataCharacters,
    )..where((VideoMetadataCharacters t) => t.characterKey.isIn(keys))).get();
  }

  Future<List<VideoMetadataPersonRow>> videoPeopleByKeys(Set<String> keys) {
    if (keys.isEmpty) {
      return Future<List<VideoMetadataPersonRow>>.value(
        const <VideoMetadataPersonRow>[],
      );
    }
    return (select(
      videoMetadataPeople,
    )..where((VideoMetadataPeople t) => t.personKey.isIn(keys))).get();
  }

  /// credit 挂在季 / 集上时换算到作品：季 id → 作品 id。
  Future<Map<int, int>> videoWorkIdsForSeasons(Set<int> seasonIds) async {
    if (seasonIds.isEmpty) return const <int, int>{};
    final List<VideoMetadataSeasonRow> rows = await (select(
      videoMetadataSeasons,
    )..where((VideoMetadataSeasons t) => t.id.isIn(seasonIds))).get();
    return <int, int>{
      for (final VideoMetadataSeasonRow r in rows) r.id: r.workId,
    };
  }

  /// 集 id → 作品 id（经季）。
  Future<Map<int, int>> videoWorkIdsForEpisodes(Set<int> episodeIds) async {
    if (episodeIds.isEmpty) return const <int, int>{};
    final List<VideoMetadataEpisodeRow> rows = await (select(
      videoMetadataEpisodes,
    )..where((VideoMetadataEpisodes t) => t.id.isIn(episodeIds))).get();
    final Map<int, int> seasonOf = <int, int>{
      for (final VideoMetadataEpisodeRow r in rows) r.id: r.seasonId,
    };
    final Map<int, int> workOfSeason = await videoWorkIdsForSeasons(
      seasonOf.values.toSet(),
    );
    return <int, int>{
      for (final MapEntry<int, int> e in seasonOf.entries)
        if (workOfSeason[e.value] case final int work) e.key: work,
    };
  }

  Future<List<VideoMetadataWorkRow>> videoWorksByIds(Set<int> ids) {
    if (ids.isEmpty) {
      return Future<List<VideoMetadataWorkRow>>.value(
        const <VideoMetadataWorkRow>[],
      );
    }
    return (select(
      videoMetadataWorks,
    )..where((VideoMetadataWorks t) => t.id.isIn(ids))).get();
  }

  /// 这些艺人的全部曲目署名（任意角色）。
  Future<List<MusicTrackCreditRow>> musicCreditsForArtists(
    Set<String> artistUids,
  ) {
    if (artistUids.isEmpty) {
      return Future<List<MusicTrackCreditRow>>.value(
        const <MusicTrackCreditRow>[],
      );
    }
    return (select(
      musicTrackCredits,
    )..where((MusicTrackCredits t) => t.artistUid.isIn(artistUids))).get();
  }

  /// 一首或多首曲目的全部署名连同艺人行，按 `ord`。
  Future<List<MusicCreditWithArtist>> musicCreditsForTracks(
    Set<String> trackUids,
  ) async {
    if (trackUids.isEmpty) return const <MusicCreditWithArtist>[];
    final List<TypedResult> rows =
        await (select(musicTrackCredits).join(<Join>[
                innerJoin(
                  musicArtists,
                  musicArtists.artistUid.equalsExp(musicTrackCredits.artistUid),
                ),
              ])
              ..where(musicTrackCredits.trackUid.isIn(trackUids))
              ..orderBy(<OrderingTerm>[
                OrderingTerm.asc(musicTrackCredits.trackUid),
                OrderingTerm.asc(musicTrackCredits.ord),
              ]))
            .get();
    return <MusicCreditWithArtist>[
      for (final TypedResult r in rows)
        (
          credit: r.readTable(musicTrackCredits),
          artist: r.readTable(musicArtists),
        ),
    ];
  }

  // ── 动画 ↔ 原作进度对应点 ────────────────────────────────────────

  /// 一对端点的全部对应点，按集号升序。
  Future<List<AdaptationProgressAnchorRow>> adaptationProgressAnchorsFor(
    AdaptationProgressPair pair,
  ) =>
      (select(adaptationProgressAnchors)
            ..where(
              (AdaptationProgressAnchors t) =>
                  t.sourceKind.equals(pair.sourceKind) &
                  t.sourceKey.equals(pair.sourceKey) &
                  t.adaptationKind.equals(pair.adaptationKind) &
                  t.adaptationKey.equals(pair.adaptationKey),
            )
            ..orderBy(<OrderClauseGenerator<AdaptationProgressAnchors>>[
              (AdaptationProgressAnchors t) =>
                  OrderingTerm.asc(t.episodeNumber),
            ]))
          .get();

  /// 写一个对应点（同集号覆盖）。
  Future<void> upsertAdaptationProgressAnchor(
    AdaptationProgressAnchorsCompanion row,
  ) => into(adaptationProgressAnchors).insertOnConflictUpdate(row);

  /// 删一个对应点。
  Future<int> deleteAdaptationProgressAnchor(
    AdaptationProgressPair pair,
    int episodeNumber,
  ) =>
      (delete(adaptationProgressAnchors)..where(
            (AdaptationProgressAnchors t) =>
                t.sourceKind.equals(pair.sourceKind) &
                t.sourceKey.equals(pair.sourceKey) &
                t.adaptationKind.equals(pair.adaptationKind) &
                t.adaptationKey.equals(pair.adaptationKey) &
                t.episodeNumber.equals(episodeNumber),
          ))
          .go();
}

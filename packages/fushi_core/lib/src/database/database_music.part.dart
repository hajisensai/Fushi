// 音乐曲库（v130，docs/specs/2026-10-23-music-module-design.md §10）：扫描批次落库、
// 软删消失的文件、曲库页查询、播放流。表语义见 music_tables.dart。
part of 'database.dart';

/// 一次扫描批次要落库的全部行（由 Rust 扫描结果在 Dart 侧换算成 companion）。
class MusicScanBatchWrite {
  const MusicScanBatchWrite({
    required this.tracks,
    required this.albums,
    required this.artists,
    required this.credits,
  });

  final List<MusicTracksCompanion> tracks;
  final List<MusicAlbumsCompanion> albums;
  final List<MusicArtistsCompanion> artists;
  final List<MusicTrackCreditsCompanion> credits;
}

/// 归组读出的一首曲目（[_FushiDbMusic._musicGroupingRows]）：[group] 是（来源, 目录,
/// 专辑名键），[origin] 是原始归属（[MusicTracks.scanAlbumUid]，NULL 时取生效专辑），
/// [artist] 是原始专辑的专辑艺人比较键（没写为 null）。
typedef _MusicGroupingRow = ({
  String trackUid,
  String group,
  String? albumUid,
  String origin,
  String? artist,
});

mixin _FushiDbMusic on _$FushiDatabase {
  Future<void> _ensureMusicIndexes() async {
    const List<String> stmts = <String>[
      'CREATE INDEX IF NOT EXISTS idx_music_tracks_album '
          'ON music_tracks (album_uid, disc_no, track_no)',
      'CREATE INDEX IF NOT EXISTS idx_music_tracks_source '
          'ON music_tracks (source_id)',
      'CREATE INDEX IF NOT EXISTS idx_music_tracks_path '
          'ON music_tracks (path)',
      'CREATE INDEX IF NOT EXISTS idx_music_track_credits_artist '
          'ON music_track_credits (artist_uid, role)',
      'CREATE INDEX IF NOT EXISTS idx_music_playlist_entries_playlist '
          'ON music_playlist_entries (playlist_uid, position)',
      'CREATE INDEX IF NOT EXISTS idx_music_play_events_track '
          'ON music_play_events (track_uid, started_at)',
      'CREATE INDEX IF NOT EXISTS idx_music_play_events_started '
          'ON music_play_events (started_at)',
    ];
    for (final String stmt in stmts) {
      await customStatement(stmt);
    }
  }

  /// v145 的 path_key 索引。不进 [_ensureMusicIndexes]：早期迁移步（v130 / `from < 132`
  /// 补跑）会在列还不存在时调用它（同 v81 uid 索引的做法）。
  Future<void> _ensureMusicPathKeyIndex() => customStatement(
    'CREATE INDEX IF NOT EXISTS idx_music_tracks_path_key '
    'ON music_tracks (path_key)',
  );

  /// 一个扫描批次整批 upsert（一个事务）。曲目重新出现时清掉软删标记——用户「从音乐库
  /// 移除」的行（[MusicTracks.hiddenAt]）除外：那是墓碑，这一行整行不动、不复活；
  /// [MusicTracks.addedAt] 只在首次插入时写（冲突更新不覆盖入库时刻）。
  /// 一首曲目的署名整组替换：先删该曲目全部旧署名再插新的（标签里删掉的艺人要消失）。
  ///
  /// 落库前按 [MusicTracks.pathKey] 认出库里已有的同一个文件（`database_music_identity`）：
  /// 传入 uid 不在库里、但库里有同一文件的行，就沿用那一行的 uid（与专辑），并把路径
  /// 改写成这次扫到的拼法。返回 传入 uid → 实际落库 uid 的改写表（没改写的不在里面），
  /// 扫描器据此记「本次见到的曲目」，否则沿用的旧行会在收尾时被当成消失软删。
  Future<Map<String, String>> writeMusicScanBatch(
    MusicScanBatchWrite incoming,
  ) => transaction(() async {
    final MusicScanUidRemap remap = await _remapScannedMusicTracks(
      this,
      incoming.tracks,
    );
    final MusicScanBatchWrite batch = _applyScanUidRemap(incoming, remap);
    for (final MusicArtistsCompanion artist in batch.artists) {
      await into(musicArtists).insert(
        artist,
        onConflict: DoUpdate<$MusicArtistsTable, MusicArtistRow>(
          (_) => MusicArtistsCompanion(
            name: artist.name,
            sortName: artist.sortName,
          ),
        ),
      );
    }
    for (final MusicAlbumsCompanion album in batch.albums) {
      await into(musicAlbums).insert(
        album,
        onConflict: DoUpdate<$MusicAlbumsTable, MusicAlbumRow>(
          (_) => MusicAlbumsCompanion(
            title: album.title,
            titleSort: album.titleSort,
            albumArtistCredit: album.albumArtistCredit,
            releaseDate: album.releaseDate,
            catalogNo: album.catalogNo,
            totalDiscs: album.totalDiscs,
            coverPath: album.coverPath,
            coverTrackUid: album.coverTrackUid,
            mbReleaseId: album.mbReleaseId,
            mbReleaseGroupId: album.mbReleaseGroupId,
            updatedAt: album.updatedAt,
          ),
        ),
      );
    }
    final Map<int, Set<String>> touchedDirs = <int, Set<String>>{};
    for (final MusicTracksCompanion raw in batch.tracks) {
      final String pathKey = musicTrackPathKey(raw.path.value);
      // 落库值是按标签算的原始归属：生效专辑与原始归属同值落下，归组在本事务末尾按
      // 受影响目录重算。
      final MusicTracksCompanion track = raw.copyWith(
        pathKey: Value<String?>(pathKey),
        scanAlbumUid: raw.albumUid,
      );
      if (raw.sourceId.present && raw.sourceId.value != null) {
        if (musicTrackDirPrefix(pathKey) case final String dir) {
          touchedDirs
              .putIfAbsent(raw.sourceId.value!, () => <String>{})
              .add(dir);
        }
      }
      await into(musicTracks).insert(
        track,
        onConflict: DoUpdate<$MusicTracksTable, MusicTrackRow>(
          (_) => track.copyWith(
            addedAt: const Value<int>.absent(),
            deletedAt: const Value<int?>(null),
          ),
          // 用户移除过的曲目（墓碑）：重扫见到文件也不复活。
          where: ($MusicTracksTable old) => old.hiddenAt.isNull(),
        ),
      );
    }
    final Set<String> creditedTracks = <String>{
      for (final MusicTracksCompanion t in batch.tracks) t.trackUid.value,
    };
    if (creditedTracks.isNotEmpty) {
      await (delete(musicTrackCredits)..where(
            ($MusicTrackCreditsTable t) => t.trackUid.isIn(creditedTracks),
          ))
          .go();
    }
    for (final MusicTrackCreditsCompanion credit in batch.credits) {
      await into(musicTrackCredits).insertOnConflictUpdate(credit);
    }
    // 标签里没有 MBID 的文件刚被按标签冲回 NULL：把识别身份（v133 刮削结论）重放上去。
    if (creditedTracks.isNotEmpty) {
      await _reapplyMusicScrapeOverlaySql(this, creditedTracks.toList());
    }
    await _regroupMusicAlbumDirs(touchedDirs);
    return remap.tracks;
  });

  /// 扫描收尾：来源 [sourceId] 下本次没见到的曲目（uid 不在 [seenTrackUids]）软删，
  /// 同一事务里在这些曲目所在的目录上重算专辑归组（[_regroupMusicAlbumDirs]：带专辑
  /// 艺人的文件没了，同一张盘没写艺人的曲目要退回原专辑）。返回新软删的行数。
  Future<int> softDeleteMissingMusicTracks({
    required int sourceId,
    required Set<String> seenTrackUids,
    required int deletedAt,
  }) async {
    final List<({String uid, String pathKey})> live =
        await (selectOnly(musicTracks)
              ..addColumns(<Expression<Object>>[
                musicTracks.trackUid,
                musicTracks.path,
                musicTracks.pathKey,
              ])
              ..where(
                musicTracks.sourceId.equals(sourceId) &
                    musicTracks.deletedAt.isNull(),
              ))
            .map(
              (TypedResult r) => (
                uid: r.read(musicTracks.trackUid)!,
                pathKey:
                    r.read(musicTracks.pathKey) ??
                    musicTrackPathKey(r.read(musicTracks.path)!),
              ),
            )
            .get();
    final List<({String uid, String pathKey})> missing = live
        .where(
          (({String uid, String pathKey}) t) => !seenTrackUids.contains(t.uid),
        )
        .toList();
    if (missing.isEmpty) return 0;
    return transaction(() async {
      int total = 0;
      for (int i = 0; i < missing.length; i += 500) {
        final List<String> chunk = <String>[
          for (final ({String uid, String pathKey}) t in missing.sublist(
            i,
            (i + 500).clamp(0, missing.length),
          ))
            t.uid,
        ];
        total +=
            await (update(musicTracks)
                  ..where(($MusicTracksTable t) => t.trackUid.isIn(chunk)))
                .write(MusicTracksCompanion(deletedAt: Value<int?>(deletedAt)));
      }
      await _regroupMusicAlbumDirs(<int, Set<String>>{
        sourceId: <String>{
          for (final ({String uid, String pathKey}) t in missing)
            ?musicTrackDirPrefix(t.pathKey),
        },
      });
      return total;
    });
  }

  /// 同一张 CD 因专辑艺人标签不齐被拆开时并回一张（BUG-5164），只在 [dirsBySource]
  /// （来源 id → 目录前缀，见 [musicTrackDirPrefix]）这些目录上按当前在库状态重算。
  ///
  /// 专辑 uid 由 Rust 按单首曲目算（`native/fushi_music` `uid.rs` 的 `album_uid`）：有专辑
  /// 艺人按（艺人, 专辑名），没有就按（目录, 专辑名）。一张 CD 只有部分曲目写了专辑艺人
  /// 时同一张盘被拆成两个 uid。Rust 一次只看一个文件，增量扫描时没变的文件也不重读标签，
  /// 所以归组放在落库这一层、按在库状态算：同一来源、同一目录、同名（[musicAlbumNameKey]）
  /// 的曲目里，按原始归属（[MusicTracks.scanAlbumUid]）带专辑艺人的恰好只有一位艺人时，
  /// 没写专辑艺人的曲目生效专辑（[MusicTracks.albumUid]）指向带艺人的那张；否则（多位
  /// 艺人是真不同的专辑、一位都没有）一律退回原始归属。原始归属从不被归组改写，所以组里
  /// 艺人变了（HBK-AUDIT-027：新加第二位艺人的同名专辑、带艺人的文件删了）只要重算这个
  /// 目录就能退回，不依赖重新解析没变的文件。
  ///
  /// 判据用的是还在磁盘上的曲目：未软删的，加上用户「从音乐库移除」的墓碑（文件还在、
  /// 标签照旧，隐藏它不该让同一张盘的其它曲目换专辑）。返回改了生效专辑的曲目数。
  Future<int> _regroupMusicAlbumDirs(Map<int, Set<String>> dirsBySource) async {
    int changed = 0;
    for (final MapEntry<int, Set<String>> source in dirsBySource.entries) {
      for (final String prefix in source.value) {
        changed += await _applyMusicAlbumGrouping(
          await _musicGroupingRows(sourceId: source.key, dirPrefix: prefix),
        );
      }
    }
    return changed;
  }

  /// 全部来源整库归组一次（v167 迁移：存量里 BUG-5164 拆开的专辑并回去）。日常扫描只走
  /// [_regroupMusicAlbumDirs]。返回改了生效专辑的曲目数。
  Future<int> regroupAllMusicAlbums() async =>
      _applyMusicAlbumGrouping(await _musicGroupingRows());

  /// 归组要的行：曲目 uid / 来源 / 路径键 / 生效与原始专辑 + 原始专辑的名字与专辑艺人。
  /// 只列用到的列（`selectOnly`）：迁移阶梯里调用时后续版本才加的列还不存在。
  /// [dirPrefix] 给了就只读这个目录（路径键区间走 `idx_music_tracks_path_key`，再排除
  /// 子目录），否则读 [sourceId]（为 null 时全部来源）。
  Future<List<_MusicGroupingRow>> _musicGroupingRows({
    int? sourceId,
    String? dirPrefix,
  }) async {
    final Expression<String> origin = coalesce<String>(<Expression<String>>[
      musicTracks.scanAlbumUid,
      musicTracks.albumUid,
    ]);
    final JoinedSelectStatement<HasResultSet, dynamic> q =
        selectOnly(musicTracks).join(<Join>[
          leftOuterJoin(musicAlbums, musicAlbums.albumUid.equalsExp(origin)),
        ])..addColumns(<Expression<Object>>[
          musicTracks.trackUid,
          musicTracks.sourceId,
          musicTracks.path,
          musicTracks.pathKey,
          musicTracks.albumUid,
          origin,
          musicAlbums.title,
          musicAlbums.albumArtistCredit,
        ]);
    Expression<bool> where =
        (musicTracks.deletedAt.isNull() | musicTracks.hiddenAt.isNotNull()) &
        origin.isNotNull();
    where &= sourceId == null
        ? musicTracks.sourceId.isNotNull()
        : musicTracks.sourceId.equals(sourceId);
    if (dirPrefix != null) {
      final int last = dirPrefix.codeUnitAt(dirPrefix.length - 1);
      final String upper =
          dirPrefix.substring(0, dirPrefix.length - 1) +
          String.fromCharCode(last + 1);
      final Expression<String> rest = musicTracks.pathKey.substrExpr(
        Variable<String>(dirPrefix).length + const Constant<int>(1),
      );
      where &=
          musicTracks.pathKey.isBiggerOrEqualValue(dirPrefix) &
          musicTracks.pathKey.isSmallerThanValue(upper) &
          rest.like('%/%').not() &
          rest.like(r'%\%').not();
    }
    q.where(where);
    return <_MusicGroupingRow>[
      for (final TypedResult r in await q.get())
        if (musicTrackDirPrefix(
              r.read(musicTracks.pathKey) ??
                  musicTrackPathKey(r.read(musicTracks.path)!),
            )
            case final String dir)
          (
            trackUid: r.read(musicTracks.trackUid)!,
            group:
                '${r.read(musicTracks.sourceId)}\u0000$dir\u0000'
                '${musicAlbumNameKey(r.read(musicAlbums.title) ?? '')}',
            albumUid: r.read(musicTracks.albumUid),
            origin: r.read(origin)!,
            artist: switch (r.read(musicAlbums.albumArtistCredit)?.trim()) {
              final String a when a.isNotEmpty => musicAlbumNameKey(a),
              _ => null,
            },
          ),
    ];
  }

  /// 按 [_regroupMusicAlbumDirs] 的规则算每首的生效专辑，只写和现值不同的行。
  Future<int> _applyMusicAlbumGrouping(List<_MusicGroupingRow> rows) async {
    final Map<String, List<_MusicGroupingRow>> groups =
        <String, List<_MusicGroupingRow>>{};
    for (final _MusicGroupingRow r in rows) {
      groups.putIfAbsent(r.group, () => <_MusicGroupingRow>[]).add(r);
    }
    // 生效专辑 → 要改成它的曲目。
    final Map<String, List<String>> moves = <String, List<String>>{};
    for (final List<_MusicGroupingRow> members in groups.values) {
      final Map<String, String> tagged = <String, String>{
        for (final _MusicGroupingRow m in members)
          if (m.artist case final String a) a: m.origin,
      };
      final String? target = tagged.length == 1 ? tagged.values.single : null;
      for (final _MusicGroupingRow m in members) {
        final String want = m.artist == null && target != null
            ? target
            : m.origin;
        if (want != m.albumUid) {
          moves.putIfAbsent(want, () => <String>[]).add(m.trackUid);
        }
      }
    }
    if (moves.isEmpty) return 0;
    return transaction(() async {
      int total = 0;
      for (final MapEntry<String, List<String>> m in moves.entries) {
        for (int i = 0; i < m.value.length; i += 500) {
          final List<String> chunk = m.value.sublist(
            i,
            (i + 500).clamp(0, m.value.length),
          );
          total +=
              await (update(musicTracks)
                    ..where(($MusicTracksTable t) => t.trackUid.isIn(chunk)))
                  .write(MusicTracksCompanion(albumUid: Value<String?>(m.key)));
        }
      }
      return total;
    });
  }

  /// 来源 [sourceId] 下在库曲目的（路径, 修改时刻, 大小, uid）。扫描器据此告诉 Rust
  /// 哪些文件没变（跳过标签解析），以及「没变的文件」对应哪些曲目 uid（一个 CUE 整轨
  /// 对应多首）。用户移除（[MusicTracks.hiddenAt]）的曲目也算：文件还在、没动过就不必
  /// 每次重扫都重新解析一遍。
  Future<List<({String path, int mtimeAt, int size, String trackUid})>>
  musicTrackFilesOfSource(int sourceId) async {
    final List<MusicTrackRow> rows =
        await (select(musicTracks)..where(
              ($MusicTracksTable t) =>
                  t.sourceId.equals(sourceId) &
                  (t.deletedAt.isNull() | t.hiddenAt.isNotNull()),
            ))
            .get();
    return <({String path, int mtimeAt, int size, String trackUid})>[
      for (final MusicTrackRow r in rows)
        (
          path: r.path,
          mtimeAt: r.fileMtimeAt,
          size: r.fileSize,
          trackUid: r.trackUid,
        ),
    ];
  }

  /// 需要 EBU R128 现扫的在库曲目（设计 §7.3）：标签里没有曲目增益、也还没扫过。
  Future<List<MusicTrackRow>> listMusicTracksNeedingLoudnessScan({
    int limit = 200,
  }) =>
      (select(musicTracks)
            ..where(
              ($MusicTracksTable t) =>
                  t.deletedAt.isNull() &
                  t.rgTrackGain.isNull() &
                  t.r128ScannedAt.isNull(),
            )
            ..orderBy(<OrderingTerm Function($MusicTracksTable)>[
              ($MusicTracksTable t) => OrderingTerm(expression: t.addedAt),
            ])
            ..limit(limit))
          .get();

  /// 写一首曲目的扫描结果。[gain] / [peak] 为 null = 扫过但测不出（静音 / 解码失败），
  /// 照样记 [scannedAt]，文件变了（重扫时会清掉这个时刻）之前不再重试。只写标签没给的列。
  Future<void> writeMusicTrackLoudness(
    String trackUid, {
    required double? gain,
    required double? peak,
    required int scannedAt,
  }) =>
      (update(musicTracks)..where(
            ($MusicTracksTable t) =>
                t.trackUid.equals(trackUid) & t.rgTrackGain.isNull(),
          ))
          .write(
            MusicTracksCompanion(
              rgTrackGain: Value<double?>(gain),
              rgTrackPeak: Value<double?>(peak),
              r128ScannedAt: Value<int?>(scannedAt),
            ),
          );

  /// 专辑增益补齐：只写该专辑里专辑增益为空的在库曲目（标签带的专辑增益不覆盖）。
  Future<int> writeMusicAlbumLoudness(
    String albumUid, {
    required double gain,
    required double? peak,
  }) =>
      (update(musicTracks)..where(
            ($MusicTracksTable t) =>
                t.albumUid.equals(albumUid) &
                t.deletedAt.isNull() &
                t.rgAlbumGain.isNull(),
          ))
          .write(
            MusicTracksCompanion(
              rgAlbumGain: Value<double?>(gain),
              rgAlbumPeak: Value<double?>(peak),
            ),
          );

  /// 软删一首曲目（远端删除标记 / 用户从曲库移除；不碰磁盘文件）。
  Future<void> softDeleteMusicTrack(
    String trackUid, {
    required int deletedAt,
  }) =>
      (update(musicTracks)..where(
            ($MusicTracksTable t) =>
                t.trackUid.equals(trackUid) & t.deletedAt.isNull(),
          ))
          .write(MusicTracksCompanion(deletedAt: Value<int?>(deletedAt)));

  /// 用户「从音乐库移除」本地曲目（拍板台 IDeN5PYaI7）：写墓碑 [MusicTracks.hiddenAt]
  /// 并软删，不碰磁盘文件；之后重扫见到同一个文件也不复活（`writeMusicScanBatch`）。
  /// 已经移除过的不重写时刻。返回这次新移除的曲目数。
  Future<int> hideMusicTracks(Iterable<String> trackUids, {required int at}) {
    final List<String> uids = trackUids.toSet().toList();
    if (uids.isEmpty) return Future<int>.value(0);
    return transaction(() async {
      int total = 0;
      for (int i = 0; i < uids.length; i += 500) {
        final List<String> chunk = uids.sublist(
          i,
          (i + 500).clamp(0, uids.length),
        );
        total +=
            await (update(musicTracks)..where(
                  ($MusicTracksTable t) =>
                      t.trackUid.isIn(chunk) & t.hiddenAt.isNull(),
                ))
                .write(
                  MusicTracksCompanion(
                    hiddenAt: Value<int?>(at),
                    deletedAt: Value<int?>(at),
                  ),
                );
      }
      return total;
    });
  }

  /// 恢复用户移除过的曲目（[hideMusicTracks] 的逆操作）：清墓碑与软删标记。文件已经
  /// 不在的，下一次重扫照常软删。只动确实被移除过的行，返回恢复的曲目数。
  Future<int> unhideMusicTracks(Iterable<String> trackUids) {
    final List<String> uids = trackUids.toSet().toList();
    if (uids.isEmpty) return Future<int>.value(0);
    return transaction(() async {
      int total = 0;
      for (int i = 0; i < uids.length; i += 500) {
        final List<String> chunk = uids.sublist(
          i,
          (i + 500).clamp(0, uids.length),
        );
        total +=
            await (update(musicTracks)..where(
                  ($MusicTracksTable t) =>
                      t.trackUid.isIn(chunk) & t.hiddenAt.isNotNull(),
                ))
                .write(
                  const MusicTracksCompanion(
                    hiddenAt: Value<int?>(null),
                    deletedAt: Value<int?>(null),
                  ),
                );
      }
      return total;
    });
  }

  /// 用户移除过的曲目（[hideMusicTracks]），最近移除的在前。
  Stream<List<MusicTrackRow>> watchHiddenMusicTracks() =>
      (select(musicTracks)
            ..where(($MusicTracksTable t) => t.hiddenAt.isNotNull())
            ..orderBy(<OrderingTerm Function($MusicTracksTable)>[
              ($MusicTracksTable t) =>
                  OrderingTerm(expression: t.hiddenAt, mode: OrderingMode.desc),
              ($MusicTracksTable t) => OrderingTerm(expression: t.title),
            ]))
          .watch();

  /// 曲库里的全部在库曲目（软删除外），按专辑 / 碟号 / 轨号 / 标题排序。
  Future<List<MusicTrackRow>> listMusicTracks({String? albumUid}) {
    final SimpleSelectStatement<$MusicTracksTable, MusicTrackRow> q = select(
      musicTracks,
    )..where(($MusicTracksTable t) => t.deletedAt.isNull());
    if (albumUid != null) {
      q.where(($MusicTracksTable t) => t.albumUid.equals(albumUid));
    }
    q.orderBy(<OrderingTerm Function($MusicTracksTable)>[
      ($MusicTracksTable t) => OrderingTerm(expression: t.albumUid),
      ($MusicTracksTable t) => OrderingTerm(expression: t.discNo),
      ($MusicTracksTable t) => OrderingTerm(expression: t.trackNo),
      ($MusicTracksTable t) => OrderingTerm(expression: t.title),
    ]);
    return q.get();
  }

  Future<MusicTrackRow?> getMusicTrack(String trackUid) =>
      (select(musicTracks)
            ..where(($MusicTracksTable t) => t.trackUid.equals(trackUid)))
          .getSingleOrNull();

  /// 至少有一首在库曲目的专辑，以及光盘专辑（盘加进曲库、章节还没导入时也要能看到它，
  /// 「章节导入为曲目」的入口就在这张专辑上），按标题排序。
  Future<List<MusicAlbumRow>> listMusicAlbums() {
    final Expression<bool> hasLiveTrack = existsQuery(
      select(musicTracks)..where(
        ($MusicTracksTable t) =>
            t.albumUid.equalsExp(musicAlbums.albumUid) & t.deletedAt.isNull(),
      ),
    );
    return (select(musicAlbums)
          ..where(($MusicAlbumsTable t) => hasLiveTrack | t.discUid.isNotNull())
          ..orderBy(<OrderingTerm Function($MusicAlbumsTable)>[
            ($MusicAlbumsTable t) => OrderingTerm(
              expression: coalesce(<Expression<String>>[t.titleSort, t.title]),
            ),
          ]))
        .get();
  }

  Future<MusicAlbumRow?> getMusicAlbum(String albumUid) =>
      (select(musicAlbums)
            ..where(($MusicAlbumsTable t) => t.albumUid.equals(albumUid)))
          .getSingleOrNull();

  /// 以 [role]（默认曲目艺人）出现在至少一首在库曲目里的艺人，按排序名。
  Future<List<MusicArtistRow>> listMusicArtists({
    Set<String> roles = const <String>{'artist', 'album_artist'},
  }) {
    final Expression<bool> credited = existsQuery(
      select(musicTrackCredits).join(<Join>[
        innerJoin(
          musicTracks,
          musicTracks.trackUid.equalsExp(musicTrackCredits.trackUid) &
              musicTracks.deletedAt.isNull(),
        ),
      ])..where(
        musicTrackCredits.artistUid.equalsExp(musicArtists.artistUid) &
            musicTrackCredits.role.isIn(roles),
      ),
    );
    return (select(musicArtists)
          ..where((_) => credited)
          ..orderBy(<OrderingTerm Function($MusicArtistsTable)>[
            ($MusicArtistsTable t) => OrderingTerm(
              expression: coalesce(<Expression<String>>[t.sortName, t.name]),
            ),
          ]))
        .get();
  }

  /// 某艺人署名（[roles]）的在库曲目。
  Future<List<MusicTrackRow>> listMusicTracksByArtist(
    String artistUid, {
    Set<String> roles = const <String>{'artist', 'album_artist'},
  }) async {
    final List<TypedResult> rows =
        await (select(musicTracks).join(<Join>[
                innerJoin(
                  musicTrackCredits,
                  musicTrackCredits.trackUid.equalsExp(musicTracks.trackUid),
                ),
              ])
              ..where(
                musicTrackCredits.artistUid.equals(artistUid) &
                    musicTrackCredits.role.isIn(roles) &
                    musicTracks.deletedAt.isNull(),
              )
              ..orderBy(<OrderingTerm>[
                OrderingTerm(expression: musicTracks.albumUid),
                OrderingTerm(expression: musicTracks.discNo),
                OrderingTerm(expression: musicTracks.trackNo),
              ]))
            .get();
    final Map<String, MusicTrackRow> unique = <String, MusicTrackRow>{};
    for (final TypedResult r in rows) {
      final MusicTrackRow t = r.readTable(musicTracks);
      unique.putIfAbsent(t.trackUid, () => t);
    }
    return unique.values.toList();
  }

  // ── 光盘专辑（音乐方案 §9.2：演唱会 / MV 合集 DVD·BD 的章节导入为曲目）──

  Future<MusicDiscSourceRow?> getMusicDiscSource(String discUid) =>
      (select(musicDiscSources)
            ..where(($MusicDiscSourcesTable t) => t.discUid.equals(discUid)))
          .getSingleOrNull();

  Future<List<MusicDiscSourceRow>> listMusicDiscSources() =>
      select(musicDiscSources).get();

  /// 把一张盘登记成曲库里的专辑（还没导入章节）。盘已登记时只更新路径 / 卷标（同一张盘
  /// 挪了目录），专辑标题等用户可能改过的不动。
  Future<void> registerMusicDisc({
    required MusicAlbumsCompanion album,
    required MusicDiscSourcesCompanion disc,
  }) => transaction(() async {
    await into(musicDiscSources).insert(
      disc,
      onConflict: DoUpdate<$MusicDiscSourcesTable, MusicDiscSourceRow>(
        (_) => MusicDiscSourcesCompanion(
          path: disc.path,
          volumeId: disc.volumeId,
          hasMenu: disc.hasMenu,
        ),
      ),
    );
    await into(musicAlbums).insert(
      album,
      onConflict: DoUpdate<$MusicAlbumsTable, MusicAlbumRow>(
        (_) => MusicAlbumsCompanion(discUid: album.discUid),
      ),
    );
  });

  /// 一次「章节导入为曲目」整体落库（一个事务）：专辑 / 光盘来源 upsert，曲目 upsert（重新
  /// 导入时清软删标记、不改入库时刻，**也不改已有曲目的标题 / 艺人 / 录音 MBID**——那是
  /// MusicBrainz 结论或用户改过的名字，重新导入只更新盘上的事实：路径、起止、时长、序号），
  /// 这张专辑上一轮导入、这一轮没选的曲目软删（歌单 / 播放记录仍能解析到行）。
  Future<void> writeMusicDiscImport({
    required MusicAlbumsCompanion album,
    required MusicDiscSourcesCompanion disc,
    required List<MusicTracksCompanion> tracks,
    required int deletedAt,
  }) => transaction(() async {
    await into(musicDiscSources).insertOnConflictUpdate(disc);
    // 已有的专辑行只认领光盘来源、刷新时刻：标题 / 艺人 / 封面可能是 MusicBrainz 结论。
    await into(musicAlbums).insert(
      album,
      onConflict: DoUpdate<$MusicAlbumsTable, MusicAlbumRow>(
        (_) => MusicAlbumsCompanion(
          discUid: album.discUid,
          updatedAt: album.updatedAt,
        ),
      ),
    );
    final String albumUid = album.albumUid.value;
    final Set<String> keep = <String>{
      for (final MusicTracksCompanion t in tracks) t.trackUid.value,
    };
    for (final MusicTracksCompanion track in tracks) {
      await into(musicTracks).insert(
        track,
        onConflict: DoUpdate<$MusicTracksTable, MusicTrackRow>(
          (_) => track.copyWith(
            addedAt: const Value<int>.absent(),
            title: const Value<String>.absent(),
            artistCredit: const Value<String?>.absent(),
            mbRecordingId: const Value<String?>.absent(),
            deletedAt: const Value<int?>(null),
            // 用户显式选了这些章节导入：移除过的也恢复。
            hiddenAt: const Value<int?>(null),
          ),
        ),
      );
    }
    await (update(musicTracks)..where(
          ($MusicTracksTable t) =>
              t.albumUid.equals(albumUid) &
              t.deletedAt.isNull() &
              t.trackUid.isNotIn(keep),
        ))
        .write(MusicTracksCompanion(deletedAt: Value<int?>(deletedAt)));
    if (keep.isNotEmpty) {
      await _reapplyMusicScrapeOverlaySql(this, keep.toList());
    }
  });

  /// 读一张音频 CD 落库（一个事务）：这是用户显式「重新读盘 / 识别」，专辑与曲目的名字
  /// 按这一次的结论整行覆盖（入库时刻不动、软删标记清掉）。
  Future<void> writeMusicAudioCd({
    required MusicAlbumsCompanion album,
    required MusicDiscSourcesCompanion disc,
    required List<MusicTracksCompanion> tracks,
  }) => transaction(() async {
    await into(musicDiscSources).insert(
      disc,
      onConflict: DoUpdate<$MusicDiscSourcesTable, MusicDiscSourceRow>(
        (_) => disc.copyWith(addedAt: const Value<int>.absent()),
      ),
    );
    await into(musicAlbums).insert(
      album,
      onConflict: DoUpdate<$MusicAlbumsTable, MusicAlbumRow>(
        (_) => album.copyWith(addedAt: const Value<int>.absent()),
      ),
    );
    for (final MusicTracksCompanion track in tracks) {
      await into(musicTracks).insert(
        track,
        onConflict: DoUpdate<$MusicTracksTable, MusicTrackRow>(
          (_) => track.copyWith(
            addedAt: const Value<int>.absent(),
            deletedAt: const Value<int?>(null),
            // 用户显式重新读盘：移除过的曲目也恢复。
            hiddenAt: const Value<int?>(null),
          ),
        ),
      );
    }
    if (tracks.isNotEmpty) {
      await _reapplyMusicScrapeOverlaySql(this, <String>[
        for (final MusicTracksCompanion t in tracks) t.trackUid.value,
      ]);
    }
  });

  /// 从曲库移除一张盘：光盘来源与专辑行删掉，它的曲目软删（歌单 / 播放记录仍能解析）。
  Future<void> removeMusicDisc({
    required String discUid,
    required int deletedAt,
  }) => transaction(() async {
    final List<String> albums =
        await (selectOnly(musicAlbums)
              ..addColumns(<Expression<Object>>[musicAlbums.albumUid])
              ..where(musicAlbums.discUid.equals(discUid)))
            .map((TypedResult r) => r.read(musicAlbums.albumUid)!)
            .get();
    if (albums.isNotEmpty) {
      await (update(musicTracks)..where(
            ($MusicTracksTable t) =>
                t.albumUid.isIn(albums) & t.deletedAt.isNull(),
          ))
          .write(MusicTracksCompanion(deletedAt: Value<int?>(deletedAt)));
      await (delete(
        musicAlbums,
      )..where(($MusicAlbumsTable t) => t.albumUid.isIn(albums))).go();
    }
    await (delete(
      musicDiscSources,
    )..where(($MusicDiscSourcesTable t) => t.discUid.equals(discUid))).go();
  });

  /// 用 MusicBrainz 发行结论更新光盘专辑（[album] 里给了的列）并给曲目改名（逐首标题 /
  /// 艺人 / 录音 MBID）。
  Future<void> applyMusicDiscRelease({
    required String albumUid,
    required MusicAlbumsCompanion album,
    required List<
      ({String trackUid, String title, String? artist, String? mbRecordingId})
    >
    names,
  }) => transaction(() async {
    await (update(musicAlbums)
          ..where(($MusicAlbumsTable t) => t.albumUid.equals(albumUid)))
        .write(album);
    for (final ({
          String trackUid,
          String title,
          String? artist,
          String? mbRecordingId,
        })
        n
        in names) {
      await (update(
        musicTracks,
      )..where(($MusicTracksTable t) => t.trackUid.equals(n.trackUid))).write(
        MusicTracksCompanion(
          title: Value<String>(n.title),
          artistCredit: n.artist == null
              ? const Value<String?>.absent()
              : Value<String?>(n.artist),
          mbRecordingId: n.mbRecordingId == null
              ? const Value<String?>.absent()
              : Value<String?>(n.mbRecordingId),
        ),
      );
    }
  });

  Future<List<MusicPlaylistRow>> listMusicPlaylists() =>
      (select(musicPlaylists)
            ..where(($MusicPlaylistsTable t) => t.deletedAt.isNull())
            ..orderBy(<OrderingTerm Function($MusicPlaylistsTable)>[
              ($MusicPlaylistsTable t) => OrderingTerm(expression: t.name),
            ]))
          .get();

  // ── 播放列表文件导入与重排（`.m3u` / `.m3u8`，music_local_playlists.dart）─────
  //
  // 导入的歌单 uid 由列表文件路径派生（同一个文件 = 同一个 uid）。用户删掉的歌单留着软删
  // 墓碑行（[deleteMusicPlaylist]），所以「uid 已被占用」要连墓碑一起算：下次扫描不会把
  // 用户删掉的歌单再导回来。

  /// [playlistUid] 是否已有歌单行（含已软删的墓碑）。
  Future<bool> musicPlaylistUidTaken(String playlistUid) async =>
      await (select(musicPlaylists)..where(
            ($MusicPlaylistsTable t) => t.playlistUid.equals(playlistUid),
          ))
          .getSingleOrNull() !=
      null;

  /// 以指定 uid 新建歌单（播放列表文件导入用；[trackUids] 按顺序成为初始条目）。uid 已被
  /// 占用（含软删墓碑）时什么都不做、回 false：同一个文件只导入一次。
  Future<bool> createImportedMusicPlaylist({
    required String playlistUid,
    required String name,
    required List<String> trackUids,
    required int at,
  }) => transaction(() async {
    if (await musicPlaylistUidTaken(playlistUid)) return false;
    await into(musicPlaylists).insert(
      MusicPlaylistsCompanion.insert(
        playlistUid: playlistUid,
        name: name,
        createdAt: at,
        updatedAt: at,
      ),
    );
    if (trackUids.isNotEmpty) {
      await addMusicPlaylistEntries(playlistUid, trackUids, at: at);
    }
    return true;
  });

  /// 按 [orderedEntryIds] 重排歌单，位置重写成 0..n-1。没列出的条目（页面上解析不到、没
  /// 显示的）保持原相对顺序排在后面；不属于本歌单的 id 忽略。推进歌单 `updated_at`。
  Future<void> reorderMusicPlaylist(
    String playlistUid,
    List<int> orderedEntryIds, {
    required int at,
  }) => transaction(() async {
    final List<int> current = <int>[
      for (final MusicPlaylistEntryRow e in await listMusicPlaylistEntries(
        playlistUid,
      ))
        e.id,
    ];
    final Set<int> known = current.toSet();
    final List<int> head = <int>[
      for (final int id in orderedEntryIds)
        if (known.contains(id)) id,
    ];
    final Set<int> placed = head.toSet();
    final List<int> order = <int>[
      ...head,
      for (final int id in current)
        if (!placed.contains(id)) id,
    ];
    await batch((Batch b) {
      for (int i = 0; i < order.length; i++) {
        b.update(
          musicPlaylistEntries,
          MusicPlaylistEntriesCompanion(position: Value<int>(i)),
          where: ($MusicPlaylistEntriesTable t) =>
              t.id.equals(order[i]) & t.playlistUid.equals(playlistUid),
        );
      }
    });
    await _touchMusicPlaylist(playlistUid, at);
  });

  /// 记一次播放（最近播放流）；返回行 id，播放结束时用 [finishMusicPlayEvent] 补时长。
  /// [snapshot] 是播放项快照 + 播放来源（v139）：在线 / 服务器曲目不进曲库，最近播放
  /// 只能靠它显示与重播。
  ///
  /// 写入守门（BUG-5290）：快照里的路径 / 封面 / 来源封面先过 [scrubMusicPersistedUrl]——
  /// 带账号凭据的服务器地址换成身份占位或丢掉，凭据绝不落库（app 侧已按服务器身份写占位，
  /// 这里兜住任何漏网的调用方）。
  Future<int> startMusicPlayEvent({
    required String trackUid,
    required int startedAt,
    MusicPlayEventSnapshot? snapshot,
  }) => into(musicPlayEvents).insert(
    MusicPlayEventsCompanion.insert(
      trackUid: trackUid,
      startedAt: startedAt,
      path: Value<String?>(scrubMusicPersistedUrl(snapshot?.path)),
      cueStartMs: Value<int?>(snapshot?.cueStartMs),
      cueEndMs: Value<int?>(snapshot?.cueEndMs),
      title: Value<String?>(snapshot?.title),
      artist: Value<String?>(snapshot?.artist),
      album: Value<String?>(snapshot?.album),
      albumUid: Value<String?>(snapshot?.albumUid),
      durationMs: Value<int?>(snapshot?.durationMs),
      coverPath: Value<String?>(scrubMusicPersistedUrl(snapshot?.coverPath)),
      sourceKind: Value<String?>(snapshot?.sourceKind),
      sourceId: Value<String?>(
        snapshot?.sourceKind == null ? null : snapshot?.sourceId,
      ),
      sourceTitle: Value<String?>(snapshot?.sourceTitle),
      sourceCover: Value<String?>(
        scrubMusicPersistedUrl(
          snapshot?.sourceCover,
          serverId: musicServerIdOfPlaySource(
            snapshot?.sourceKind,
            snapshot?.sourceId,
          ),
        ),
      ),
    ),
  );

  /// 清洗播放流快照里带账号凭据的服务器地址（BUG-5290）：`path` / `cover_path` /
  /// `source_cover` 里凡是带凭据的 http(s) 地址，按 [scrubMusicPersistedUrl] 换成身份占位
  /// （认不出曲目 / 封面 id 的置 NULL）。v174 迁移、备份恢复 / 合并导入之后各跑一次；
  /// 幂等，只扫 http(s) 开头的行。返回改写的行数。
  Future<int> scrubMusicPlayEventCredentials() async {
    final List<QueryRow> rows = await customSelect(
      'SELECT id, path, cover_path, source_cover, source_kind, source_id '
      'FROM music_play_events '
      "WHERE path LIKE 'http%' OR cover_path LIKE 'http%' "
      "OR source_cover LIKE 'http%'",
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{musicPlayEvents},
    ).get();
    int changed = 0;
    await transaction(() async {
      for (final QueryRow r in rows) {
        final String? path = r.read<String?>('path');
        final String? cover = r.read<String?>('cover_path');
        final String? sourceCover = r.read<String?>('source_cover');
        final String? newPath = scrubMusicPersistedUrl(path);
        final String? newCover = scrubMusicPersistedUrl(cover);
        final String? newSourceCover = scrubMusicPersistedUrl(
          sourceCover,
          serverId: musicServerIdOfPlaySource(
            r.read<String?>('source_kind'),
            r.read<String?>('source_id'),
          ),
        );
        if (newPath == path &&
            newCover == cover &&
            newSourceCover == sourceCover) {
          continue;
        }
        await customUpdate(
          'UPDATE music_play_events SET path = ?, cover_path = ?, '
          'source_cover = ? WHERE id = ?',
          variables: <Variable<Object>>[
            Variable<String>(newPath),
            Variable<String>(newCover),
            Variable<String>(newSourceCover),
            Variable<int>(r.read<int>('id')),
          ],
          updates: <TableInfo<Table, dynamic>>{musicPlayEvents},
        );
        changed++;
      }
    });
    return changed;
  }

  Future<void> finishMusicPlayEvent(
    int id, {
    required int listenedMs,
    required bool completed,
  }) =>
      (update(
        musicPlayEvents,
      )..where(($MusicPlayEventsTable t) => t.id.equals(id))).write(
        MusicPlayEventsCompanion(
          listenedMs: Value<int>(listenedMs),
          completed: Value<bool>(completed),
        ),
      );

  /// 一首曲目的断点（v146）；没有为 null。
  Future<MusicResumePointRow?> getMusicResumePoint(String trackUid) =>
      (select(musicResumePoints)
            ..where(($MusicResumePointsTable t) => t.trackUid.equals(trackUid)))
          .getSingleOrNull();

  /// 一批曲目的断点（列表显示进度用）。按块查询，不受 SQLite 变量个数上限限制。
  Future<Map<String, MusicResumePointRow>> listMusicResumePoints(
    Iterable<String> trackUids,
  ) async {
    final List<String> uids = trackUids.toSet().toList();
    final Map<String, MusicResumePointRow> out =
        <String, MusicResumePointRow>{};
    const int chunk = 500;
    for (int i = 0; i < uids.length; i += chunk) {
      final List<String> part = uids.sublist(
        i,
        i + chunk > uids.length ? uids.length : i + chunk,
      );
      for (final MusicResumePointRow r in await (select(
        musicResumePoints,
      )..where(($MusicResumePointsTable t) => t.trackUid.isIn(part))).get()) {
        out[r.trackUid] = r;
      }
    }
    return out;
  }

  /// 写一首曲目的断点（有则覆盖）。
  Future<void> upsertMusicResumePoint(
    String trackUid, {
    required int positionMs,
    int? durationMs,
    required int updatedAt,
  }) => into(musicResumePoints).insertOnConflictUpdate(
    MusicResumePointsCompanion.insert(
      trackUid: trackUid,
      positionMs: positionMs,
      durationMs: Value<int?>(durationMs),
      updatedAt: updatedAt,
    ),
  );

  /// 删一首曲目的断点（听完 / 回到开头 / 用户清除）。
  Future<void> deleteMusicResumePoint(String trackUid) => (delete(
    musicResumePoints,
  )..where(($MusicResumePointsTable t) => t.trackUid.equals(trackUid))).go();

  /// 最近播放的曲库曲目（按最近一次开始时刻去重），最多 [limit] 首。
  ///
  /// 只算曲库里还在（未软删）的曲目，且过滤在 SQL 里做：在线插件 / 服务器曲目的播放事件
  /// 不在 music_tracks 里，若先取 [limit] 条再丢，最近一次听的是在线曲时 `limit: 1`
  /// 就什么都拿不到。
  Future<List<MusicTrackRow>> listRecentlyPlayedMusicTracks({
    int limit = 20,
  }) async {
    final Expression<int> lastPlayed = musicPlayEvents.startedAt.max();
    final List<TypedResult> rows =
        await (selectOnly(musicPlayEvents).join(<Join>[
                innerJoin(
                  musicTracks,
                  musicTracks.trackUid.equalsExp(musicPlayEvents.trackUid) &
                      musicTracks.deletedAt.isNull(),
                  useColumns: false,
                ),
              ])
              ..addColumns(<Expression<Object>>[
                musicPlayEvents.trackUid,
                lastPlayed,
              ])
              ..groupBy(<Expression<Object>>[musicPlayEvents.trackUid])
              ..orderBy(<OrderingTerm>[
                OrderingTerm(expression: lastPlayed, mode: OrderingMode.desc),
              ])
              ..limit(limit))
            .get();
    final List<String> uids = <String>[
      for (final TypedResult r in rows) r.read(musicPlayEvents.trackUid)!,
    ];
    if (uids.isEmpty) return const <MusicTrackRow>[];
    final Map<String, MusicTrackRow> byUid = <String, MusicTrackRow>{
      for (final MusicTrackRow t
          in await (select(musicTracks)..where(
                ($MusicTracksTable t) =>
                    t.trackUid.isIn(uids) & t.deletedAt.isNull(),
              ))
              .get())
        t.trackUid: t,
    };
    return <MusicTrackRow>[
      for (final String uid in uids)
        if (byUid[uid] != null) byUid[uid]!,
    ];
  }

  /// 最近播放（按曲目去重，每首取最近一次播放事件），最多 [limit] 首，新的在前。
  ///
  /// 曲库里还在（未软删）的曲目带上 [MusicRecentPlay.track] / [MusicRecentPlay.album]；
  /// 不在曲库的（在线插件 / 服务器曲目、被删的本地曲目）靠事件快照，快照也没有
  /// （v139 前的存量事件）才丢——过滤在 SQL 里做，丢掉的不占 [limit] 名额。
  Future<List<MusicRecentPlay>> listRecentMusicPlays({int limit = 20}) async {
    if (limit <= 0) return const <MusicRecentPlay>[];
    // SQLite 的 bare column：带 MAX() 的分组查询里，其余列取自 MAX 所在那一行。
    final List<QueryRow> rows = await customSelect(
      'SELECT e.* FROM ('
      'SELECT *, MAX(started_at) AS last_at FROM music_play_events '
      'GROUP BY track_uid'
      ') AS e '
      'LEFT JOIN music_tracks AS t '
      'ON t.track_uid = e.track_uid AND t.deleted_at IS NULL '
      'WHERE t.track_uid IS NOT NULL OR e.path IS NOT NULL '
      'ORDER BY e.last_at DESC, e.id DESC LIMIT ?',
      variables: <Variable<Object>>[Variable<int>(limit)],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        musicPlayEvents,
        musicTracks,
      },
    ).get();
    final List<MusicPlayEventRow> events = <MusicPlayEventRow>[
      for (final QueryRow r in rows) musicPlayEvents.map(r.data),
    ];
    if (events.isEmpty) return const <MusicRecentPlay>[];
    final Map<String, MusicTrackRow> tracks = <String, MusicTrackRow>{
      for (final MusicTrackRow t
          in await (select(musicTracks)..where(
                ($MusicTracksTable t) =>
                    t.trackUid.isIn(<String>[
                      for (final MusicPlayEventRow e in events) e.trackUid,
                    ]) &
                    t.deletedAt.isNull(),
              ))
              .get())
        t.trackUid: t,
    };
    final Set<String> albumUids = <String>{
      for (final MusicTrackRow t in tracks.values)
        if (t.albumUid != null) t.albumUid!,
    };
    final Map<String, MusicAlbumRow> albums = albumUids.isEmpty
        ? const <String, MusicAlbumRow>{}
        : <String, MusicAlbumRow>{
            for (final MusicAlbumRow a
                in await (select(musicAlbums)..where(
                      ($MusicAlbumsTable a) => a.albumUid.isIn(albumUids),
                    ))
                    .get())
              a.albumUid: a,
          };
    return <MusicRecentPlay>[
      for (final MusicPlayEventRow e in events)
        MusicRecentPlay(
          event: e,
          track: tracks[e.trackUid],
          album: tracks[e.trackUid]?.albumUid == null
              ? null
              : albums[tracks[e.trackUid]!.albumUid!],
        ),
    ];
  }

  /// 最近播放的来源（专辑 / 歌单 …），按 (sourceKind, sourceId) 去重，最多 [limit] 个，
  /// 新的在前；标题 / 封面取该来源最近一次播放时记下的。[kinds] 非空时只要这些种类。
  Future<List<MusicRecentSource>> listRecentMusicSources({
    int limit = 20,
    Set<String>? kinds,
  }) async {
    if (limit <= 0) return const <MusicRecentSource>[];
    final List<String> kindList = kinds == null
        ? const <String>[]
        : (kinds.toList()..sort());
    if (kinds != null && kindList.isEmpty) return const <MusicRecentSource>[];
    final String kindFilter = kindList.isEmpty
        ? ''
        : 'AND source_kind IN (${List<String>.filled(kindList.length, '?').join(', ')}) ';
    final List<QueryRow> rows = await customSelect(
      'SELECT source_kind, source_id, source_title, source_cover, '
      'MAX(started_at) AS last_at FROM music_play_events '
      'WHERE source_kind IS NOT NULL AND source_id IS NOT NULL '
      '$kindFilter'
      'GROUP BY source_kind, source_id '
      'ORDER BY last_at DESC LIMIT ?',
      variables: <Variable<Object>>[
        for (final String k in kindList) Variable<String>(k),
        Variable<int>(limit),
      ],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{musicPlayEvents},
    ).get();
    return <MusicRecentSource>[
      for (final QueryRow r in rows)
        MusicRecentSource(
          kind: r.read<String>('source_kind'),
          id: r.read<String>('source_id'),
          title: r.readNullable<String>('source_title'),
          cover: r.readNullable<String>('source_cover'),
          lastPlayedAt: r.read<int>('last_at'),
        ),
    ];
  }

  // ── 本地歌单与远程曲目（v148，反馈 0tRY-D2JgG）──────────────────────────
  //
  // 歌单条目只存 `track_uid`：本地曲目指 `music_tracks`，远程曲目指 `music_remote_tracks`
  // （两边 uid 命名空间不同，不撞）。往歌单里加远程曲目时，远程曲目行与条目在同一个事务里
  // 落库，不会出现「条目指向一个查不到的远程曲目」。

  /// 新建一个普通歌单（可带初始曲目），返回新歌单行。[remote] 是 [trackUids] 里远程曲目的
  /// 元数据（同事务 upsert，入库状态不变）。
  Future<MusicPlaylistRow> createMusicPlaylist(
    String name, {
    required int at,
    List<String> trackUids = const <String>[],
    List<MusicRemoteTracksCompanion> remote =
        const <MusicRemoteTracksCompanion>[],
  }) => transaction(() async {
    final String uid = _FushiDbSrs.newProfileUid(); // UUIDv7：跨设备合并按它认歌单
    await into(musicPlaylists).insert(
      MusicPlaylistsCompanion.insert(
        playlistUid: uid,
        name: name,
        createdAt: at,
        updatedAt: at,
      ),
    );
    if (trackUids.isNotEmpty) {
      await addMusicPlaylistEntries(uid, trackUids, at: at, remote: remote);
    }
    return (select(musicPlaylists)
          ..where(($MusicPlaylistsTable t) => t.playlistUid.equals(uid)))
        .getSingle();
  });

  /// 一个歌单（软删的不算）；没有为 null。
  Future<MusicPlaylistRow?> getMusicPlaylist(String playlistUid) =>
      (select(musicPlaylists)..where(
            ($MusicPlaylistsTable t) =>
                t.playlistUid.equals(playlistUid) & t.deletedAt.isNull(),
          ))
          .getSingleOrNull();

  /// 改名（同时推进 `updated_at`，备份合并按它 LWW）。
  Future<void> renameMusicPlaylist(
    String playlistUid,
    String name, {
    required int at,
  }) =>
      (update(musicPlaylists)..where(
            ($MusicPlaylistsTable t) => t.playlistUid.equals(playlistUid),
          ))
          .write(
            MusicPlaylistsCompanion(
              name: Value<String>(name),
              updatedAt: Value<int>(at),
            ),
          );

  /// 软删歌单（留墓碑让删除随备份传到别的设备）并清掉条目。
  Future<void> deleteMusicPlaylist(String playlistUid, {required int at}) =>
      transaction(() async {
        await (delete(musicPlaylistEntries)..where(
              ($MusicPlaylistEntriesTable t) =>
                  t.playlistUid.equals(playlistUid),
            ))
            .go();
        await (update(musicPlaylists)..where(
              ($MusicPlaylistsTable t) => t.playlistUid.equals(playlistUid),
            ))
            .write(
              MusicPlaylistsCompanion(
                deletedAt: Value<int?>(at),
                updatedAt: Value<int>(at),
              ),
            );
      });

  /// 歌单条目（按位置排）。
  Future<List<MusicPlaylistEntryRow>> listMusicPlaylistEntries(
    String playlistUid,
  ) =>
      (select(musicPlaylistEntries)
            ..where(
              ($MusicPlaylistEntriesTable t) =>
                  t.playlistUid.equals(playlistUid),
            )
            ..orderBy(<OrderingTerm Function($MusicPlaylistEntriesTable)>[
              ($MusicPlaylistEntriesTable t) =>
                  OrderingTerm(expression: t.position),
              ($MusicPlaylistEntriesTable t) => OrderingTerm(expression: t.id),
            ]))
          .get();

  /// 各歌单的条目数（选歌单对话框显示用）。
  Future<Map<String, int>> countMusicPlaylistEntries() async {
    final Expression<int> n = musicPlaylistEntries.id.count();
    final List<TypedResult> rows =
        await (selectOnly(musicPlaylistEntries)
              ..addColumns(<Expression<Object>>[
                musicPlaylistEntries.playlistUid,
                n,
              ])
              ..groupBy(<Expression<Object>>[musicPlaylistEntries.playlistUid]))
            .get();
    return <String, int>{
      for (final TypedResult r in rows)
        r.read(musicPlaylistEntries.playlistUid)!: r.read(n) ?? 0,
    };
  }

  /// 把 [trackUids] 依次追加到歌单末尾；[remote] 是其中远程曲目的元数据（同事务 upsert，
  /// 不改它们的入库状态）。推进歌单 `updated_at`。
  Future<void> addMusicPlaylistEntries(
    String playlistUid,
    List<String> trackUids, {
    required int at,
    List<MusicRemoteTracksCompanion> remote =
        const <MusicRemoteTracksCompanion>[],
  }) => transaction(() async {
    for (final MusicRemoteTracksCompanion r in remote) {
      await upsertMusicRemoteTrack(r, at: at);
    }
    final Expression<int> maxPos = musicPlaylistEntries.position.max();
    final int? last =
        await (selectOnly(musicPlaylistEntries)
              ..addColumns(<Expression<Object>>[maxPos])
              ..where(musicPlaylistEntries.playlistUid.equals(playlistUid)))
            .map((TypedResult r) => r.read(maxPos))
            .getSingle();
    int position = last == null ? 0 : last + 1;
    for (final String uid in trackUids) {
      await into(musicPlaylistEntries).insert(
        MusicPlaylistEntriesCompanion.insert(
          playlistUid: playlistUid,
          trackUid: uid,
          position: position++,
          addedAt: at,
        ),
      );
    }
    await _touchMusicPlaylist(playlistUid, at);
  });

  /// 删一条歌单条目（按条目 id：同一首在歌单里可以出现两次，只删点的那一条），其后的
  /// 位置前移、不留空洞。推进歌单 `updated_at`。
  Future<void> removeMusicPlaylistEntry(
    String playlistUid,
    int entryId, {
    required int at,
  }) => transaction(() async {
    await (delete(musicPlaylistEntries)..where(
          ($MusicPlaylistEntriesTable t) =>
              t.id.equals(entryId) & t.playlistUid.equals(playlistUid),
        ))
        .go();
    final List<MusicPlaylistEntryRow> rest = await listMusicPlaylistEntries(
      playlistUid,
    );
    for (int i = 0; i < rest.length; i++) {
      if (rest[i].position == i) continue;
      await (update(musicPlaylistEntries)
            ..where(($MusicPlaylistEntriesTable t) => t.id.equals(rest[i].id)))
          .write(MusicPlaylistEntriesCompanion(position: Value<int>(i)));
    }
    await _touchMusicPlaylist(playlistUid, at);
  });

  /// 一次从歌单移除多条（按条目 id；同一首出现两次时只删选中的那几条），剩下的重排
  /// 位置。返回真被删掉的行（原位置不变），[restoreMusicPlaylistEntries] 拿它撤销。
  Future<List<MusicPlaylistEntryRow>> removeMusicPlaylistEntries(
    String playlistUid,
    Iterable<int> entryIds, {
    required int at,
  }) {
    final Set<int> ids = entryIds.toSet();
    if (ids.isEmpty) {
      return Future<List<MusicPlaylistEntryRow>>.value(
        const <MusicPlaylistEntryRow>[],
      );
    }
    return transaction(() async {
      final List<MusicPlaylistEntryRow> all = await listMusicPlaylistEntries(
        playlistUid,
      );
      final List<MusicPlaylistEntryRow> removed = <MusicPlaylistEntryRow>[
        for (final MusicPlaylistEntryRow r in all)
          if (ids.contains(r.id)) r,
      ];
      if (removed.isEmpty) return removed;
      final List<int> removedIds = <int>[
        for (final MusicPlaylistEntryRow r in removed) r.id,
      ];
      await (delete(musicPlaylistEntries)..where(
            ($MusicPlaylistEntriesTable t) =>
                t.playlistUid.equals(playlistUid) & t.id.isIn(removedIds),
          ))
          .go();
      await _renumberMusicPlaylistEntries(<MusicPlaylistEntryRow>[
        for (final MusicPlaylistEntryRow r in all)
          if (!ids.contains(r.id)) r,
      ]);
      await _touchMusicPlaylist(playlistUid, at);
      return removed;
    });
  }

  /// 撤销 [removeMusicPlaylistEntries]：把删掉的条目（原 id、原入列时刻）按原位置插回
  /// 当前列表。歌单已经不在（期间被删）时什么都不做。
  Future<void> restoreMusicPlaylistEntries(
    String playlistUid,
    List<MusicPlaylistEntryRow> rows, {
    required int at,
  }) {
    if (rows.isEmpty) return Future<void>.value();
    return transaction(() async {
      final MusicPlaylistRow? playlist =
          await (select(musicPlaylists)..where(
                ($MusicPlaylistsTable t) =>
                    t.playlistUid.equals(playlistUid) & t.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (playlist == null) return;
      final List<MusicPlaylistEntryRow> order = await listMusicPlaylistEntries(
        playlistUid,
      );
      final List<MusicPlaylistEntryRow> sorted =
          List<MusicPlaylistEntryRow>.of(rows)..sort(
            (MusicPlaylistEntryRow a, MusicPlaylistEntryRow b) =>
                a.position.compareTo(b.position),
          );
      // 按原位置从小到大插回：没有别的改动时正好还原成删除前的顺序。
      for (final MusicPlaylistEntryRow r in sorted) {
        await into(musicPlaylistEntries).insertOnConflictUpdate(r);
        order.insert(r.position.clamp(0, order.length), r);
      }
      await _renumberMusicPlaylistEntries(order);
      await _touchMusicPlaylist(playlistUid, at);
    });
  }

  /// 把 [ordered] 的位置写成 0..n-1（已经对的不写）。
  Future<void> _renumberMusicPlaylistEntries(
    List<MusicPlaylistEntryRow> ordered,
  ) async {
    for (int i = 0; i < ordered.length; i++) {
      if (ordered[i].position == i) continue;
      await (update(musicPlaylistEntries)..where(
            ($MusicPlaylistEntriesTable t) => t.id.equals(ordered[i].id),
          ))
          .write(MusicPlaylistEntriesCompanion(position: Value<int>(i)));
    }
  }

  Future<void> _touchMusicPlaylist(String playlistUid, int at) =>
      (update(musicPlaylists)..where(
            ($MusicPlaylistsTable t) => t.playlistUid.equals(playlistUid),
          ))
          .write(MusicPlaylistsCompanion(updatedAt: Value<int>(at)));

  /// 写一首远程曲目的元数据（有则更新元数据；[MusicRemoteTracksCompanion.libraryAddedAt]
  /// 缺省时保留原入库状态；`created_at` 只在首次写入时定）。
  Future<void> upsertMusicRemoteTrack(
    MusicRemoteTracksCompanion track, {
    required int at,
  }) => into(musicRemoteTracks).insert(
    track.copyWith(createdAt: Value<int>(at), updatedAt: Value<int>(at)),
    onConflict: DoUpdate(
      (_) => track.copyWith(
        createdAt: const Value<int>.absent(),
        updatedAt: Value<int>(at),
      ),
    ),
  );

  /// 加入音乐库（已在库的不改入库时刻，只刷新元数据）。
  Future<void> addMusicRemoteTrackToLibrary(
    MusicRemoteTracksCompanion track, {
    required int at,
  }) => transaction(() async {
    final MusicRemoteTrackRow? existing = await getMusicRemoteTrack(
      track.trackUid.value,
    );
    await upsertMusicRemoteTrack(
      track.copyWith(
        libraryAddedAt: Value<int?>(existing?.libraryAddedAt ?? at),
      ),
      at: at,
    );
  });

  /// 从音乐库移除：只清入库时刻（行留着，歌单 / 别的设备可能还引用它）。
  Future<void> removeMusicRemoteTrackFromLibrary(
    String trackUid, {
    required int at,
  }) => removeMusicRemoteTracksFromLibrary(<String>[trackUid], at: at);

  /// 一批远程曲目整体加入音乐库（专辑 / 艺人「加入音乐库」）：同一个事务，已在库的不改入库
  /// 时刻、只刷新元数据。
  Future<void> addMusicRemoteTracksToLibrary(
    List<MusicRemoteTracksCompanion> tracks, {
    required int at,
  }) => transaction(() async {
    final Map<String, MusicRemoteTrackRow> existing =
        await listMusicRemoteTracks(<String>[
          for (final MusicRemoteTracksCompanion t in tracks) t.trackUid.value,
        ]);
    for (final MusicRemoteTracksCompanion t in tracks) {
      await upsertMusicRemoteTrack(
        t.copyWith(
          libraryAddedAt: Value<int?>(
            existing[t.trackUid.value]?.libraryAddedAt ?? at,
          ),
        ),
        at: at,
      );
    }
  });

  /// 一批远程曲目整体移出音乐库（只清入库时刻，行留着）。同一个事务。离线副本不在这里删：
  /// 调用方过了撤销窗口再删（[listMusicServerDownloadsOutsideLibrary]）。
  Future<void> removeMusicRemoteTracksFromLibrary(
    Iterable<String> trackUids, {
    required int at,
  }) => transaction(() async {
    final List<String> uids = trackUids.toSet().toList();
    const int chunk = 500;
    for (int i = 0; i < uids.length; i += chunk) {
      final List<String> part = uids.sublist(
        i,
        i + chunk > uids.length ? uids.length : i + chunk,
      );
      await (update(
        musicRemoteTracks,
      )..where(($MusicRemoteTracksTable t) => t.trackUid.isIn(part))).write(
        MusicRemoteTracksCompanion(
          libraryAddedAt: const Value<int?>(null),
          updatedAt: Value<int>(at),
        ),
      );
    }
  });

  /// 不在音乐库里的离线副本行（下载 ⊂ 音乐库：用户在本机「移出音乐库」、撤销窗口过去后由
  /// 调用方连文件一起删）。[trackUids] 给了只看这几首。只用于本机显式移除的收尾——启动 /
  /// 恢复 / 合并后的对账走 [reconcileMusicServerDownloadsIntoLibrary]（放回曲库，不删文件）。
  Future<List<MusicServerDownloadRow>> listMusicServerDownloadsOutsideLibrary([
    Iterable<String>? trackUids,
  ]) async {
    final List<MusicServerDownloadRow> rows = trackUids == null
        ? await select(musicServerDownloads).get()
        : (await listMusicServerDownloadsOf(trackUids)).values.toList();
    if (rows.isEmpty) return rows;
    final Set<String> inLibrary = await musicRemoteLibraryUidsOf(<String>[
      for (final MusicServerDownloadRow r in rows) r.trackUid,
    ]);
    return <MusicServerDownloadRow>[
      for (final MusicServerDownloadRow r in rows)
        if (!inLibrary.contains(r.trackUid)) r,
    ];
  }

  /// 一批曲目里已在音乐库的 uid（专辑 / 艺人页的「全部 / 部分 / 不在库」）。按块查询。
  Future<Set<String>> musicRemoteLibraryUidsOf(
    Iterable<String> trackUids,
  ) async {
    final Set<String> out = <String>{};
    for (final MusicRemoteTrackRow r in (await listMusicRemoteTracks(
      trackUids,
    )).values) {
      if (r.libraryAddedAt != null) out.add(r.trackUid);
    }
    return out;
  }

  /// 盯一批曲目里已在音乐库的 uid（专辑 / 艺人页的入库状态随任何写路径实时更新）。一条
  /// 查询（一张专辑 / 一位艺人的曲目数远低于 SQLite 变量上限）。
  Stream<Set<String>> watchMusicRemoteLibraryUidsOf(List<String> trackUids) {
    if (trackUids.isEmpty) return Stream<Set<String>>.value(const <String>{});
    return (selectOnly(musicRemoteTracks)
          ..addColumns(<Expression<Object>>[musicRemoteTracks.trackUid])
          ..where(
            musicRemoteTracks.trackUid.isIn(trackUids) &
                musicRemoteTracks.libraryAddedAt.isNotNull(),
          ))
        .watch()
        .map(
          (List<TypedResult> rows) => <String>{
            for (final TypedResult r in rows)
              r.read(musicRemoteTracks.trackUid)!,
          },
        );
  }

  /// 记一份下完的离线副本：同一个事务里把这首写进音乐库（已在库不改入库时刻）并落副本行
  /// （同一首重下覆盖旧行）。
  ///
  /// [stillWanted] 在事务**里面**、写入之前判一次：下载开始之后这首被「移出音乐库」了就回假，
  /// 这里什么都不写、返回 false（调用方删掉落地的文件）——不让下完的任务把刚移出的曲目又
  /// 加回曲库。判据放在事务里：移出的写入与这里的写入在同一个连接上串行，先判后移出的那次
  /// 移出一定落在这次写入之后（曲目照样被移出，副本由移出的收尾删）。
  Future<bool> recordMusicServerDownload(
    MusicServerDownloadsCompanion download, {
    required MusicRemoteTracksCompanion track,
    required int at,
    bool Function()? stillWanted,
  }) => transaction(() async {
    if (stillWanted != null && !stillWanted()) return false;
    await addMusicRemoteTrackToLibrary(track, at: at);
    await into(
      musicServerDownloads,
    ).insertOnConflictUpdate(download.copyWith(downloadedAt: Value<int>(at)));
    return true;
  });

  /// 离线副本是设备本地的事实（下载 ⊂ 音乐库）：把每个副本行对应的曲目放回音乐库，返回放回
  /// 的首数。启动接上库时、覆盖恢复与合并导入之后各跑一次——备份里没有这首（覆盖恢复把
  /// `music_remote_tracks` 换成了备份的）、或合并进来的较新一行清了入库时刻（别的设备移出过）
  /// 都不许让本机下好的文件变成没人认的孤儿、更不许被删。
  ///
  /// - 行在、不在库：入库时刻填成下完的时刻，`updated_at` **不动**——这是本机的设备本地修正，
  ///   不该在下次合并时把「放回曲库」当成更新的一次编辑传给别的设备（那边仍按它自己的 LWW）。
  /// - 行都没了：按副本行的服务器身份重建一行（种类 `server` + 服务器配置身份 + 条目 id）；标题 /
  ///   专辑按落点文件名推（`<曲序> <标题> [哈希].<扩展名>`、专辑目录 `<专辑名> [哈希]`），
  ///   之后在服务器页上再入库 / 播放时刷新成服务器的元数据。覆盖恢复会先从恢复前的本机库把
  ///   这些行原样搬回来（[copyMusicRemoteTracksOfDownloadsFrom]），这里只是兜底。
  Future<int> reconcileMusicServerDownloadsIntoLibrary({
    required int at,
  }) => transaction(() async {
    final List<MusicServerDownloadRow> downloads = await select(
      musicServerDownloads,
    ).get();
    if (downloads.isEmpty) return 0;
    final Map<String, MusicRemoteTrackRow> remote = await listMusicRemoteTracks(
      <String>[for (final MusicServerDownloadRow d in downloads) d.trackUid],
    );
    int n = 0;
    for (final MusicServerDownloadRow d in downloads) {
      final MusicRemoteTrackRow? r = remote[d.trackUid];
      if (r != null && r.libraryAddedAt != null) continue;
      if (r == null) {
        await into(musicRemoteTracks).insert(
          MusicRemoteTracksCompanion.insert(
            trackUid: d.trackUid,
            kind: 'server',
            sourceKey: d.sourceKey,
            itemId: d.itemId,
            title: musicServerDownloadTitleFromPath(d.filePath),
            album: Value<String?>(musicServerDownloadAlbumFromPath(d.filePath)),
            libraryAddedAt: Value<int?>(d.downloadedAt),
            createdAt: at,
            updatedAt: at,
          ),
        );
      } else {
        await (update(musicRemoteTracks)..where(
              ($MusicRemoteTracksTable t) => t.trackUid.equals(d.trackUid),
            ))
            .write(
              MusicRemoteTracksCompanion(
                libraryAddedAt: Value<int?>(d.downloadedAt),
              ),
            );
      }
      n++;
    }
    return n;
  });

  /// 覆盖恢复：恢复进来的库里缺了离线副本对应的 `music_remote_tracks` 行时，从 ATTACH 成
  /// [schema] 的恢复前本机库原样搬回来（元数据 / 封面引用 / 艺人引用都在），已有的行不动。
  /// 两个库此刻都在当前 schema（恢复前的库就是本机活库的副本）。返回搬回的行数。
  Future<int> copyMusicRemoteTracksOfDownloadsFrom(String schema) async {
    final String cols = <String>[
      for (final GeneratedColumn<Object> c in musicRemoteTracks.$columns)
        '"${c.name}"',
    ].join(', ');
    return customUpdate(
      'INSERT OR IGNORE INTO main.music_remote_tracks ($cols) '
      'SELECT $cols FROM $schema.music_remote_tracks '
      'WHERE track_uid IN (SELECT track_uid FROM main.music_server_downloads)',
      updates: <TableInfo<Table, Object?>>{musicRemoteTracks},
      updateKind: UpdateKind.insert,
    );
  }

  /// 删一批离线副本行（文件由调用方删）。返回被删的行。
  Future<List<MusicServerDownloadRow>> deleteMusicServerDownloads(
    Iterable<String> trackUids,
  ) => transaction(() async {
    final List<String> uids = trackUids.toSet().toList();
    final List<MusicServerDownloadRow> rows = (await listMusicServerDownloadsOf(
      uids,
    )).values.toList();
    const int chunk = 500;
    for (int i = 0; i < uids.length; i += chunk) {
      final List<String> part = uids.sublist(
        i,
        i + chunk > uids.length ? uids.length : i + chunk,
      );
      await (delete(
        musicServerDownloads,
      )..where(($MusicServerDownloadsTable t) => t.trackUid.isIn(part))).go();
    }
    return rows;
  });

  /// 一批曲目的离线副本行（按块查询）。
  Future<Map<String, MusicServerDownloadRow>> listMusicServerDownloadsOf(
    Iterable<String> trackUids,
  ) async {
    final List<String> uids = trackUids.toSet().toList();
    final Map<String, MusicServerDownloadRow> out =
        <String, MusicServerDownloadRow>{};
    const int chunk = 500;
    for (int i = 0; i < uids.length; i += chunk) {
      final List<String> part = uids.sublist(
        i,
        i + chunk > uids.length ? uids.length : i + chunk,
      );
      for (final MusicServerDownloadRow r
          in await (select(
                musicServerDownloads,
              )..where(($MusicServerDownloadsTable t) => t.trackUid.isIn(part)))
              .get()) {
        out[r.trackUid] = r;
      }
    }
    return out;
  }

  /// 全部离线副本（进程内索引的初值与变化：任何写路径改了表都会推新快照）。
  Stream<List<MusicServerDownloadRow>> watchMusicServerDownloads() =>
      select(musicServerDownloads).watch();

  // ── v176：服务器曲目没送达的播放 / 收藏（补发队列）与客户端状态 ──

  /// 播放的去重键：同一台服务器、同一首、同一个开播时刻只记一次。
  String musicServerPendingPlayKey(
    String serverId,
    String itemId,
    int playedAt,
  ) => 'play\u0000$serverId\u0000$itemId\u0000$playedAt';

  /// 收藏的去重键：同一台服务器、同一首只留最后一次切换。
  String musicServerPendingFavoriteKey(String serverId, String itemId) =>
      'favorite\u0000$serverId\u0000$itemId';

  /// 记一次没送达的播放（同一次播放重复记是空操作）。
  Future<void> enqueueMusicServerPendingPlay({
    required String serverKind,
    required String serverId,
    required String itemId,
    required String trackUid,
    required int playedAt,
    required int at,
  }) => into(musicServerPendingActions).insert(
    MusicServerPendingActionsCompanion.insert(
      dedupeKey: musicServerPendingPlayKey(serverId, itemId, playedAt),
      action: 'play',
      serverKind: serverKind,
      serverId: serverId,
      itemId: itemId,
      trackUid: trackUid,
      playedAt: Value<int?>(playedAt),
      createdAt: at,
    ),
    mode: InsertMode.insertOrIgnore,
  );

  /// 记一次没送达的收藏切换：同一首之前没送达的那次被这次覆盖（最后一次切换为准，尝试
  /// 次数清零）。
  Future<void> enqueueMusicServerPendingFavorite({
    required String serverKind,
    required String serverId,
    required String itemId,
    required String trackUid,
    required bool favorite,
    required int at,
  }) => into(musicServerPendingActions).insertOnConflictUpdate(
    MusicServerPendingActionsCompanion.insert(
      dedupeKey: musicServerPendingFavoriteKey(serverId, itemId),
      action: 'favorite',
      serverKind: serverKind,
      serverId: serverId,
      itemId: itemId,
      trackUid: trackUid,
      favorite: Value<bool?>(favorite),
      createdAt: at,
      attempts: const Value<int>(0),
      lastAttemptAt: const Value<int?>(null),
    ),
  );

  /// 待补发的条目（[serverId] 给了只看那台服务器），按播放时刻 / 入队时刻从旧到新——
  /// Jellyfin 的「最近播放时刻」取最后一次标记的值，旧的先发才不会把它改回旧时刻。
  Future<List<MusicServerPendingActionRow>> listMusicServerPendingActions({
    String? serverId,
  }) async {
    final List<MusicServerPendingActionRow> rows =
        await (select(musicServerPendingActions)..where(
              ($MusicServerPendingActionsTable t) => serverId == null
                  ? const Constant<bool>(true)
                  : t.serverId.equals(serverId),
            ))
            .get();
    rows.sort((MusicServerPendingActionRow a, MusicServerPendingActionRow b) {
      final int byTime = (a.playedAt ?? a.createdAt).compareTo(
        b.playedAt ?? b.createdAt,
      );
      return byTime != 0 ? byTime : a.dedupeKey.compareTo(b.dedupeKey);
    });
    return rows;
  }

  /// 盯待送达的收藏切换（「正在播放」的心形显示它）。
  Stream<List<MusicServerPendingActionRow>>
  watchMusicServerPendingFavorites() =>
      (select(musicServerPendingActions)..where(
            ($MusicServerPendingActionsTable t) => t.action.equals('favorite'),
          ))
          .watch();

  /// 补发成功 / 放弃的条目删掉。
  Future<void> deleteMusicServerPendingActions(Iterable<String> dedupeKeys) =>
      transaction(() async {
        final List<String> keys = dedupeKeys.toSet().toList();
        const int chunk = 500;
        for (int i = 0; i < keys.length; i += chunk) {
          final List<String> part = keys.sublist(
            i,
            i + chunk > keys.length ? keys.length : i + chunk,
          );
          await (delete(musicServerPendingActions)..where(
                ($MusicServerPendingActionsTable t) => t.dedupeKey.isIn(part),
              ))
              .go();
        }
      });

  /// 补发成功后删这一条——只删这一版：补发期间同一首又切换了收藏（入队时刻变了），新的那次
  /// 留着下次发。
  Future<void> deleteMusicServerPendingActionIfUnchanged(
    MusicServerPendingActionRow row,
  ) =>
      (delete(musicServerPendingActions)..where(
            ($MusicServerPendingActionsTable t) =>
                t.dedupeKey.equals(row.dedupeKey) &
                t.createdAt.equals(row.createdAt),
          ))
          .go();

  /// 服务器回了错误（不是连不上）：尝试次数 +1。返回加完之后的次数（行已不在为 null）。
  Future<int?> bumpMusicServerPendingAttempt(
    String dedupeKey, {
    required int at,
  }) => transaction(() async {
    await customUpdate(
      'UPDATE music_server_pending_actions '
      'SET attempts = attempts + 1, last_attempt_at = ? '
      'WHERE dedupe_key = ?',
      variables: <Variable<Object>>[
        Variable<int>(at),
        Variable<String>(dedupeKey),
      ],
      updates: <TableInfo<Table, Object?>>{musicServerPendingActions},
      updateKind: UpdateKind.update,
    );
    final MusicServerPendingActionRow? row =
        await (select(musicServerPendingActions)..where(
              ($MusicServerPendingActionsTable t) =>
                  t.dedupeKey.equals(dedupeKey),
            ))
            .getSingleOrNull();
    return row?.attempts;
  });

  /// 队列修剪：① 服务器不在 [configuredServerIds] 里、且入队早于 [orphanBefore] 的条目丢掉
  /// （那台服务器一直没配回来）；② 超过 [cap] 条时丢最旧的播放（收藏每首只有一条，留着）。
  /// 返回丢掉的条数。
  Future<int> pruneMusicServerPendingActions({
    required Set<String> configuredServerIds,
    required int orphanBefore,
    required int cap,
  }) => transaction(() async {
    int dropped = 0;
    final List<MusicServerPendingActionRow> all = await select(
      musicServerPendingActions,
    ).get();
    final List<String> orphans = <String>[
      for (final MusicServerPendingActionRow r in all)
        if (!configuredServerIds.contains(r.serverId) &&
            r.createdAt < orphanBefore)
          r.dedupeKey,
    ];
    if (orphans.isNotEmpty) {
      await deleteMusicServerPendingActions(orphans);
      dropped += orphans.length;
    }
    final int left = all.length - orphans.length;
    if (left > cap) {
      final Set<String> gone = orphans.toSet();
      final List<MusicServerPendingActionRow> plays =
          <MusicServerPendingActionRow>[
            for (final MusicServerPendingActionRow r in all)
              if (r.action == 'play' && !gone.contains(r.dedupeKey)) r,
          ]..sort(
            (MusicServerPendingActionRow a, MusicServerPendingActionRow b) =>
                (a.playedAt ?? a.createdAt).compareTo(
                  b.playedAt ?? b.createdAt,
                ),
          );
      final List<String> oldest = <String>[
        for (final MusicServerPendingActionRow r in plays.take(left - cap))
          r.dedupeKey,
      ];
      await deleteMusicServerPendingActions(oldest);
      dropped += oldest.length;
    }
    return dropped;
  });

  /// 一首服务器曲目在本机记下的客户端状态；没有为 null。
  Future<MusicServerTrackStateRow?> getMusicServerTrackState(String trackUid) =>
      (select(musicServerTrackStates)..where(
            ($MusicServerTrackStatesTable t) => t.trackUid.equals(trackUid),
          ))
          .getSingleOrNull();

  Future<void> _upsertMusicServerTrackState(
    MusicServerTrackStatesCompanion row,
  ) => into(musicServerTrackStates).insert(
    row,
    onConflict: DoUpdate(
      (_) => row,
      target: <Column<Object>>[musicServerTrackStates.trackUid],
    ),
  );

  /// 记下一首服务器曲目最后已知的收藏状态。
  Future<void> writeMusicServerTrackFavorite({
    required String trackUid,
    required String serverKind,
    required String serverId,
    required String itemId,
    required bool favorite,
    required int at,
  }) => _upsertMusicServerTrackState(
    MusicServerTrackStatesCompanion(
      trackUid: Value<String>(trackUid),
      serverKind: Value<String>(serverKind),
      serverId: Value<String>(serverId),
      itemId: Value<String>(itemId),
      favorite: Value<bool?>(favorite),
      favoriteAt: Value<int?>(at),
      updatedAt: Value<int>(at),
    ),
  );

  /// 记下客户端测的响度（[gain] 为 null = 测过、测不出：不再测）。
  Future<void> writeMusicServerTrackMeasuredLoudness({
    required String trackUid,
    required String serverKind,
    required String serverId,
    required String itemId,
    required double? gain,
    required double? peak,
    required int at,
  }) => _upsertMusicServerTrackState(
    MusicServerTrackStatesCompanion(
      trackUid: Value<String>(trackUid),
      serverKind: Value<String>(serverKind),
      serverId: Value<String>(serverId),
      itemId: Value<String>(itemId),
      measuredTrackGain: Value<double?>(gain),
      measuredTrackPeak: Value<double?>(peak),
      loudnessMeasuredAt: Value<int?>(at),
      updatedAt: Value<int>(at),
    ),
  );

  Future<MusicRemoteTrackRow?> getMusicRemoteTrack(String trackUid) =>
      (select(musicRemoteTracks)
            ..where(($MusicRemoteTracksTable t) => t.trackUid.equals(trackUid)))
          .getSingleOrNull();

  /// 在音乐库里的远程曲目（最近加入的在前）。
  Future<List<MusicRemoteTrackRow>> listMusicRemoteLibraryTracks() =>
      (select(musicRemoteTracks)
            ..where(($MusicRemoteTracksTable t) => t.libraryAddedAt.isNotNull())
            ..orderBy(<OrderingTerm Function($MusicRemoteTracksTable)>[
              ($MusicRemoteTracksTable t) => OrderingTerm(
                expression: t.libraryAddedAt,
                mode: OrderingMode.desc,
              ),
              ($MusicRemoteTracksTable t) => OrderingTerm(expression: t.title),
            ]))
          .get();

  /// 一批远程曲目（歌单解析条目用）。按块查询，不受 SQLite 变量个数上限限制。
  Future<Map<String, MusicRemoteTrackRow>> listMusicRemoteTracks(
    Iterable<String> trackUids,
  ) async {
    final List<String> uids = trackUids.toSet().toList();
    final Map<String, MusicRemoteTrackRow> out =
        <String, MusicRemoteTrackRow>{};
    const int chunk = 500;
    for (int i = 0; i < uids.length; i += chunk) {
      final List<String> part = uids.sublist(
        i,
        i + chunk > uids.length ? uids.length : i + chunk,
      );
      for (final MusicRemoteTrackRow r in await (select(
        musicRemoteTracks,
      )..where(($MusicRemoteTracksTable t) => t.trackUid.isIn(part))).get()) {
        out[r.trackUid] = r;
      }
    }
    return out;
  }

  /// 一批本地曲库曲目（含软删的：歌单条目仍要能解析到被删文件的那一行）。按块查询。
  Future<Map<String, MusicTrackRow>> listMusicTracksByUid(
    Iterable<String> trackUids,
  ) async {
    final List<String> uids = trackUids.toSet().toList();
    final Map<String, MusicTrackRow> out = <String, MusicTrackRow>{};
    const int chunk = 500;
    for (int i = 0; i < uids.length; i += chunk) {
      final List<String> part = uids.sublist(
        i,
        i + chunk > uids.length ? uids.length : i + chunk,
      );
      for (final MusicTrackRow r in await (select(
        musicTracks,
      )..where(($MusicTracksTable t) => t.trackUid.isIn(part))).get()) {
        out[r.trackUid] = r;
      }
    }
    return out;
  }
}

/// 写播放事件时随行落库的播放项快照与播放来源（v139）。来源 [sourceKind] 为 null 时
/// [sourceId] 也不落（来源未知）。
class MusicPlayEventSnapshot {
  const MusicPlayEventSnapshot({
    this.path,
    this.cueStartMs,
    this.cueEndMs,
    this.title,
    this.artist,
    this.album,
    this.albumUid,
    this.durationMs,
    this.coverPath,
    this.sourceKind,
    this.sourceId,
    this.sourceTitle,
    this.sourceCover,
  });

  final String? path;
  final int? cueStartMs;
  final int? cueEndMs;
  final String? title;
  final String? artist;
  final String? album;
  final String? albumUid;
  final int? durationMs;
  final String? coverPath;
  final String? sourceKind;
  final String? sourceId;
  final String? sourceTitle;
  final String? sourceCover;
}

/// 最近播放的一首：该曲目最近一次播放事件（含快照与来源）+ 曲库里的现行（未软删）
/// 行（不在曲库为 null）。
class MusicRecentPlay {
  const MusicRecentPlay({required this.event, this.track, this.album});

  final MusicPlayEventRow event;
  final MusicTrackRow? track;
  final MusicAlbumRow? album;

  String get trackUid => event.trackUid;
  int get lastPlayedAt => event.startedAt;
}

/// 最近播放的一个来源（专辑 / 歌单 …）。
class MusicRecentSource {
  const MusicRecentSource({
    required this.kind,
    required this.id,
    required this.lastPlayedAt,
    this.title,
    this.cover,
  });

  /// 来源种类 wire 值（见 `MusicPlayEvents.sourceKind`）。
  final String kind;
  final String id;
  final String? title;
  final String? cover;
  final int lastPlayedAt;
}

/// 落点名末尾的 ` [<十六进制哈希>]`（`musicServerDownloadTarget` 写的去重后缀）。
final RegExp _musicServerDownloadHashSuffix = RegExp(r' \[[0-9a-f]+\]$');

/// 离线副本文件名推出的曲目标题（`<曲序> <标题> [哈希].<扩展名>` → `<曲序> <标题>`）：只在
/// `music_remote_tracks` 行没了、要按副本重建时用（[FushiDatabase.reconcileMusicServerDownloadsIntoLibrary]）。
String musicServerDownloadTitleFromPath(String filePath) {
  final String stem = p
      .basenameWithoutExtension(filePath)
      .replaceFirst(_musicServerDownloadHashSuffix, '')
      .trim();
  return stem.isEmpty ? p.basename(filePath) : stem;
}

/// 离线副本所在专辑目录推出的专辑名（`<专辑名> [哈希]` → `<专辑名>`）；推不出回 null。
String? musicServerDownloadAlbumFromPath(String filePath) {
  final String dir = p.basename(p.dirname(filePath));
  final String name = dir
      .replaceFirst(_musicServerDownloadHashSuffix, '')
      .trim();
  return name.isEmpty || name == dir ? null : name;
}

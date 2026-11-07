// 音乐曲目身份（schema v145，反馈 QAondMh4M5）：同一个文件在曲库里只有一行。
//
// 曲目 uid 由 Rust 按「路径原文 + CUE 起点 + 音频指纹」派生。旧版本扫描器拼出的路径随
// 扫描根的写法而变（`D:/Music\Album\x.flac` 与 `D:/Music/Album\x.flac`），同一个文件从
// 不同的根进来就是两个 uid、两行。Rust 现在只产出一种拼法；这里负责过渡与兜底：
// - 扫描落库（[_remapScannedMusicTracks]）：新 uid 不在库里、但库里有同一路径键
//   （[MusicTracks.pathKey]）+ 同一 CUE 起点 + 同一音频指纹的行，就沿用那一行的 uid——
//   存量曲目不因为路径拼法变了整体换 uid（歌单 / 播放记录 / 歌词都挂在 uid 上）。
// - 存量重复行（[mergeDuplicateMusicTracks]，v145 迁移跑一次，幂等）：按同一判据分组，
//   败者并进胜者（[mergeMusicTrackInto]），引用改指胜者，记 uid 别名。
// - 别名（[applyMusicTrackUidAliases]）：别的设备 / 旧备份里仍是败者 uid 的歌单项、
//   播放记录、歌词合入本机后，由合并引擎与恢复调用它改指胜者。
//
// 引用 track uid 的地方全部列在 [kMusicTrackUidReferences]，守卫测试按 schema 枚举
// 核对，以后新表漏登记会变红。
part of 'database.dart';

/// 引用曲目 uid 的一列，以及改写它时怎么处理唯一键冲突。
class MusicTrackUidReference {
  const MusicTrackUidReference(
    this.table,
    this.column, {
    this.where,
    this.conflictKey = const <String>[],
    this.lwwColumn,
    this.unique = false,
  });

  final String table;
  final String column;

  /// 只改写满足条件的行（共用表里只有音乐来源的行是曲目 uid，例如
  /// `mined_sentences.source = 'music'`）。
  final String? where;

  /// 与 [column] 一起构成唯一键的其余列；空 = 没有唯一约束（直接改写）。
  final List<String> conflictKey;

  /// 唯一键冲突时按这一列取较新的一行（LWW）；null = 胜者已有的行优先。
  final String? lwwColumn;

  /// （[column] + [conflictKey]）是否唯一（改写时胜者已有同键行就去重）。
  final bool unique;
}

/// 全部引用 `music_tracks.track_uid` 的列（`music_tracks` 自身的主键除外）。
const List<MusicTrackUidReference> kMusicTrackUidReferences =
    <MusicTrackUidReference>[
      MusicTrackUidReference(
        'music_track_credits',
        'track_uid',
        conflictKey: <String>['artist_uid', 'role'],
        unique: true,
      ),
      MusicTrackUidReference(
        'music_lyrics',
        'track_uid',
        conflictKey: <String>['source'],
        unique: true,
        lwwColumn: 'updated_at',
      ),
      MusicTrackUidReference(
        'music_videos',
        'track_uid',
        conflictKey: <String>['kind', 'ref'],
        unique: true,
        lwwColumn: 'updated_at',
      ),
      // 歌单里同一首歌可以出现两次（用户有意为之），所以不按唯一键处理；改写后才在
      // 同一歌单里撞上的那一条由 [_dedupePlaylistEntriesAfterAlias] 去掉。
      MusicTrackUidReference('music_playlist_entries', 'track_uid'),
      // 播放流没有唯一约束，但合并引擎按 (track_uid, started_at) 去重并集：同一次播放
      // 在胜者下已有就不再留败者那条。
      MusicTrackUidReference(
        'music_play_events',
        'track_uid',
        conflictKey: <String>['started_at'],
        unique: true,
      ),
      MusicTrackUidReference('music_scrape_meta', 'track_uid', unique: true),
      // 逐曲断点（v146）：一首一行，两边都有时留较新的那个断点。
      MusicTrackUidReference(
        'music_resume_points',
        'track_uid',
        unique: true,
        lwwColumn: 'updated_at',
      ),
      MusicTrackUidReference(
        'music_locked_fields',
        'entity_uid',
        where: "entity_kind = 'track'",
        conflictKey: <String>['entity_kind', 'field'],
        unique: true,
      ),
      MusicTrackUidReference(
        'video_theme_song_spans',
        'track_uid',
        conflictKey: <String>['book_uid', 'episode_index'],
        unique: true,
      ),
      MusicTrackUidReference('music_albums', 'cover_track_uid'),
      MusicTrackUidReference(
        'mined_sentences',
        'book_key',
        where: "source = 'music'",
      ),
    ];

/// 收藏句存在偏好里（JSON 列表，`FavoriteSentenceRepository`），音乐来源的出处身份是
/// track uid（`bookKey`）。
const String kFavoriteSentencesPrefKey = 'favorite_sentences';

/// 一首曲目的「同一个文件」判据：路径键 + CUE 起点 + 音频指纹。
typedef MusicTrackIdentityKey = ({
  String pathKey,
  int? cueStartMs,
  int? durationMs,
  int? sampleRate,
  int? channels,
});

MusicTrackIdentityKey _identityOf({
  required String pathKey,
  required int? cueStartMs,
  required int? durationMs,
  required int? sampleRate,
  required int? channels,
}) => (
  pathKey: pathKey,
  cueStartMs: cueStartMs,
  durationMs: durationMs,
  sampleRate: sampleRate,
  channels: channels,
);

/// [_remapScannedMusicTracks] 的结果：传入 uid → 沿用的库内 uid；传入专辑 uid → 库内专辑。
typedef MusicScanUidRemap = ({
  Map<String, String> tracks,
  Map<String, String> albums,
});

/// 同一身份的几行里取胜者：在库（未软删）优先，其次挂在仍存在的来源下，其次最早入库，
/// 最后按 uid 字典序（结果确定）。
int _compareMergeWinner(
  ({String uid, int? deletedAt, bool hasLiveSource, int addedAt}) a,
  ({String uid, int? deletedAt, bool hasLiveSource, int addedAt}) b,
) {
  final int live =
      (a.deletedAt == null ? 0 : 1) - (b.deletedAt == null ? 0 : 1);
  if (live != 0) return live;
  final int source = (a.hasLiveSource ? 0 : 1) - (b.hasLiveSource ? 0 : 1);
  if (source != 0) return source;
  final int added = a.addedAt.compareTo(b.addedAt);
  if (added != 0) return added;
  return a.uid.compareTo(b.uid);
}

/// 扫描批次落库前：库里已有同一个文件（[MusicTrackIdentityKey]）的，沿用它的 uid 与专辑。
/// 只看传入 uid **不在库里**的曲目（在库的就是它自己）。
Future<MusicScanUidRemap> _remapScannedMusicTracks(
  _$FushiDatabase db,
  List<MusicTracksCompanion> tracks,
) async {
  final Map<String, String> trackRemap = <String, String>{};
  final Map<String, String> albumRemap = <String, String>{};
  if (tracks.isEmpty) return (tracks: trackRemap, albums: albumRemap);
  final Set<String> incoming = <String>{
    for (final MusicTracksCompanion t in tracks) t.trackUid.value,
  };
  final Set<String> existing = <String>{};
  final List<String> incomingList = incoming.toList();
  for (int i = 0; i < incomingList.length; i += 500) {
    final List<String> chunk = incomingList.sublist(
      i,
      (i + 500).clamp(0, incomingList.length),
    );
    existing.addAll(
      await (db.selectOnly(db.musicTracks)
            ..addColumns(<Expression<Object>>[db.musicTracks.trackUid])
            ..where(db.musicTracks.trackUid.isIn(chunk)))
          .map((TypedResult r) => r.read(db.musicTracks.trackUid)!)
          .get(),
    );
  }
  final List<MusicTracksCompanion> fresh = <MusicTracksCompanion>[
    for (final MusicTracksCompanion t in tracks)
      if (!existing.contains(t.trackUid.value)) t,
  ];
  if (fresh.isEmpty) return (tracks: trackRemap, albums: albumRemap);
  final List<String> keys = <String>{
    for (final MusicTracksCompanion t in fresh) musicTrackPathKey(t.path.value),
  }.toList();
  final Map<MusicTrackIdentityKey, List<MusicTrackRow>> byIdentity =
      <MusicTrackIdentityKey, List<MusicTrackRow>>{};
  for (int i = 0; i < keys.length; i += 500) {
    final List<String> chunk = keys.sublist(i, (i + 500).clamp(0, keys.length));
    for (final MusicTrackRow row in await (db.select(
      db.musicTracks,
    )..where(($MusicTracksTable t) => t.pathKey.isIn(chunk))).get()) {
      if (incoming.contains(row.trackUid)) continue;
      byIdentity
          .putIfAbsent(
            _identityOf(
              pathKey: row.pathKey!,
              cueStartMs: row.cueStartMs,
              durationMs: row.durationMs,
              sampleRate: row.sampleRate,
              channels: row.channels,
            ),
            () => <MusicTrackRow>[],
          )
          .add(row);
    }
  }
  if (byIdentity.isEmpty) return (tracks: trackRemap, albums: albumRemap);
  final Set<String> knownAlbums = <String>{};
  final Set<String> usedTargets = <String>{};
  for (final MusicTracksCompanion t in fresh) {
    final List<MusicTrackRow>? candidates =
        byIdentity[_identityOf(
          pathKey: musicTrackPathKey(t.path.value),
          cueStartMs: t.cueStartMs.present ? t.cueStartMs.value : null,
          durationMs: t.durationMs.present ? t.durationMs.value : null,
          sampleRate: t.sampleRate.present ? t.sampleRate.value : null,
          channels: t.channels.present ? t.channels.value : null,
        )];
    if (candidates == null) continue;
    final List<MusicTrackRow> sorted =
        candidates
            .where((MusicTrackRow r) => !usedTargets.contains(r.trackUid))
            .toList()
          ..sort(
            (MusicTrackRow a, MusicTrackRow b) => _compareMergeWinner(
              (
                uid: a.trackUid,
                deletedAt: a.deletedAt,
                hasLiveSource: a.sourceId != null,
                addedAt: a.addedAt,
              ),
              (
                uid: b.trackUid,
                deletedAt: b.deletedAt,
                hasLiveSource: b.sourceId != null,
                addedAt: b.addedAt,
              ),
            ),
          );
    if (sorted.isEmpty) continue;
    final MusicTrackRow target = sorted.first;
    usedTargets.add(target.trackUid);
    trackRemap[t.trackUid.value] = target.trackUid;
    final String? incomingAlbum = t.albumUid.present ? t.albumUid.value : null;
    final String? targetAlbum = target.albumUid;
    if (incomingAlbum != null &&
        targetAlbum != null &&
        incomingAlbum != targetAlbum &&
        !albumRemap.containsKey(incomingAlbum)) {
      knownAlbums.add(incomingAlbum);
      albumRemap[incomingAlbum] = targetAlbum;
    }
  }
  if (albumRemap.isNotEmpty) {
    // 传入的专辑 uid 已经在库里（别的曲目早就挂在它上面）就不改：那是一张真实存在的
    // 专辑，不能被一首旧行拽走。
    final Set<String> albumsInDb =
        (await (db.selectOnly(db.musicAlbums)
                  ..addColumns(<Expression<Object>>[db.musicAlbums.albumUid])
                  ..where(db.musicAlbums.albumUid.isIn(knownAlbums)))
                .map((TypedResult r) => r.read(db.musicAlbums.albumUid)!)
                .get())
            .toSet();
    final Set<String> targetsInDb =
        (await (db.selectOnly(db.musicAlbums)
                  ..addColumns(<Expression<Object>>[db.musicAlbums.albumUid])
                  ..where(db.musicAlbums.albumUid.isIn(albumRemap.values)))
                .map((TypedResult r) => r.read(db.musicAlbums.albumUid)!)
                .get())
            .toSet();
    albumRemap.removeWhere(
      (String from, String to) =>
          albumsInDb.contains(from) || !targetsInDb.contains(to),
    );
  }
  return (tracks: trackRemap, albums: albumRemap);
}

/// 把 [batch] 里的 uid 按 [remap] 改写（曲目、署名、专辑与专辑封面曲目）。
MusicScanBatchWrite _applyScanUidRemap(
  MusicScanBatchWrite batch,
  MusicScanUidRemap remap,
) {
  if (remap.tracks.isEmpty && remap.albums.isEmpty) return batch;
  String track(String uid) => remap.tracks[uid] ?? uid;
  String? album(String? uid) => uid == null ? null : remap.albums[uid] ?? uid;
  final Map<String, MusicAlbumsCompanion> albums =
      <String, MusicAlbumsCompanion>{};
  for (final MusicAlbumsCompanion a in batch.albums) {
    final String uid = album(a.albumUid.value)!;
    albums.putIfAbsent(
      uid,
      () => a.copyWith(
        albumUid: Value<String>(uid),
        coverTrackUid: a.coverTrackUid.present && a.coverTrackUid.value != null
            ? Value<String?>(track(a.coverTrackUid.value!))
            : a.coverTrackUid,
      ),
    );
  }
  return MusicScanBatchWrite(
    tracks: <MusicTracksCompanion>[
      for (final MusicTracksCompanion t in batch.tracks)
        t.copyWith(
          trackUid: Value<String>(track(t.trackUid.value)),
          albumUid: t.albumUid.present
              ? Value<String?>(album(t.albumUid.value))
              : t.albumUid,
        ),
    ],
    albums: albums.values.toList(),
    artists: batch.artists,
    credits: <MusicTrackCreditsCompanion>[
      for (final MusicTrackCreditsCompanion c in batch.credits)
        c.copyWith(trackUid: Value<String>(track(c.trackUid.value))),
    ],
  );
}

mixin _FushiDbMusicIdentity on _$FushiDatabase {
  /// 回填 [MusicTracks.pathKey]（v145 迁移；只补 NULL 行，幂等）。[context] 只给测试用。
  Future<int> backfillMusicTrackPathKeys({p.Context? context}) async {
    final List<QueryRow> rows = await customSelect(
      'SELECT track_uid, path FROM music_tracks WHERE path_key IS NULL',
    ).get();
    for (final QueryRow r in rows) {
      await customStatement(
        'UPDATE music_tracks SET path_key = ? WHERE track_uid = ?',
        <Object?>[
          musicTrackPathKey(r.read<String>('path'), context: context),
          r.read<String>('track_uid'),
        ],
      );
    }
    return rows.length;
  }

  /// 把存量重复曲目（同一 [MusicTrackIdentityKey] 的几行）并成一行，返回并掉的行数。
  /// 幂等：并完之后每个身份只剩一行，再跑是空操作。
  Future<int> mergeDuplicateMusicTracks() async {
    // 迁移链里 `media_sources` 不一定在（早期步骤按需建表、只建了曲库的库）：没有来源表
    // 就没有「来源还在」的曲目，按 0 算；SQLite 预编译整条语句，引用不存在的表会直接失败。
    final bool sourcesTable = (await customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' "
      "AND name = 'media_sources'",
    ).get()).isNotEmpty;
    final String hasLiveSource = sourcesTable
        ? '(t.source_id IS NOT NULL AND EXISTS (SELECT 1 FROM media_sources s '
              'WHERE s.id = t.source_id))'
        : '0';
    final List<QueryRow> rows = await customSelect(
      'SELECT t.track_uid, t.path_key, t.cue_start_ms, t.duration_ms, '
      't.sample_rate, t.channels, t.deleted_at, t.added_at, '
      '$hasLiveSource AS has_live_source '
      'FROM music_tracks t WHERE t.path_key IS NOT NULL AND EXISTS ('
      'SELECT 1 FROM music_tracks o WHERE o.path_key = t.path_key '
      'AND o.track_uid != t.track_uid '
      'AND o.cue_start_ms IS t.cue_start_ms)',
    ).get();
    final Map<
      MusicTrackIdentityKey,
      List<({String uid, int? deletedAt, bool hasLiveSource, int addedAt})>
    >
    groups =
        <
          MusicTrackIdentityKey,
          List<({String uid, int? deletedAt, bool hasLiveSource, int addedAt})>
        >{};
    for (final QueryRow r in rows) {
      groups
          .putIfAbsent(
            _identityOf(
              pathKey: r.read<String>('path_key'),
              cueStartMs: r.readNullable<int>('cue_start_ms'),
              durationMs: r.readNullable<int>('duration_ms'),
              sampleRate: r.readNullable<int>('sample_rate'),
              channels: r.readNullable<int>('channels'),
            ),
            () =>
                <
                  ({
                    String uid,
                    int? deletedAt,
                    bool hasLiveSource,
                    int addedAt,
                  })
                >[],
          )
          .add((
            uid: r.read<String>('track_uid'),
            deletedAt: r.readNullable<int>('deleted_at'),
            hasLiveSource: r.read<int>('has_live_source') != 0,
            addedAt: r.read<int>('added_at'),
          ));
    }
    int merged = 0;
    for (final List<
          ({String uid, int? deletedAt, bool hasLiveSource, int addedAt})
        >
        group
        in groups.values) {
      if (group.length < 2) continue;
      group.sort(_compareMergeWinner);
      for (final ({String uid, int? deletedAt, bool hasLiveSource, int addedAt})
          loser
          in group.skip(1)) {
        await mergeMusicTrackInto(loser: loser.uid, winner: group.first.uid);
        merged++;
      }
    }
    return merged;
  }

  /// 把曲目 [loser] 并进 [winner]：记别名、引用改指胜者（[applyMusicTrackUidAliases]）、
  /// 删掉败者行。不写同步墓碑——曲目行是设备本地的，跨设备的用户数据靠别名改指。
  Future<void> mergeMusicTrackInto({
    required String loser,
    required String winner,
  }) async {
    if (loser == winner) return;
    await transaction(() async {
      await customStatement(
        'INSERT INTO music_track_uid_aliases (alias_uid, track_uid, created_at) '
        'VALUES (?, ?, ?) ON CONFLICT (alias_uid) DO UPDATE SET '
        'track_uid = excluded.track_uid',
        <Object?>[loser, winner, DateTime.now().millisecondsSinceEpoch],
      );
      // 以前并进 loser 的别名改指新胜者（别名不成链）。
      await customStatement(
        'UPDATE music_track_uid_aliases SET track_uid = ? WHERE track_uid = ?',
        <Object?>[winner, loser],
      );
      await customStatement(
        'DELETE FROM music_track_uid_aliases WHERE alias_uid = ?',
        <Object?>[winner],
      );
      await applyMusicTrackUidAliases();
      await customStatement(
        'DELETE FROM music_tracks WHERE track_uid = ?',
        <Object?>[loser],
      );
    });
  }

  /// 按 `music_track_uid_aliases` 把所有引用（[kMusicTrackUidReferences] 与收藏句偏好）
  /// 里的败者 uid 改指胜者。幂等；没有别名时是空操作。合并引擎合入「音乐」类别、恢复
  /// 备份之后都要调用：别的设备 / 旧备份里的行可能还挂着败者 uid。
  Future<void> applyMusicTrackUidAliases() async {
    final int aliasCount = await customSelect(
      'SELECT COUNT(*) AS c FROM music_track_uid_aliases',
    ).getSingle().then((QueryRow r) => r.read<int>('c'));
    if (aliasCount == 0) return;
    await transaction(() async {
      for (final MusicTrackUidReference ref in kMusicTrackUidReferences) {
        await _rewriteAliasedReference(ref);
      }
      await _rewriteAliasedFavoriteSentences();
    });
  }

  Future<void> _rewriteAliasedReference(MusicTrackUidReference ref) async {
    final String t = ref.table;
    final String c = ref.column;
    final String scope = ref.where == null ? '' : ' AND (${ref.where})';
    const String aliases = 'music_track_uid_aliases';
    final String target =
        '(SELECT a.track_uid FROM $aliases a WHERE a.alias_uid = $t.$c)';
    final String aliased = '$c IN (SELECT alias_uid FROM $aliases)';
    if (t == 'music_playlist_entries') {
      await _dedupePlaylistEntriesAfterAlias();
    }
    if (!ref.unique) {
      await customStatement('UPDATE $t SET $c = $target WHERE $aliased$scope');
      return;
    }
    final String keyMatch = ref.conflictKey
        .map((String k) => ' AND o.$k IS $t.$k')
        .join();
    final String? lww = ref.lwwColumn;
    if (lww != null) {
      // 胜者已有同键行、但败者那行更新：先删胜者那行，让败者那行改指过去。
      await customStatement(
        'DELETE FROM $t WHERE EXISTS (SELECT 1 FROM $t o '
        'JOIN $aliases a ON a.alias_uid = o.$c '
        'WHERE a.track_uid = $t.$c$keyMatch AND o.$lww > $t.$lww)$scope',
      );
    }
    // 胜者已有同键行：败者那行就是重复，删掉。
    await customStatement(
      'DELETE FROM $t WHERE $aliased$scope AND EXISTS '
      '(SELECT 1 FROM $t o WHERE o.$c = $target$keyMatch)',
    );
    // 两个败者并进同一胜者、键又相同：只留先改过去的一行。
    await customStatement(
      'UPDATE OR IGNORE $t SET $c = $target WHERE $aliased$scope',
    );
    await customStatement('DELETE FROM $t WHERE $aliased$scope');
  }

  /// 同一歌单里败者与胜者都在：改写后会变成同一首出现两次，先删败者那条。用户有意
  /// 放两次的同一首（同一 uid）不受影响。
  Future<void> _dedupePlaylistEntriesAfterAlias() => customStatement(
    'DELETE FROM music_playlist_entries WHERE id IN ('
    'SELECT e.id FROM music_playlist_entries e '
    'JOIN music_track_uid_aliases a ON a.alias_uid = e.track_uid '
    'WHERE EXISTS (SELECT 1 FROM music_playlist_entries o '
    'WHERE o.playlist_uid = e.playlist_uid AND o.track_uid = a.track_uid))',
  );

  Future<void> _rewriteAliasedFavoriteSentences() async {
    final List<QueryRow> prefRows = await customSelect(
      'SELECT value FROM preferences WHERE key = ?',
      variables: <Variable<Object>>[
        const Variable<String>(kFavoriteSentencesPrefKey),
      ],
    ).get();
    if (prefRows.isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(prefRows.first.read<String>('value'));
    } on FormatException {
      return; // 坏 JSON 由收藏句仓库自己报；这里不替它改写。
    }
    if (decoded is! List<Object?>) return;
    final Map<String, String> aliases = <String, String>{
      for (final QueryRow r in await customSelect(
        'SELECT alias_uid, track_uid FROM music_track_uid_aliases',
      ).get())
        r.read<String>('alias_uid'): r.read<String>('track_uid'),
    };
    bool changed = false;
    for (final Object? item in decoded) {
      if (item is! Map<String, Object?>) continue;
      if (item['source'] != 'music') continue;
      final Object? key = item['bookKey'];
      if (key is! String) continue;
      final String? to = aliases[key];
      if (to == null) continue;
      item['bookKey'] = to;
      changed = true;
    }
    if (!changed) return;
    await customStatement(
      'UPDATE preferences SET value = ? WHERE key = ?',
      <Object?>[jsonEncode(decoded), kFavoriteSentencesPrefKey],
    );
  }

  /// 移除音乐来源 [sourceId] 时它名下的曲目怎么办：仍被另一个本地音乐来源覆盖的
  /// （根 = 曲目所在目录，或递归来源包含它）改挂到那个来源——两个来源重叠时曲目的
  /// `source_id` 只记最后扫到它的那个，按 id 一律软删会把仍在另一个来源下的曲目删掉；
  /// 其余软删（与扫描器「文件已不在」同一语义）。[excludeSourceIds] 是同一次操作里也要
  /// 删掉的来源（不能改挂到它们）。返回（改挂数, 软删数）。
  Future<({int reassigned, int softDeleted})> releaseMusicTracksOfSource(
    int sourceId, {
    Set<int> excludeSourceIds = const <int>{},
    p.Context? context,
  }) async {
    final p.Context ctx = context ?? p.context;
    final List<MediaSourceRow> covers =
        <MediaSourceRow>[
          for (final MediaSourceRow s
              in await (select(mediaSources)..where(
                    ($MediaSourcesTable t) =>
                        t.mediaKind.equals('music') &
                        t.transport.equals('local'),
                  ))
                  .get())
            if (s.id != sourceId && !excludeSourceIds.contains(s.id)) s,
        ]..sort(
          // 最具体（根最长）的来源优先。
          (MediaSourceRow a, MediaSourceRow b) =>
              b.rootPath.length.compareTo(a.rootPath.length),
        );
    final List<MusicTrackRow> live =
        await (select(musicTracks)..where(
              ($MusicTracksTable t) =>
                  t.sourceId.equals(sourceId) & t.deletedAt.isNull(),
            ))
            .get();
    int reassigned = 0;
    int softDeleted = 0;
    final int now = DateTime.now().millisecondsSinceEpoch;
    await transaction(() async {
      for (final MusicTrackRow track in live) {
        final String dir = ctx.dirname(track.path);
        MediaSourceRow? cover;
        for (final MediaSourceRow s in covers) {
          if (ctx.equals(s.rootPath, dir) ||
              (s.recursive && ctx.isWithin(s.rootPath, dir))) {
            cover = s;
            break;
          }
        }
        if (cover != null) {
          await (update(musicTracks)..where(
                ($MusicTracksTable t) => t.trackUid.equals(track.trackUid),
              ))
              .write(MusicTracksCompanion(sourceId: Value<int?>(cover.id)));
          reassigned++;
        } else {
          await (update(musicTracks)..where(
                ($MusicTracksTable t) => t.trackUid.equals(track.trackUid),
              ))
              .write(MusicTracksCompanion(deletedAt: Value<int?>(now)));
          softDeleted++;
        }
      }
    });
    return (reassigned: reassigned, softDeleted: softDeleted);
  }

  // ── 自动登记的音乐来源（v145 auto_owner_source_id / music_auto_source_dismissals）──

  /// 视频来源 [ownerId] 自动登记的音乐来源。
  Future<List<MediaSourceRow>> listAutoMusicSourcesOf(int ownerId) =>
      (select(mediaSources)..where(
            ($MediaSourcesTable t) =>
                t.mediaKind.equals('music') &
                t.autoOwnerSourceId.equals(ownerId),
          ))
          .get();

  /// 改来源的归属：[ownerId] 为 null = 转为用户手动添加的来源。
  Future<void> setMediaSourceAutoOwner(int id, int? ownerId) =>
      (update(
        mediaSources,
      )..where(($MediaSourcesTable t) => t.id.equals(id))).write(
        MediaSourcesCompanion(autoOwnerSourceId: Value<int?>(ownerId)),
      );

  /// 改来源的「含子文件夹」。
  Future<void> updateMediaSourceRecursive(int id, bool recursive) =>
      (update(mediaSources)..where(($MediaSourcesTable t) => t.id.equals(id)))
          .write(MediaSourcesCompanion(recursive: Value<bool>(recursive)));

  /// 记下「用户删掉了 owner [ownerId] 自动添加的 [rootPath]」，之后不再登记回来。
  Future<void> addMusicAutoSourceDismissal(int ownerId, String rootPath) =>
      into(musicAutoSourceDismissals).insertOnConflictUpdate(
        MusicAutoSourceDismissalsCompanion.insert(
          ownerSourceId: ownerId,
          rootPath: rootPath,
          dismissedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

  /// owner [ownerId] 名下被用户删掉过的自动来源根。
  Future<List<String>> musicAutoSourceDismissalsOf(int ownerId) =>
      (select(musicAutoSourceDismissals)..where(
            ($MusicAutoSourceDismissalsTable t) =>
                t.ownerSourceId.equals(ownerId),
          ))
          .map((MusicAutoSourceDismissalRow r) => r.rootPath)
          .get();

  /// 用户手动添加了 [rootPath]：解除所有 owner 对它的「不再登记」。
  Future<void> clearMusicAutoSourceDismissalsForRoot(String rootPath) =>
      (delete(musicAutoSourceDismissals)..where(
            ($MusicAutoSourceDismissalsTable t) => t.rootPath.equals(rootPath),
          ))
          .go();
}

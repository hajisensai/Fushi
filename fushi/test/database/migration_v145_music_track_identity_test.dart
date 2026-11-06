// v145（反馈 QAondMh4M5）：同一个文件在曲库里只有一行。
//
// 旧版本扫描器拼出的曲目路径随扫描根的写法而变，同一个文件从不同的根进来就是两个 uid、
// 两行。承重的是：迁移把存量重复行并成一行、所有引用改指胜者、记 uid 别名；之后扫描
// 落库按路径键沿用旧 uid，不再产生重复；移除音乐来源时仍被别的来源覆盖的曲目改挂过去。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show QueryRow, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// 宿主平台上「同一个文件」的两种旧拼法（与 Rust 旧扫描器拼出的一致）。
({String a, String b}) _twoSpellings(String name) {
  if (p.style == p.Style.windows) {
    return (a: 'C:/Music/Album\\$name', b: 'C:/Music\\Album\\$name');
  }
  return (a: '/music/album/$name', b: '/music//album/./$name');
}

MusicTracksCompanion _track(
  String uid,
  String path, {
  int? sourceId,
  int addedAt = 1,
  int durationMs = 1000,
  String? albumUid,
}) => MusicTracksCompanion.insert(
  trackUid: uid,
  sourceId: Value<int?>(sourceId),
  path: path,
  durationMs: Value<int?>(durationMs),
  sampleRate: const Value<int?>(44100),
  channels: const Value<int?>(2),
  title: uid,
  albumUid: Value<String?>(albumUid),
  fileMtimeAt: 1,
  fileSize: 1,
  addedAt: addedAt,
);

Future<List<String>> _col(FushiDatabase db, String sql) async => <String>[
  for (final QueryRow r in await db.customSelect(sql).get())
    r.data.values.first as String,
];

void main() {
  group('musicTrackPathKey', () {
    test('Windows：分隔符与大小写不同的写法同一个键', () {
      final String k = musicTrackPathKey(
        r'C:/Music\Album\x.flac',
        context: p.windows,
      );
      expect(
        musicTrackPathKey(r'c:\music\album\X.FLAC', context: p.windows),
        k,
      );
      expect(musicTrackPathKey('C:/Music/Album/x.flac', context: p.windows), k);
      expect(
        musicTrackPathKey('C:/Music/Album/y.flac', context: p.windows),
        isNot(k),
      );
    });

    test('POSIX：只做词法归一，大小写敏感', () {
      expect(
        musicTrackPathKey('/music//album/./x.flac', context: p.posix),
        musicTrackPathKey('/music/album/x.flac', context: p.posix),
      );
      expect(
        musicTrackPathKey('/Music/x.flac', context: p.posix),
        isNot(musicTrackPathKey('/music/x.flac', context: p.posix)),
      );
    });
  });

  test('v144 → v145：存量重复曲目并成一行，引用改指胜者，记别名；再开一次不变', () async {
    final Directory dir = Directory.systemTemp.createTempSync('mus145');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/test.db';
    final FushiDatabase fresh = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    final int source = await fresh.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Music',
        mediaKind: 'music',
        rootPath: 'C:/Music',
        createdAt: 1,
      ),
    );
    await fresh.close();

    final ({String a, String b}) x = _twoSpellings('x.flac');
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP INDEX idx_music_tracks_path_key');
    raw.execute('ALTER TABLE music_tracks DROP COLUMN path_key');
    raw.execute('DROP TABLE music_track_uid_aliases');
    raw.execute('DROP TABLE music_auto_source_dismissals');
    // 胜者：挂在仍存在的来源下（loser 入库更早但来源已没了）。
    raw.execute(
      'INSERT INTO music_tracks (track_uid, source_id, path, duration_ms, '
      'sample_rate, channels, title, file_mtime_at, file_size, added_at, '
      'is_lossless, has_embedded_cover) VALUES '
      "('win', $source, ?, 1000, 44100, 2, 'x', 1, 1, 5, 0, 0), "
      "('lose', 999, ?, 1000, 44100, 2, 'x', 1, 1, 2, 0, 0), "
      // 同路径但音频指纹不同（换过文件）：不是同一首，不并。
      "('other', $source, ?, 2000, 44100, 2, 'x', 1, 1, 1, 0, 0)",
      <Object?>[x.a, x.b, x.a],
    );
    raw.execute(
      'INSERT INTO music_playlists (playlist_uid, name, created_at, updated_at) '
      "VALUES ('pl', 'L', 1, 1), ('pl2', 'M', 1, 1)",
    );
    raw.execute(
      'INSERT INTO music_playlist_entries (playlist_uid, track_uid, position, '
      "added_at) VALUES ('pl', 'win', 0, 1), ('pl', 'lose', 1, 1), "
      "('pl2', 'lose', 0, 1)",
    );
    raw.execute(
      'INSERT INTO music_lyrics (track_uid, source, format, raw, updated_at) '
      "VALUES ('win', 'user', 'lrc', x'61', 10), ('lose', 'user', 'lrc', x'62', 20)",
    );
    raw.execute(
      'INSERT INTO music_play_events (track_uid, started_at) VALUES '
      "('win', 100), ('lose', 100), ('lose', 200)",
    );
    raw.execute(
      'INSERT INTO mined_sentences (source, book_key, date_key, created_at) '
      "VALUES ('music', 'lose', '2026-11-06', 1), ('book', 'lose', '2026-11-06', 1)",
    );
    raw.execute(
      "INSERT INTO preferences (key, value, updated_at) VALUES ('favorite_sentences', ?, 1)",
      <Object?>[
        jsonEncode(<Map<String, Object?>>[
          <String, Object?>{'source': 'music', 'bookKey': 'lose', 'text': 'a'},
          <String, Object?>{'source': 'book', 'bookKey': 'lose', 'text': 'b'},
        ]),
      ],
    );
    raw.execute('PRAGMA user_version = 144');
    raw.dispose();

    Future<void> check(FushiDatabase db) async {
      expect(db.schemaVersion, 146);
      expect(
        await _col(db, 'SELECT track_uid FROM music_tracks ORDER BY track_uid'),
        <String>['other', 'win'],
      );
      expect(
        await _col(
          db,
          "SELECT track_uid FROM music_playlist_entries WHERE playlist_uid='pl' "
          'ORDER BY position',
        ),
        <String>['win'],
        reason: '同一歌单里败者与胜者都在：去掉败者那条，不重复',
      );
      expect(
        await _col(
          db,
          "SELECT track_uid FROM music_playlist_entries WHERE playlist_uid='pl2'",
        ),
        <String>['win'],
      );
      final QueryRow lyric = await db
          .customSelect('SELECT track_uid, raw FROM music_lyrics')
          .getSingle();
      expect(lyric.read<String>('track_uid'), 'win');
      expect(
        utf8.decode(lyric.read<Uint8List>('raw')),
        'b',
        reason: '同来源歌词 LWW：败者那份更新，留它',
      );
      expect(
        await _col(
          db,
          'SELECT track_uid || started_at FROM music_play_events '
          'ORDER BY started_at',
        ),
        <String>['win100', 'win200'],
      );
      expect(
        await _col(
          db,
          'SELECT source || book_key FROM mined_sentences ORDER BY source',
        ),
        <String>['booklose', 'musicwin'],
        reason: '只改音乐来源的出处',
      );
      final List<Object?> favs =
          jsonDecode((await db.getPref(kFavoriteSentencesPrefKey))!)
              as List<Object?>;
      expect(
        <Object?>[
          for (final Object? f in favs) (f! as Map<String, Object?>)['bookKey'],
        ],
        <String>['win', 'lose'],
      );
      expect(
        await _col(
          db,
          'SELECT alias_uid || track_uid FROM music_track_uid_aliases',
        ),
        <String>['losewin'],
      );
      expect(
        await _col(db, 'SELECT path_key FROM music_tracks GROUP BY path_key'),
        <String>[musicTrackPathKey(x.a)],
      );
    }

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await check(migrated);
    // 幂等：再并一次、再回填一次都是空操作。
    expect(await migrated.mergeDuplicateMusicTracks(), 0);
    expect(await migrated.backfillMusicTrackPathKeys(), 0);
    await migrated.applyMusicTrackUidAliases();
    await check(migrated);
    await migrated.close();
  });

  group('writeMusicScanBatch', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    MusicScanBatchWrite batchOf(
      List<MusicTracksCompanion> tracks, {
      List<MusicAlbumsCompanion> albums = const <MusicAlbumsCompanion>[],
    }) => MusicScanBatchWrite(
      tracks: tracks,
      albums: albums,
      artists: const <MusicArtistsCompanion>[],
      credits: <MusicTrackCreditsCompanion>[
        for (final MusicTracksCompanion t in tracks)
          MusicTrackCreditsCompanion.insert(
            trackUid: t.trackUid.value,
            artistUid: 'ar',
            role: 'artist',
            creditName: 'A',
          ),
      ],
    );

    test('同一个文件换了拼法再扫到：沿用库里的 uid 与专辑，路径改成新拼法，曲库仍一行', () async {
      final ({String a, String b}) x = _twoSpellings('x.flac');
      await db.writeMusicScanBatch(
        batchOf(
          <MusicTracksCompanion>[_track('old', x.a, albumUid: 'albOld')],
          albums: <MusicAlbumsCompanion>[
            MusicAlbumsCompanion.insert(
              albumUid: 'albOld',
              title: 'Album',
              addedAt: 1,
              updatedAt: 1,
            ),
          ],
        ),
      );
      final Map<String, String> remap = await db.writeMusicScanBatch(
        batchOf(
          <MusicTracksCompanion>[
            _track('new', x.b, albumUid: 'albNew', addedAt: 9),
          ],
          albums: <MusicAlbumsCompanion>[
            MusicAlbumsCompanion.insert(
              albumUid: 'albNew',
              title: 'Album',
              coverTrackUid: const Value<String?>('new'),
              addedAt: 9,
              updatedAt: 9,
            ),
          ],
        ),
      );
      expect(remap, <String, String>{'new': 'old'});
      final List<MusicTrackRow> rows = await db.select(db.musicTracks).get();
      expect(rows.single.trackUid, 'old');
      expect(rows.single.path, x.b);
      expect(rows.single.albumUid, 'albOld');
      expect(rows.single.addedAt, 1, reason: '入库时刻不被冲掉');
      expect(await _col(db, 'SELECT album_uid FROM music_albums'), <String>[
        'albOld',
      ]);
      expect(
        await _col(db, 'SELECT cover_track_uid FROM music_albums'),
        <String>['old'],
      );
      expect(
        await _col(db, 'SELECT track_uid FROM music_track_credits'),
        <String>['old'],
      );
    });

    test('音频指纹不同（文件换过）不算同一首：新 uid 新行', () async {
      final ({String a, String b}) x = _twoSpellings('x.flac');
      await db.writeMusicScanBatch(
        batchOf(<MusicTracksCompanion>[_track('old', x.a)]),
      );
      final Map<String, String> remap = await db.writeMusicScanBatch(
        batchOf(<MusicTracksCompanion>[_track('new', x.b, durationMs: 5)]),
      );
      expect(remap, isEmpty);
      expect(await db.select(db.musicTracks).get(), hasLength(2));
    });
  });

  test('releaseMusicTracksOfSource：仍被别的本地音乐来源覆盖的曲目改挂过去，其余软删', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final String root = p.join(p.rootPrefix(p.current), 'm');
    Future<int> src(String path, {bool recursive = true}) =>
        db.insertMediaSource(
          MediaSourcesCompanion.insert(
            label: path,
            mediaKind: 'music',
            rootPath: normalizeSourceRootPath(path, transport: 'local'),
            recursive: Value<bool>(recursive),
            createdAt: 1,
          ),
        );
    final int upper = await src(root);
    final int inner = await src(p.join(root, 'A'));
    final int flat = await src(p.join(root, 'B'), recursive: false);
    await db.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[
          _track('a', p.join(root, 'A', '1.flac'), sourceId: inner),
          _track('b', p.join(root, 'B', '1.flac'), sourceId: inner),
          _track('c', p.join(root, 'B', 'sub', '1.flac'), sourceId: inner),
        ],
        albums: const <MusicAlbumsCompanion>[],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );
    final ({int reassigned, int softDeleted}) r = await db
        .releaseMusicTracksOfSource(inner, excludeSourceIds: <int>{upper});
    expect(r, (reassigned: 1, softDeleted: 2));
    final Map<String, MusicTrackRow> byUid = <String, MusicTrackRow>{
      for (final MusicTrackRow t in await db.select(db.musicTracks).get())
        t.trackUid: t,
    };
    expect(byUid['a']!.deletedAt, isNotNull, reason: '只剩 upper，但它也要删');
    expect(byUid['b']!.sourceId, flat);
    expect(byUid['c']!.deletedAt, isNotNull, reason: '非递归来源不含子目录');
    expect(byUid['b']!.deletedAt, isNull);
  });

  test('守卫：schema 里每一列曲目 uid 引用都登记在 kMusicTrackUidReferences', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final Set<String> registered = <String>{
      for (final MusicTrackUidReference r in kMusicTrackUidReferences)
        '${r.table}.${r.column}',
    };
    const Set<String> exempt = <String>{
      'music_tracks.track_uid', // 主键本身，由 mergeMusicTrackInto 删败者行
      'music_track_uid_aliases.track_uid', // 别名表自己
    };
    final List<String> found = <String>[];
    for (final QueryRow t
        in await db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'table' "
              "AND name NOT LIKE 'sqlite_%'",
            )
            .get()) {
      final String table = t.read<String>('name');
      for (final QueryRow c
          in await db.customSelect("PRAGMA table_info('$table')").get()) {
        final String col = c.read<String>('name');
        if (col == 'track_uid' || col.endsWith('_track_uid')) {
          found.add('$table.$col');
        }
      }
    }
    expect(found, isNotEmpty);
    for (final String f in found) {
      if (exempt.contains(f)) continue;
      expect(registered, contains(f), reason: '$f 引用曲目 uid，合并重复曲目时要改写');
    }
    // 用表 + source 区分的共用表：手工登记，这里钉住不被删掉。
    expect(
      registered,
      containsAll(<String>[
        'mined_sentences.book_key',
        'music_locked_fields.entity_uid',
      ]),
    );
  });
}

import 'dart:io';

import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_format_badge.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_library_scanner.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';

MusicScannedTrack _track(
  String uid, {
  String path = '/m/a.flac',
  String? album = 'Album',
  String? albumUid = 'al',
  String? albumArtist = 'X',
  String? cover,
  bool embedded = false,
  int? start,
  List<MusicScanCredit> credits = const <MusicScanCredit>[
    MusicScanCredit(role: 'artist', name: 'X', artistUid: 'ax'),
    MusicScanCredit(role: 'album_artist', name: 'X', artistUid: 'ax'),
  ],
}) => MusicScannedTrack(
  path: path,
  trackUid: uid,
  cueStartMs: start,
  cueEndMs: null,
  durationMs: 1000,
  codec: 'flac',
  sampleRate: 96000,
  bitDepth: 24,
  channels: 2,
  bitrateKbps: 3000,
  isLossless: true,
  title: 'title-$uid',
  titleSort: null,
  artistCredit: 'X',
  albumTitle: album,
  albumTitleSort: null,
  albumArtist: albumArtist,
  albumUid: albumUid,
  discNo: 1,
  discTotal: 1,
  trackNo: 1,
  year: 2020,
  releaseDate: '2020',
  genre: null,
  catalogNo: null,
  rgTrackGain: -6,
  rgTrackPeak: 0.9,
  rgAlbumGain: -5,
  rgAlbumPeak: 0.95,
  mbRecordingId: null,
  mbWorkId: null,
  mbReleaseId: null,
  mbReleaseGroupId: null,
  fileMtimeMs: 10,
  fileSize: 20,
  hasEmbeddedCover: embedded,
  folderCoverPath: cover,
  cueSheetPath: null,
  credits: credits,
);

/// 按顺序把预设批次喂给扫描器，并记下扫描器传来的已知文件清单。
class _ScriptedScanner {
  _ScriptedScanner(this.batches);

  final List<List<MusicScanRecord>> batches;
  Map<String, ({int mtimeMs, int size})>? lastKnown;

  Stream<MusicScanBatch> call(
    String root, {
    bool recursive = true,
    Map<String, ({int mtimeMs, int size})> known =
        const <String, ({int mtimeMs, int size})>{},
  }) async* {
    lastKnown = known;
    for (int i = 0; i < batches.length; i++) {
      yield MusicScanBatch(done: i == batches.length - 1, records: batches[i]);
    }
  }
}

/// 数归组读了多少行：同时涉及曲目表与专辑表的查询（按目录 / 专辑名归组要两边一起读）
/// 返回的行数。扫描开头取已知文件清单、收尾找消失曲目都只读曲目表，不算在内。
class _MusicReadCounter extends QueryInterceptor {
  int groupingRows = 0;

  void reset() => groupingRows = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final List<Map<String, Object?>> rows = await executor.runSelect(
      statement,
      args,
    );
    if (statement.contains('music_tracks') &&
        statement.contains('music_albums')) {
      groupingRows += rows.length;
    }
    return rows;
  }
}

String _fixtureRoot() {
  Directory dir = Directory.current.absolute;
  for (int i = 0; i < 6; i++) {
    final Directory c = Directory(
      '${dir.path}/native/fushi_music/tests/fixtures/library',
    );
    if (c.existsSync()) return c.path;
    dir = dir.parent;
  }
  throw StateError('fixtures not found');
}

void main() {
  late FushiDatabase db;
  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('批次换算：同专辑封面取第一个有的；没封面不写封面列', () {
    final MusicScanBatchWrite w = musicScanBatchWriteOf(
      <MusicScannedTrack>[
        _track('t1'),
        _track('t2', cover: '/m/cover.jpg', embedded: true),
        _track('t3'),
      ],
      sourceId: 1,
      now: 5,
    );
    expect(w.tracks, hasLength(3));
    expect(w.albums, hasLength(1));
    expect(w.albums.single.coverPath.value, '/m/cover.jpg');
    expect(w.albums.single.coverTrackUid.value, 't2');
    expect(w.artists, hasLength(1));
    expect(w.credits, hasLength(6));
    final MusicScanBatchWrite none = musicScanBatchWriteOf(
      <MusicScannedTrack>[_track('t9')],
      sourceId: 1,
      now: 5,
    );
    expect(none.albums.single.coverPath.present, isFalse);
  });

  test('BUG-4493 存量：解析修订号变了就不传已知文件、整源重新解析，'
      '已入库的合写署名被重写成一人一位艺人；修订号没变照常增量', () async {
    const List<MusicScanCredit> combined = <MusicScanCredit>[
      MusicScanCredit(role: 'artist', name: '藤澤慶昌&加藤達也', artistUid: 'combo'),
    ];
    const List<MusicScanCredit> split = <MusicScanCredit>[
      MusicScanCredit(role: 'artist', name: '藤澤慶昌', artistUid: 'fuji'),
      MusicScanCredit(role: 'artist', name: '加藤達也', artistUid: 'kato'),
    ];
    Future<_ScriptedScanner> scan(
      int revision,
      List<MusicScanRecord> records,
    ) async {
      final _ScriptedScanner s = _ScriptedScanner(<List<MusicScanRecord>>[
        records,
      ]);
      await MusicLibraryScanner(
        db,
        scanner: s.call,
        parserRevision: () => revision,
      ).scanSource(sourceId: 3, rootPath: '/m');
      return s;
    }

    Future<Set<String>> artistNames() async =>
        (await db.listMusicArtists()).map((MusicArtistRow a) => a.name).toSet();
    const String key = '${kMusicScanParserRevisionPrefKeyPrefix}3';

    // 旧解析器（修订号 0）入的库：合写串整个是一位艺人。
    final _ScriptedScanner old = await scan(0, <MusicScanRecord>[
      _track('a1', credits: combined),
    ]);
    expect(old.lastKnown, isEmpty);
    expect(await artistNames(), <String>{'藤澤慶昌&加藤達也'});
    expect(await db.getPref(key), '0');

    // 修订号没变：增量，文件没动就只报 unchanged，署名原样。
    final _ScriptedScanner same = await scan(0, <MusicScanRecord>[
      const MusicScanUnchanged('/m/a.flac'),
    ]);
    expect(same.lastKnown?.keys.toSet(), <String>{'/m/a.flac'});
    expect(await artistNames(), <String>{'藤澤慶昌&加藤達也'});

    // 升级到新解析器：文件 mtime / size 没变也不传已知清单，重新解析后 credits 重写。
    final _ScriptedScanner bumped = await scan(1, <MusicScanRecord>[
      _track('a1', credits: split),
    ]);
    expect(bumped.lastKnown, isEmpty);
    expect(await artistNames(), <String>{'藤澤慶昌', '加藤達也'});
    expect(await db.getPref(key), '1');
    expect((await db.listMusicTracks()).single.trackUid, 'a1');

    // 记下新修订号之后回到增量。
    final _ScriptedScanner after = await scan(1, <MusicScanRecord>[
      const MusicScanUnchanged('/m/a.flac'),
    ]);
    expect(after.lastKnown?.keys.toSet(), <String>{'/m/a.flac'});
    expect(await artistNames(), <String>{'藤澤慶昌', '加藤達也'});
  });

  test('解析修订号偏好是设备本地状态：不进备份 / Profile 快照 / 设置同步', () {
    expect(
      PrefRedactionPolicy.isDeviceLocalOrCredential(
        '${kMusicScanParserRevisionPrefKeyPrefix}3',
      ),
      isTrue,
    );
  });

  test('BUG-5080：同目录同一张 CD 只有部分曲目写了专辑艺人，扫完并回一张；'
      '不同目录、专辑艺人不止一位的不动', () async {
    final _ScriptedScanner s = _ScriptedScanner(<List<MusicScanRecord>>[
      <MusicScanRecord>[
        // 第 1 首带专辑艺人 → (艺人, 专辑名) uid；2、3 首没写 → (目录, 专辑名) uid。
        _track(
          'h1',
          path: '/m/CDBOX/01.flac',
          album: 'Here, the world!',
          albumUid: 'artist-uid',
        ),
        _track(
          'h2',
          path: '/m/CDBOX/02.flac',
          album: 'Here，ｔｈｅ world! ',
          albumUid: 'dir-uid',
          albumArtist: null,
        ),
        _track(
          'h3',
          path: '/m/CDBOX/03.flac',
          album: 'Here, the world!',
          albumUid: 'dir-uid',
          albumArtist: null,
        ),
        // 别的目录的同名无艺人专辑：不是同一张，不动。
        _track(
          'o1',
          path: '/m/other/01.flac',
          album: 'Here, the world!',
          albumUid: 'other-dir-uid',
          albumArtist: null,
        ),
        // 同目录两位不同专辑艺人 + 一张无艺人：说不清归谁，不动。
        _track('v1', path: '/m/VA/01.flac', album: 'Best', albumUid: 'va-a'),
        _track(
          'v2',
          path: '/m/VA/02.flac',
          album: 'Best',
          albumUid: 'va-b',
          albumArtist: 'Y',
        ),
        _track(
          'v3',
          path: '/m/VA/03.flac',
          album: 'Best',
          albumUid: 'va-dir',
          albumArtist: null,
        ),
      ],
    ]);
    await MusicLibraryScanner(
      db,
      scanner: s.call,
    ).scanSource(sourceId: 1, rootPath: '/m');
    final Map<String, String?> albumOf = <String, String?>{
      for (final MusicTrackRow t in await db.listMusicTracks())
        t.trackUid: t.albumUid,
    };
    expect(albumOf['h1'], 'artist-uid');
    expect(albumOf['h2'], 'artist-uid');
    expect(albumOf['h3'], 'artist-uid');
    expect(albumOf['o1'], 'other-dir-uid');
    expect(
      <String?>[albumOf['v1'], albumOf['v2'], albumOf['v3']],
      <String>['va-a', 'va-b', 'va-dir'],
    );
    // 被并空的旧专辑行不再列出。
    final Set<String> listed = <String>{
      for (final MusicAlbumRow a in await db.listMusicAlbums()) a.albumUid,
    };
    expect(listed, isNot(contains('dir-uid')));
    expect(listed, contains('artist-uid'));
  });

  test('HBK-AUDIT-027：并入后的无艺人曲目保留原始归属，增量扫描在受影响的组上重算——'
      '新加第二位艺人的同名专辑就退回自己那张，那张再消失又并回去，带艺人的全没了也退回', () async {
    MusicScannedTrack cd(
      String uid,
      String file,
      String albumUid,
      String? by,
    ) => _track(
      uid,
      path: '/m/CD/$file',
      album: 'Best',
      albumUid: albumUid,
      albumArtist: by,
    );
    Future<Map<String, String?>> scan(List<MusicScanRecord> records) async {
      await MusicLibraryScanner(
        db,
        scanner: _ScriptedScanner(<List<MusicScanRecord>>[records]).call,
      ).scanSource(sourceId: 1, rootPath: '/m');
      return <String, String?>{
        for (final MusicTrackRow t in await db.listMusicTracks())
          t.trackUid: t.albumUid,
      };
    }

    // 第一次：01 带专辑艺人 X，02 没写 → 02 并到 X 那张。
    Map<String, String?> albumOf = await scan(<MusicScanRecord>[
      cd('h1', '01.flac', 'x-uid', 'X'),
      cd('h2', '02.flac', 'dir-uid', null),
    ]);
    expect(albumOf, <String, String?>{'h1': 'x-uid', 'h2': 'x-uid'});

    // 增量：01 / 02 没变（不重新解析），新加 03 带另一位专辑艺人 Y：
    // 同目录同名有两位艺人，说不清 02 归谁 → 02 退回按标签算出的原专辑。
    albumOf = await scan(<MusicScanRecord>[
      const MusicScanUnchanged('/m/CD/01.flac'),
      const MusicScanUnchanged('/m/CD/02.flac'),
      cd('y1', '03.flac', 'y-uid', 'Y'),
    ]);
    expect(albumOf, <String, String?>{
      'h1': 'x-uid',
      'h2': 'dir-uid',
      'y1': 'y-uid',
    });

    // 03 被删：又只剩一位艺人 → 02 再并回 X。
    albumOf = await scan(<MusicScanRecord>[
      const MusicScanUnchanged('/m/CD/01.flac'),
      const MusicScanUnchanged('/m/CD/02.flac'),
    ]);
    expect(albumOf, <String, String?>{'h1': 'x-uid', 'h2': 'x-uid'});

    // 01 也被删：没有带艺人的了 → 02 回到自己那张，不再挂在 X 名下。
    albumOf = await scan(<MusicScanRecord>[
      const MusicScanUnchanged('/m/CD/02.flac'),
    ]);
    expect(albumOf, <String, String?>{'h2': 'dir-uid'});
  });

  test('HBK-AUDIT-027：零变化的增量扫描收尾不读整源做归组；'
      '有变化时只读受影响目录', () async {
    final _MusicReadCounter counter = _MusicReadCounter();
    await db.close();
    db = FushiDatabase.forTesting(
      NativeDatabase.memory().interceptWith(counter),
    );
    final List<MusicScanRecord> first = <MusicScanRecord>[
      for (int d = 0; d < 20; d++)
        for (int i = 0; i < 10; i++)
          _track(
            'd$d-$i',
            path: '/m/D$d/$i.flac',
            album: 'Album $d',
            albumUid: i == 0 ? 'tag-$d' : 'dir-$d',
            albumArtist: i == 0 ? 'X' : null,
          ),
    ];
    await MusicLibraryScanner(
      db,
      scanner: _ScriptedScanner(<List<MusicScanRecord>>[first]).call,
    ).scanSource(sourceId: 1, rootPath: '/m');
    expect(
      (await db.listMusicTracks())
          .where((MusicTrackRow t) => t.albumUid!.startsWith('dir-'))
          .toList(),
      isEmpty,
    );

    // 200 首全没变。
    counter.reset();
    await MusicLibraryScanner(
      db,
      scanner: _ScriptedScanner(<List<MusicScanRecord>>[
        <MusicScanRecord>[
          for (int d = 0; d < 20; d++)
            for (int i = 0; i < 10; i++) MusicScanUnchanged('/m/D$d/$i.flac'),
        ],
      ]).call,
    ).scanSource(sourceId: 1, rootPath: '/m');
    // ignore: avoid_print
    print('zero-change regroup rows read: ${counter.groupingRows}');
    expect(counter.groupingRows, 0);

    // 只有 D3 新加一首：归组只读 D3 这一个目录（10 + 1 行）。
    counter.reset();
    await MusicLibraryScanner(
      db,
      scanner: _ScriptedScanner(<List<MusicScanRecord>>[
        <MusicScanRecord>[
          for (int d = 0; d < 20; d++)
            for (int i = 0; i < 10; i++) MusicScanUnchanged('/m/D$d/$i.flac'),
          _track(
            'new',
            path: '/m/D3/new.flac',
            album: 'Album 3',
            albumUid: 'dir-3',
            albumArtist: null,
          ),
        ],
      ]).call,
    ).scanSource(sourceId: 1, rootPath: '/m');
    // ignore: avoid_print
    print('one-dir-change regroup rows read: ${counter.groupingRows}');
    expect(counter.groupingRows, lessThanOrEqualTo(11));
    expect(
      (await db.listMusicTracks(
        albumUid: 'tag-3',
      )).map((MusicTrackRow t) => t.trackUid),
      contains('new'),
    );
  });

  test('重扫：没变的文件经 unchanged 保留（含 CUE 多首），消失的软删', () async {
    final _ScriptedScanner first = _ScriptedScanner(<List<MusicScanRecord>>[
      <MusicScanRecord>[
        _track('a1', path: '/m/a.flac'),
        _track('c1', path: '/m/cue.flac', start: 0),
      ],
      <MusicScanRecord>[
        _track('c2', path: '/m/cue.flac', start: 1000),
        _track('gone', path: '/m/gone.flac'),
      ],
    ]);
    final MusicScanSummary s1 = await MusicLibraryScanner(
      db,
      scanner: first.call,
    ).scanSource(sourceId: 1, rootPath: '/m');
    expect(s1.trackCount, 4);
    expect(s1.parsedTrackCount, 4);
    expect(first.lastKnown, isEmpty);

    final _ScriptedScanner second = _ScriptedScanner(<List<MusicScanRecord>>[
      <MusicScanRecord>[
        const MusicScanUnchanged('/m/a.flac'),
        const MusicScanUnchanged('/m/cue.flac'),
        const MusicScanError('/m/bad.ape', 'corrupt'),
      ],
    ]);
    final MusicScanSummary s2 = await MusicLibraryScanner(
      db,
      scanner: second.call,
    ).scanSource(sourceId: 1, rootPath: '/m');
    expect(second.lastKnown?.keys.toSet(), <String>{
      '/m/a.flac',
      '/m/cue.flac',
      '/m/gone.flac',
    });
    expect(second.lastKnown?['/m/a.flac'], (mtimeMs: 10, size: 20));
    expect(s2.trackCount, 3);
    expect(s2.removedTrackCount, 1);
    expect(s2.errorSummary, contains('/m/bad.ape'));
    expect(
      (await db.listMusicTracks()).map((MusicTrackRow t) => t.trackUid).toSet(),
      <String>{'a1', 'c1', 'c2'},
    );
  });

  test('从音乐库移除（墓碑，拍板台 IDeN5PYaI7）：重扫不论整首重新解析还是「没变」都不复活', () async {
    final _ScriptedScanner first = _ScriptedScanner(<List<MusicScanRecord>>[
      <MusicScanRecord>[
        _track('a1', path: '/m/a.flac'),
        _track('b1', path: '/m/b.flac'),
      ],
    ]);
    await MusicLibraryScanner(
      db,
      scanner: first.call,
    ).scanSource(sourceId: 1, rootPath: '/m');
    await db.hideMusicTracks(<String>['a1'], at: 5);

    // 文件动过：Rust 整首重新解析报回同一个 uid。
    final _ScriptedScanner reparsed = _ScriptedScanner(<List<MusicScanRecord>>[
      <MusicScanRecord>[
        _track('a1', path: '/m/a.flac'),
        const MusicScanUnchanged('/m/b.flac'),
      ],
    ]);
    final MusicScanSummary s2 = await MusicLibraryScanner(
      db,
      scanner: reparsed.call,
    ).scanSource(sourceId: 1, rootPath: '/m');
    expect(reparsed.lastKnown?.keys.toSet(), <String>{
      '/m/a.flac',
      '/m/b.flac',
    }, reason: '移除过的文件也算已知：没变就不必每次重新解析');
    expect(s2.removedTrackCount, 0);
    expect(
      (await db.listMusicTracks()).map((MusicTrackRow t) => t.trackUid),
      <String>['b1'],
    );

    // 文件没动：报「没变」。
    final _ScriptedScanner unchanged = _ScriptedScanner(<List<MusicScanRecord>>[
      <MusicScanRecord>[
        const MusicScanUnchanged('/m/a.flac'),
        const MusicScanUnchanged('/m/b.flac'),
      ],
    ]);
    await MusicLibraryScanner(
      db,
      scanner: unchanged.call,
    ).scanSource(sourceId: 1, rootPath: '/m');
    expect(
      (await db.listMusicTracks()).map((MusicTrackRow t) => t.trackUid),
      <String>['b1'],
    );
    expect((await db.getMusicTrack('a1'))!.hiddenAt, 5);
  });

  test('库里是旧版本的混合分隔符拼法（v145）：Rust 按统一拼法报「没变」不被误删；'
      '文件变了重新解析时沿用旧 uid，曲库仍是那几行', () async {
    final bool win = Platform.isWindows;
    final String legacyA = win ? r'C:/m\a.flac' : '/m//a.flac';
    final String legacyB = win ? r'C:/m\b.flac' : '/m/./b.flac';
    final String canonA = win ? r'C:\m\a.flac' : '/m/a.flac';
    final String canonB = win ? r'C:\m\b.flac' : '/m/b.flac';
    final _ScriptedScanner first = _ScriptedScanner(<List<MusicScanRecord>>[
      <MusicScanRecord>[
        _track('legacyA', path: legacyA),
        _track('legacyB', path: legacyB),
      ],
    ]);
    await MusicLibraryScanner(
      db,
      scanner: first.call,
    ).scanSource(sourceId: 1, rootPath: '/m');

    final _ScriptedScanner second = _ScriptedScanner(<List<MusicScanRecord>>[
      <MusicScanRecord>[
        MusicScanUnchanged(canonA),
        // b 变了（mtime），Rust 按新拼法算出新 uid；音频指纹没变。
        _track('freshB', path: canonB),
      ],
    ]);
    final MusicScanSummary s = await MusicLibraryScanner(
      db,
      scanner: second.call,
    ).scanSource(sourceId: 1, rootPath: '/m');
    expect(s.removedTrackCount, 0);
    expect(s.trackCount, 2);
    final List<MusicTrackRow> rows = await db.listMusicTracks();
    expect(rows.map((MusicTrackRow t) => t.trackUid).toSet(), <String>{
      'legacyA',
      'legacyB',
    });
    expect(
      rows.firstWhere((MusicTrackRow t) => t.trackUid == 'legacyB').path,
      canonB,
    );
  });

  test('真原生库扫样本库入库：CUE 拆轨 + 专辑聚合（硬依赖，缺库判红）', () async {
    final MusicScanSummary s = await MusicLibraryScanner(
      db,
    ).scanSource(sourceId: 7, rootPath: _fixtureRoot());
    expect(s.errors, isEmpty);
    expect(s.trackCount, 18);
    final MusicLibrarySnapshot snap = await MusicLibrarySnapshot.load(db);
    final MusicAlbumRow cueAlbum = snap.albums.firstWhere(
      (MusicAlbumRow a) => a.title == 'キュー盤',
    );
    final List<MusicTrackRow> cue = snap.tracksOfAlbum(cueAlbum.albumUid);
    expect(cue.map((MusicTrackRow t) => t.title), <String>[
      '夜に駆ける',
      '二曲目',
      '三曲目',
    ]);
    expect(cue.map((MusicTrackRow t) => t.cueStartMs), <int?>[0, 1000, 2000]);
    final MusicAlbumRow albumA = snap.albums.firstWhere(
      (MusicAlbumRow a) => a.title == 'Album A',
    );
    expect(albumA.coverPath, endsWith('cover.png'));
    expect(snap.tracksOfAlbum(albumA.albumUid), hasLength(2));

    // 第二遍：文件都没动 → 全部走 unchanged，一首都不重解析，也不软删。
    final MusicScanSummary again = await MusicLibraryScanner(
      db,
    ).scanSource(sourceId: 7, rootPath: _fixtureRoot());
    expect(again.parsedTrackCount, 0);
    expect(again.removedTrackCount, 0);
    expect(again.trackCount, 18);
  });

  test('格式徽章', () {
    expect(
      musicFormatBadge(
        codec: 'flac',
        isLossless: true,
        sampleRate: 96000,
        bitDepth: 24,
      ),
      'FLAC 24/96',
    );
    expect(
      musicFormatBadge(
        codec: 'flac',
        isLossless: true,
        sampleRate: 44100,
        bitDepth: 16,
      ),
      'FLAC 16/44.1',
    );
    expect(
      musicFormatBadge(codec: 'dsd', isLossless: true, sampleRate: 2822400),
      'DSD64',
    );
    expect(
      musicFormatBadge(codec: 'mp3', isLossless: false, bitrateKbps: 320),
      'MP3 320k',
    );
    expect(
      musicIsHiRes(
        codec: 'flac',
        isLossless: true,
        sampleRate: 48000,
        bitDepth: 24,
      ),
      isTrue,
    );
    expect(
      musicIsHiRes(
        codec: 'flac',
        isLossless: true,
        sampleRate: 44100,
        bitDepth: 16,
      ),
      isFalse,
    );
    expect(
      musicIsHiRes(codec: 'aac', isLossless: false, sampleRate: 96000),
      isFalse,
    );
  });
}

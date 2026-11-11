import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_library_scanner.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';

/// 扫描收尾的专辑对齐（native/fushi_music/src/album_merge.rs）经真原生库跑通落库：
/// 同一目录里标签不一致的曲目归回同一张专辑，增量扫描只有一首变化时结论不变。
/// 原生库是硬依赖：缺库判红，不 skip。
MusicScannedTrack _track(
  String uid, {
  required String path,
  required String album,
  required String albumUid,
  String? albumArtist,
  String? catalogNo,
  int mtime = 10,
}) => MusicScannedTrack(
  path: path,
  trackUid: uid,
  cueStartMs: null,
  cueEndMs: null,
  durationMs: 1000,
  codec: 'flac',
  sampleRate: 44100,
  bitDepth: 16,
  channels: 2,
  bitrateKbps: 900,
  isLossless: true,
  title: 'title-$uid',
  titleSort: null,
  artistCredit: 'Singer',
  albumTitle: album,
  albumTitleSort: null,
  albumArtist: albumArtist,
  albumUid: albumUid,
  discNo: 1,
  discTotal: 1,
  trackNo: 1,
  year: 2025,
  releaseDate: '2025',
  genre: null,
  catalogNo: catalogNo,
  rgTrackGain: null,
  rgTrackPeak: null,
  rgAlbumGain: null,
  rgAlbumPeak: null,
  mbRecordingId: null,
  mbWorkId: null,
  mbReleaseId: null,
  mbReleaseGroupId: null,
  fileMtimeMs: mtime,
  fileSize: 20,
  hasEmbeddedCover: false,
  folderCoverPath: null,
  cueSheetPath: null,
  credits: <MusicScanCredit>[
    const MusicScanCredit(role: 'artist', name: 'Singer', artistUid: 'as'),
    if (albumArtist != null)
      MusicScanCredit(
        role: 'album_artist',
        name: albumArtist,
        artistUid: 'aa-$albumArtist',
      ),
  ],
);

Stream<MusicScanBatch> Function(
  String root, {
  bool recursive,
  Map<String, ({int mtimeMs, int size})> known,
})
_scripted(List<MusicScanRecord> records) =>
    (
      String root, {
      bool recursive = true,
      Map<String, ({int mtimeMs, int size})> known =
          const <String, ({int mtimeMs, int size})>{},
    }) => Stream<MusicScanBatch>.value(
      MusicScanBatch(done: true, records: records),
    );

/// 逐首派生（Rust 扫描器的行为）：有专辑艺人的那首一个 uid，没写的另一个 uid。
const String _dot = 'TVアニメ「X」オリジナル.サウンドトラック 上';
const String _mid = 'TVアニメ「X」オリジナル・サウンドトラック 上';

void main() {
  late FushiDatabase db;
  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> scan(List<MusicScanRecord> records) => MusicLibraryScanner(
    db,
    scanner: _scripted(records),
    discRegistrar: (String root, {bool recursive = true}) async =>
        const <String, String>{},
  ).scanSource(sourceId: 1, rootPath: '/m');

  Future<Map<String, String?>> albumOfTracks() async => <String, String?>{
    for (final MusicTrackRow t in await db.listMusicTracks())
      t.trackUid: t.albumUid,
  };

  MusicScannedTrack first(String uid, {int mtime = 10}) => _track(
    uid,
    path: '/m/CDs/01/$uid.flac',
    album: _dot,
    albumUid: 'raw-artist',
    albumArtist: 'Composer',
    catalogNo: 'LACA-1',
    mtime: mtime,
  );
  MusicScannedTrack rest(String uid, {int mtime = 10}) => _track(
    uid,
    path: '/m/CDs/01/$uid.flac',
    album: _mid,
    albumUid: 'raw-dir',
    mtime: mtime,
  );

  test('缺省专辑艺人 + 标点差异：首扫并成一张，名取多数写法，目录号从带艺人的行补', () async {
    await scan(<MusicScanRecord>[first('t1'), rest('t2'), rest('t3')]);
    final List<MusicAlbumRow> albums = await db.listMusicAlbums();
    expect(albums, hasLength(1));
    final MusicAlbumRow a = albums.single;
    expect(a.title, _mid);
    expect(a.albumArtistCredit, 'Composer');
    expect(a.catalogNo, 'LACA-1');
    expect((await albumOfTracks()).values.toSet(), <String?>{a.albumUid});
    // 被并掉的专辑行没有曲目引用了：删掉，不留孤儿行。
    expect(await db.getMusicAlbum('raw-artist'), isNull);
    expect(await db.getMusicAlbum('raw-dir'), isNull);
  });

  test('增量扫描只有一首变了（它重新拿到逐首 uid，其余只报没变）：仍是同一张、同一个 uid', () async {
    await scan(<MusicScanRecord>[first('t1'), rest('t2'), rest('t3')]);
    final String canonical = (await db.listMusicAlbums()).single.albumUid;
    for (final List<MusicScanRecord> second in <List<MusicScanRecord>>[
      <MusicScanRecord>[
        rest('t2', mtime: 11),
        const MusicScanUnchanged('/m/CDs/01/t1.flac'),
        const MusicScanUnchanged('/m/CDs/01/t3.flac'),
      ],
      <MusicScanRecord>[
        first('t1', mtime: 12),
        const MusicScanUnchanged('/m/CDs/01/t2.flac'),
        const MusicScanUnchanged('/m/CDs/01/t3.flac'),
      ],
      // 什么都没变（存量库）：方案为空，不动任何行。
      <MusicScanRecord>[
        const MusicScanUnchanged('/m/CDs/01/t1.flac'),
        const MusicScanUnchanged('/m/CDs/01/t2.flac'),
        const MusicScanUnchanged('/m/CDs/01/t3.flac'),
      ],
    ]) {
      await scan(second);
      final List<MusicAlbumRow> albums = await db.listMusicAlbums();
      expect(albums.map((MusicAlbumRow a) => a.albumUid), <String>[canonical]);
      expect(albums.single.title, _mid);
      expect(albums.single.albumArtistCredit, 'Composer');
      expect((await albumOfTracks()).values.toSet(), <String?>{canonical});
    }
  });

  test('存量库（旧版本扫出的两张）：下次扫描哪怕全部没变也自动合并', () async {
    // 旧行为：直接按逐首 uid 落库、不对齐。
    await db.writeMusicScanBatch(
      musicScanBatchWriteOf(
        <MusicScannedTrack>[first('t1'), rest('t2')],
        sourceId: 1,
        now: 1,
      ),
    );
    expect(await db.listMusicAlbums(), hasLength(2));
    await scan(<MusicScanRecord>[
      const MusicScanUnchanged('/m/CDs/01/t1.flac'),
      const MusicScanUnchanged('/m/CDs/01/t2.flac'),
    ]);
    expect(await db.listMusicAlbums(), hasLength(1));
  });

  test('两个不同的专辑艺人不合并；不同目录的同名专辑不合并', () async {
    await scan(<MusicScanRecord>[
      _track(
        'a',
        path: '/m/Best/a.flac',
        album: 'Best',
        albumUid: 'ua',
        albumArtist: 'Artist A',
      ),
      _track(
        'b',
        path: '/m/Best/b.flac',
        album: 'Best!',
        albumUid: 'ub',
        albumArtist: 'Artist B',
      ),
      _track('c', path: '/m/One/c.flac', album: 'Hits', albumUid: 'h1'),
      _track('d', path: '/m/Two/d.flac', album: 'Hits', albumUid: 'h2'),
    ]);
    expect(
      (await db.listMusicAlbums()).map((MusicAlbumRow a) => a.albumUid).toSet(),
      <String>{'ua', 'ub', 'h1', 'h2'},
    );
  });
}

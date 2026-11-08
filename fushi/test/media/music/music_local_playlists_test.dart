import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_library_scanner.dart';
import 'package:fushi/src/media/music/music_local_playlists.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:path/path.dart' as p;

final p.Context _posix = p.Context(style: p.Style.posix);

MusicTrackRow _row(String uid, String path, {int? cueStartMs}) => MusicTrackRow(
  trackUid: uid,
  path: path,
  title: uid,
  cueStartMs: cueStartMs,
  isLossless: false,
  fileMtimeAt: 1,
  fileSize: 1,
  hasEmbeddedCover: false,
  addedAt: 1,
);

MusicTracksCompanion _insert(String uid, String path) =>
    MusicTracksCompanion.insert(
      trackUid: uid,
      path: path,
      title: 'title-$uid',
      durationMs: const Value<int?>(1000),
      fileMtimeAt: 1,
      fileSize: 1,
      addedAt: 1,
    );

/// 只回预设批次的扫描替身（播放列表记录由它直接给出，不经原生库）。
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

void main() {
  group('matchMusicPlaylistEntries', () {
    final List<MusicTrackRow> library = <MusicTrackRow>[
      _row('a', '/music/Artist/Album/01 A.flac'),
      _row('b', '/music/Artist/Album/02 B.mp3'),
      _row('cue2', '/music/Live/live.flac', cueStartMs: 60000),
      _row('cue1', '/music/Live/live.flac', cueStartMs: 0),
      _row('x1', '/music/One/intro.mp3'),
      _row('x2', '/music/Two/intro.mp3'),
    ];

    test('精确路径按列表顺序对上，可重复；网络地址与对不上的条目丢掉', () {
      expect(
        matchMusicPlaylistEntries(
          <String>[
            '/music/Artist/Album/02 B.mp3',
            'https://example.com/s.mp3',
            '/music/Artist/Album/01 A.flac',
            '/nowhere/z.mp3',
            '/music/Artist/Album/02 B.mp3',
          ],
          library,
          context: _posix,
        ),
        <String>['b', 'a', 'b'],
      );
    });

    test('CUE 整轨文件展开成全部虚拟曲目（按起点排）', () {
      expect(
        matchMusicPlaylistEntries(
          <String>['/music/Live/live.flac'],
          library,
          context: _posix,
        ),
        <String>['cue1', 'cue2'],
      );
    });

    test('别的机器写的绝对路径按尾段对上；尾段有歧义的不猜', () {
      expect(
        matchMusicPlaylistEntries(
          <String>[
            r'C:\Users\someone\Music\Artist\Album\01 A.flac',
            '/old/disk/intro.mp3',
            '/old/disk/Two/intro.mp3',
          ],
          library,
          context: _posix,
        ),
        <String>['a', 'x2'],
      );
    });
  });

  test('导入歌单 uid 由文件路径派生，同一文件同一 uid', () {
    final String a = importedMusicPlaylistUid('/m/l.m3u8', context: _posix);
    expect(a, startsWith('pl-file-'));
    expect(importedMusicPlaylistUid('/m/./l.m3u8', context: _posix), a);
    expect(
      importedMusicPlaylistUid('/m/other.m3u8', context: _posix),
      isNot(a),
    );
    expect(newMusicPlaylistUid(), isNot(newMusicPlaylistUid()));
  });

  test('列表显示名：#PLAYLIST 优先，否则文件名', () {
    expect(
      musicPlaylistFileTitle(
        '/m/Road Trip.m3u8',
        const MusicPlaylistFile(name: null, entries: <String>[]),
        context: _posix,
      ),
      'Road Trip',
    );
    expect(
      musicPlaylistFileTitle(
        '/m/x.m3u',
        const MusicPlaylistFile(name: ' Mix ', entries: <String>[]),
        context: _posix,
      ),
      'Mix',
    );
  });

  test('远程列表：相对条目按 / 拼到列表目录，.. 不越过主机', () {
    final MusicPlaylistFile r = resolveRemoteMusicPlaylistEntries(
      'sftp://nas/music/Lists/a.m3u8',
      const MusicPlaylistFile(
        name: 'A',
        entries: <String>[
          '../Album/01.flac',
          r'sub\02.flac',
          '../../../../x.flac',
          'https://e.com/s.mp3',
        ],
      ),
    );
    expect(r.name, 'A');
    expect(r.entries, <String>[
      'sftp://nas/music/Album/01.flac',
      'sftp://nas/music/Lists/sub/02.flac',
      'sftp://nas/x.flac',
      'https://e.com/s.mp3',
    ]);
  });

  test('导出 .m3u8：同根本地路径写相对，扩展信息写进 EXTINF', () {
    final String text = encodeMusicPlaylistM3u8(
      name: 'Mix\nTwo',
      items: const <MusicPlaylistExportItem>[
        MusicPlaylistExportItem(
          location: '/music/Album/01 A.flac',
          title: 'A',
          artist: 'Singer',
          durationMs: 61500,
        ),
        MusicPlaylistExportItem(location: '/srv/b.mp3'),
      ],
      relativeTo: '/music/Lists',
      context: _posix,
    );
    expect(
      text,
      '#EXTM3U\n#PLAYLIST:Mix Two\n'
      '#EXTINF:62,Singer - A\n../Album/01 A.flac\n'
      '#EXTINF:-1,\n../../srv/b.mp3\n',
    );
  });

  group('数据库', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<List<String>> trackUidsOf(String uid) async => <String>[
      for (final MusicPlaylistEntryRow e in await db.listMusicPlaylistEntries(
        uid,
      ))
        e.trackUid,
    ];

    Future<int> updatedAtOf(String uid) async =>
        (await db.getMusicPlaylist(uid))!.updatedAt;

    test('新建 / 追加 / 删条目 / 重排 / 改名 / 软删，每步推进 updatedAt', () async {
      expect(
        await db.createMusicPlaylist(
          playlistUid: 'p',
          name: 'P',
          trackUids: <String>['a', 'b'],
          now: 1,
        ),
        isTrue,
      );
      expect(
        await db.createMusicPlaylist(playlistUid: 'p', name: 'again', now: 2),
        isFalse,
      );
      await db.appendMusicPlaylistTracks('p', <String>['c', 'a'], now: 3);
      expect(await trackUidsOf('p'), <String>['a', 'b', 'c', 'a']);
      expect(await updatedAtOf('p'), 3);
      expect((await db.musicPlaylistEntryCounts())['p'], 4);

      final List<MusicPlaylistEntryRow> entries = await db
          .listMusicPlaylistEntries('p');
      // 删第二个 'a'（同一首放两次只删指定那条）。
      await db.removeMusicPlaylistEntries('p', <int>{entries[3].id}, now: 4);
      expect(await trackUidsOf('p'), <String>['a', 'b', 'c']);
      expect(
        (await db.listMusicPlaylistEntries(
          'p',
        )).map((MusicPlaylistEntryRow e) => e.position),
        <int>[0, 1, 2],
      );

      // 只列出部分条目：没列出的按原顺序排在后面；外来 id 忽略。
      await db.reorderMusicPlaylist('p', <int>[
        entries[2].id,
        999,
        entries[0].id,
      ], now: 5);
      expect(await trackUidsOf('p'), <String>['c', 'a', 'b']);
      expect(await updatedAtOf('p'), 5);

      await db.renameMusicPlaylist('p', 'Renamed', now: 6);
      expect((await db.getMusicPlaylist('p'))!.name, 'Renamed');

      await db.softDeleteMusicPlaylist('p', now: 7);
      expect(await db.listMusicPlaylists(), isEmpty);
      expect((await db.getMusicPlaylist('p'))!.deletedAt, 7);
    });

    test('导入：对上的曲目建歌单；同一文件不再导入（删掉之后也不）；手动导入可再建一份', () async {
      await db.batch((b) {
        b.insertAll(db.musicTracks, <MusicTracksCompanion>[
          _insert('a', '/music/a.flac'),
          _insert('b', '/music/b.flac'),
        ]);
      });
      const MusicPlaylistFile file = MusicPlaylistFile(
        name: 'List',
        entries: <String>['/music/b.flac', '/missing.flac', '/music/a.flac'],
      );
      final r1 = await importMusicPlaylistFile(
        db,
        path: '/music/list.m3u8',
        file: file,
        now: 1,
        context: _posix,
      );
      expect(r1.outcome, MusicPlaylistImportOutcome.imported);
      expect(r1.matched, 2);
      expect(await trackUidsOf(r1.playlistUid), <String>['b', 'a']);
      expect((await db.getMusicPlaylist(r1.playlistUid))!.name, 'List');

      await db.softDeleteMusicPlaylist(r1.playlistUid, now: 2);
      final r2 = await importMusicPlaylistFile(
        db,
        path: '/music/list.m3u8',
        file: file,
        now: 3,
        context: _posix,
      );
      expect(r2.outcome, MusicPlaylistImportOutcome.alreadyImported);
      expect(await db.listMusicPlaylists(), isEmpty);

      final r3 = await importMusicPlaylistFile(
        db,
        path: '/music/list.m3u8',
        file: file,
        now: 4,
        forceNewCopy: true,
        context: _posix,
      );
      expect(r3.outcome, MusicPlaylistImportOutcome.imported);
      expect(r3.playlistUid, isNot(r1.playlistUid));
      expect(await db.listMusicPlaylists(), hasLength(1));
    });

    test('导入：一条都没对上不建歌单，之后对得上时还能导入', () async {
      const MusicPlaylistFile file = MusicPlaylistFile(
        name: null,
        entries: <String>['/music/a.flac'],
      );
      final r1 = await importMusicPlaylistFile(
        db,
        path: '/music/l.m3u',
        file: file,
        now: 1,
        context: _posix,
      );
      expect(r1.outcome, MusicPlaylistImportOutcome.noMatches);
      expect(await db.getMusicPlaylist(r1.playlistUid), isNull);

      await db.into(db.musicTracks).insert(_insert('a', '/music/a.flac'));
      final r2 = await importMusicPlaylistFile(
        db,
        path: '/music/l.m3u',
        file: file,
        now: 2,
        context: _posix,
      );
      expect(r2.outcome, MusicPlaylistImportOutcome.imported);
      expect((await db.getMusicPlaylist(r2.playlistUid))!.name, 'l');
    });

    test('扫描：本次见到的播放列表文件在曲目落库后导入，重扫不重复', () async {
      final List<MusicScanRecord> records = <MusicScanRecord>[
        MusicScannedTrack(
          path: '/m/a.flac',
          trackUid: 'ta',
          cueStartMs: null,
          cueEndMs: null,
          durationMs: 1000,
          codec: 'flac',
          sampleRate: 44100,
          bitDepth: 16,
          channels: 2,
          bitrateKbps: 900,
          isLossless: true,
          title: 'A',
          titleSort: null,
          artistCredit: 'X',
          albumTitle: null,
          albumTitleSort: null,
          albumArtist: null,
          albumUid: null,
          discNo: null,
          discTotal: null,
          trackNo: null,
          year: null,
          releaseDate: null,
          genre: null,
          catalogNo: null,
          rgTrackGain: null,
          rgTrackPeak: null,
          rgAlbumGain: null,
          rgAlbumPeak: null,
          mbRecordingId: null,
          mbWorkId: null,
          mbReleaseId: null,
          mbReleaseGroupId: null,
          fileMtimeMs: 1,
          fileSize: 1,
          hasEmbeddedCover: false,
          folderCoverPath: null,
          cueSheetPath: null,
          credits: const <MusicScanCredit>[],
        ),
        const MusicScanPlaylist(
          '/m/mix.m3u8',
          mtimeMs: 1,
          playlist: MusicPlaylistFile(
            name: 'Mix',
            entries: <String>['/m/a.flac', '/m/a.flac'],
          ),
        ),
      ];
      final MusicScanSummary s1 = await MusicLibraryScanner(
        db,
        scanner: _scripted(records),
        discRegistrar: (String root, {bool recursive = true}) async =>
            <String, String>{},
      ).scanSource(sourceId: 1, rootPath: '/m');
      expect(s1.importedPlaylistCount, 1);
      final List<MusicPlaylistRow> lists = await db.listMusicPlaylists();
      expect(lists.single.name, 'Mix');
      expect(await trackUidsOf(lists.single.playlistUid), <String>['ta', 'ta']);

      final MusicScanSummary s2 = await MusicLibraryScanner(
        db,
        scanner: _scripted(records),
        discRegistrar: (String root, {bool recursive = true}) async =>
            <String, String>{},
      ).scanSource(sourceId: 1, rootPath: '/m');
      expect(s2.importedPlaylistCount, 0);
      expect(await db.listMusicPlaylists(), hasLength(1));
    });
  });
}

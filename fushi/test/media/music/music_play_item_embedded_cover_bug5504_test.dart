import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/ops/ctl_music_routes.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_backdrop.dart';
import 'package:fushi/src/pages/implementations/music/music_track_list.dart'
    show musicLocalTrackCoverOf;
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/music_ctl_fakes.dart';

/// BUG-5504（反馈 qGNRXaXNEv / EMjx7gJftH）：只有内嵌封面、没有目录封面的本地曲目，
/// 曲目行有图，播放页 / 迷你播放条 / 队列却是占位音符——播放项只带目录封面。

MusicTrackRow _track(
  String uid, {
  String? albumUid,
  bool hasEmbeddedCover = false,
}) => MusicTrackRow(
  trackUid: uid,
  path: '/music/$uid.flac',
  title: 'Title $uid',
  albumUid: albumUid,
  isLossless: true,
  fileMtimeAt: 1,
  fileSize: 1,
  hasEmbeddedCover: hasEmbeddedCover,
  addedAt: 1,
);

MusicAlbumRow _album(String uid, {String? coverPath, String? coverTrackUid}) =>
    MusicAlbumRow(
      albumUid: uid,
      title: 'Album $uid',
      coverPath: coverPath,
      coverTrackUid: coverTrackUid,
      addedAt: 1,
      updatedAt: 1,
    );

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('musicPlayItemOf 封面来源（与曲目行同一规则）', () {
    test('没有目录封面、曲目带内嵌封面 → 播放项带内嵌封面来源', () {
      final MusicPlayItem item = musicPlayItemOf(
        _track('a', albumUid: 'al', hasEmbeddedCover: true),
        album: _album('al'),
      );
      expect(item.coverPath, isNull);
      expect(item.embeddedCoverPath, '/music/a.flac');
    });

    test('没有专辑的单曲同样带上自己的内嵌封面', () {
      final MusicPlayItem item = musicPlayItemOf(
        _track('a', hasEmbeddedCover: true),
      );
      expect(item.embeddedCoverPath, '/music/a.flac');
    });

    test('目录封面优先：有目录封面时不带内嵌来源', () {
      final MusicPlayItem item = musicPlayItemOf(
        _track('a', albumUid: 'al', hasEmbeddedCover: true),
        album: _album('al', coverPath: '/music/cover.jpg'),
      );
      expect(item.coverPath, '/music/cover.jpg');
      expect(item.embeddedCoverPath, isNull);
    });

    test('显式 coverPath 覆盖专辑封面且不带内嵌来源', () {
      final MusicPlayItem item = musicPlayItemOf(
        _track('a', hasEmbeddedCover: true),
        coverPath: '/cache/x.jpg',
      );
      expect(item.coverPath, '/cache/x.jpg');
      expect(item.embeddedCoverPath, isNull);
    });

    test('专辑选定的封面曲目（经 trackPathOf 查路径）优先于这首自己的', () {
      final MusicPlayItem item = musicPlayItemOf(
        _track('b', albumUid: 'al', hasEmbeddedCover: true),
        album: _album('al', coverTrackUid: 'a'),
        trackPathOf: musicTrackPathsOf(<MusicTrackRow>[
          _track('a', albumUid: 'al', hasEmbeddedCover: true),
        ]),
      );
      expect(item.embeddedCoverPath, '/music/a.flac');
    });

    test('只有第一首带内嵌图：第二首的播放项与曲目行同一张封面', () {
      final MusicAlbumRow album = _album('al', coverTrackUid: 'a');
      final List<MusicTrackRow> tracks = <MusicTrackRow>[
        _track('a', albumUid: 'al', hasEmbeddedCover: true),
        _track('b', albumUid: 'al'),
      ];
      final MusicLocalEntry second = MusicLocalEntry(tracks[1]);
      final MusicPlayItem item = second.playItem(<String, MusicAlbumRow>{
        'al': album,
      }, trackPathOf: musicTrackPathsOf(tracks));
      expect(item.embeddedCoverPath, '/music/a.flac');
      // 曲目行（BUG-4494）走同一条规则。
      expect(
        musicLocalTrackCoverOf(
          tracks[1],
          album: album,
          pathByUid: <String, String>{
            for (final MusicTrackRow t in tracks) t.trackUid: t.path,
          },
        ).embeddedFromPath,
        item.embeddedCoverPath,
      );
      // 快照查表（曲库页 / 互联 / 控制通道用的那份）。
      final MusicLibrarySnapshot snap = MusicLibrarySnapshot(
        albums: <MusicAlbumRow>[album],
        tracks: tracks,
        artists: const <MusicArtistRow>[],
        playlists: const <MusicPlaylistRow>[],
      );
      expect(
        musicPlayItemOf(
          tracks[1],
          album: album,
          trackPathOf: snap.trackPathOf,
        ).embeddedCoverPath,
        '/music/a.flac',
      );
    });

    test('都没有 → 两个都为 null（占位）', () {
      final MusicPlayItem item = musicPlayItemOf(
        _track('a', albumUid: 'al'),
        album: _album('al'),
      );
      expect(item.coverPath, isNull);
      expect(item.embeddedCoverPath, isNull);
    });
  });

  group('真实调用方：控制通道放专辑 / 按曲目放', () {
    late FushiDatabase db;
    late FakeMusicPlayer player;
    late List<CtlRoute> routes;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      player = FakeMusicPlayer();
      routes = buildMusicCtlRoutesFor(
        database: () => db,
        musicEnabled: () => true,
        isReadonly: () => false,
        player: () => player,
        scraper: () => FakeMusicScraper(db).port,
        removeSource: (FushiDatabase d, int id) async {},
        jobs: MusicScrapeJobs(),
        clock: () => 1,
      );
      await seedMusicLibrary(db);
      // 专辑 al-1 没有目录封面，只有第一首 t-1 带内嵌图（扫描时选它当封面曲目）。
      await (db.update(
        db.musicTracks,
      )..where(($MusicTracksTable t) => t.trackUid.equals('t-1'))).write(
        const MusicTracksCompanion(hasEmbeddedCover: Value<bool>(true)),
      );
      await (db.update(
        db.musicAlbums,
      )..where(($MusicAlbumsTable a) => a.albumUid.equals('al-1'))).write(
        const MusicAlbumsCompanion(coverTrackUid: Value<String?>('t-1')),
      );
    });

    tearDown(() => db.close());

    Future<Object?> play(Map<String, Object?> body) => routes
        .singleWhere(
          (CtlRoute r) =>
              r.method == 'POST' && r.pattern == '$kMusicCtlRoot/player/play',
        )
        .handler(
          CtlCall(
            method: 'POST',
            path: '$kMusicCtlRoot/player/play',
            params: const <String, String>{},
            body: body,
          ),
        );

    test('放专辑：第二首的播放项带第一首的内嵌封面', () async {
      await play(<String, Object?>{'album': 'al-1'});
      expect(
        <String?>[for (final MusicPlayItem i in player.queue) i.trackUid],
        <String>['t-1', 't-2'],
      );
      expect(player.queue[1].coverPath, isNull);
      expect(player.queue[1].embeddedCoverPath, '/music/t-1.flac');
    });

    test('只点第二首：播放项照样带专辑封面曲目的内嵌封面', () async {
      await play(<String, Object?>{
        'tracks': <String>['t-2'],
      });
      expect(player.queue.single.embeddedCoverPath, '/music/t-1.flac');
    });
  });

  group('只认 ImageProvider 的消费方接上内嵌封面', () {
    test('MusicEmbeddedCoverImage 按音频路径判等', () {
      expect(
        const MusicEmbeddedCoverImage('/m/a.flac'),
        const MusicEmbeddedCoverImage('/m/a.flac'),
      );
      expect(
        const MusicEmbeddedCoverImage('/m/a.flac') ==
            const MusicEmbeddedCoverImage('/m/b.flac'),
        isFalse,
      );
    });

    test('取色 provider：无封面文件时退到内嵌封面', () {
      final ImageProvider? p = musicCoverImageProvider(
        null,
        size: 128,
        embeddedFromPath: '/m/a.flac',
      );
      expect(p, isA<ResizeImage>());
      expect(
        (p! as ResizeImage).imageProvider,
        const MusicEmbeddedCoverImage('/m/a.flac'),
      );
      expect(musicCoverImageProvider(null), isNull);
    });

    test('歌词页背景 / 取色 provider：无封面文件时退到内嵌封面', () {
      expect(
        musicLyricsBackdropCoverProvider(null, embeddedFromPath: '/m/a.flac'),
        const MusicEmbeddedCoverImage('/m/a.flac'),
      );
      expect(musicLyricsBackdropCoverProvider(null), isNull);
    });
  });

  test('带专辑的 musicPlayItemOf 调用都给了 trackPathOf（封面曲目查得到）', () {
    // 最近播放从事件快照还原播放项，手里没有专辑其余曲目，只能退回这首自己的内嵌封面。
    const Set<String> exempt = <String>{
      'lib/src/media/music/music_history.dart',
    };
    final List<String> missing = <String>[];
    for (final FileSystemEntity f in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final String path = f.path.replaceAll(r'\', '/');
      if (exempt.contains(path)) continue;
      final String src = f.readAsStringSync();
      int from = 0;
      while (true) {
        final int at = src.indexOf('musicPlayItemOf(', from);
        if (at < 0) break;
        int depth = 0;
        int end = at + 'musicPlayItemOf'.length;
        for (; end < src.length; end++) {
          final String ch = src[end];
          if (ch == '(') depth++;
          if (ch == ')' && --depth == 0) break;
        }
        final String call = src.substring(at, end + 1);
        from = end;
        if (call.contains('album:') && !call.contains('trackPathOf:')) {
          missing.add('$path: $call');
        }
      }
    }
    expect(missing, isEmpty);
  });

  test('播放页 / Apple 播放页 / 播放条 / 队列的封面都传了内嵌来源', () {
    const String dir = 'lib/src/pages/implementations/music';
    final Map<String, int> minUses = <String, int>{
      '$dir/music_lyrics_page.dart': 5,
      '$dir/music_lyrics_page_apple.part.dart': 1,
      '$dir/music_now_playing_bar.dart': 2,
      '$dir/music_queue_panel.dart': 2,
    };
    for (final MapEntry<String, int> e in minUses.entries) {
      final int uses = RegExp(
        r'embeddedCoverPath',
      ).allMatches(_read(e.key)).length;
      expect(uses, greaterThanOrEqualTo(e.value), reason: e.key);
    }
  });
}

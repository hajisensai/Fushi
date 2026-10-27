import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/ops/ctl_music_routes.dart';

import '../helpers/music_ctl_fakes.dart';

Matcher _status(int status) => throwsA(
  isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', status),
);

void main() {
  late FushiDatabase db;
  late FakeMusicPlayer player;
  late FakeMusicScraper scraper;
  late MusicScrapeJobs jobs;
  late List<CtlRoute> routes;
  late List<int> removedSources;
  bool enabled = true;
  bool readonly = false;

  setUp(() async {
    enabled = true;
    readonly = false;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    player = FakeMusicPlayer();
    scraper = FakeMusicScraper(db);
    jobs = MusicScrapeJobs();
    removedSources = <int>[];
    routes = buildMusicCtlRoutesFor(
      database: () => db,
      musicEnabled: () => enabled,
      isReadonly: () => readonly,
      player: () => player,
      scraper: () => scraper.port,
      removeSource: (FushiDatabase d, int id) async {
        removedSources.add(id);
        await d.deleteMediaSource(id);
      },
      jobs: jobs,
      clock: () => 4242,
    );
    await seedMusicLibrary(db);
  });

  tearDown(() => db.close());

  Future<Object?> call(
    String method,
    String pattern, {
    Map<String, String> params = const <String, String>{},
    Map<String, Object?> body = const <String, Object?>{},
  }) {
    final CtlRoute route = routes.singleWhere(
      (CtlRoute r) => r.method == method && r.pattern == pattern,
    );
    String path = pattern;
    params.forEach((String k, String v) => path = path.replaceAll(':$k', v));
    return route.handler(
      CtlCall(method: method, path: path, params: params, body: body),
    );
  }

  Map<String, Object?> asMap(Object? v) => (v! as Map).cast<String, Object?>();
  List<Object?> listOf(Object? v, String key) =>
      asMap(v)[key]! as List<Object?>;

  test('路由都在 /api/admin/music 下、method + pattern 唯一', () {
    final Set<String> keys = <String>{};
    for (final CtlRoute r in routes) {
      expect(r.pattern, startsWith('$kMusicCtlRoot/'));
      expect(keys.add('${r.method} ${r.pattern}'), isTrue);
    }
  });

  group('曲库列表 / 搜索', () {
    test('专辑：搜索走统一归一化（大小写不敏感），带曲目数', () async {
      final Object? all = await call('GET', '$kMusicCtlRoot/albums');
      expect(asMap(all)['total'], 2);
      final Object? hit = await call(
        'GET',
        '$kMusicCtlRoot/albums',
        body: <String, Object?>{'search': 'the book'},
      );
      final List<Object?> albums = listOf(hit, 'albums');
      expect(albums, hasLength(1));
      expect(asMap(albums.single)['uid'], 'al-1');
      expect(asMap(albums.single)['tracks'], 2);
      final Object? limited = await call(
        'GET',
        '$kMusicCtlRoot/albums',
        body: <String, Object?>{'limit': 1},
      );
      expect(listOf(limited, 'albums'), hasLength(1));
      expect(asMap(limited)['total'], 2);
    });

    test('专辑详情按轨号排；不存在 404', () async {
      final Object? album = await call(
        'GET',
        '$kMusicCtlRoot/albums/:uid',
        params: <String, String>{'uid': 'al-1'},
      );
      expect(
        <Object?>[
          for (final Object? t in listOf(album, 'tracks')) asMap(t)['uid'],
        ],
        <String>['t-1', 't-2'],
      );
      expect(
        () => call(
          'GET',
          '$kMusicCtlRoot/albums/:uid',
          params: <String, String>{'uid': 'nope'},
        ),
        _status(404),
      );
    });

    test('艺人与曲目：按艺人过滤、关键词命中专辑名', () async {
      final Object? artists = await call(
        'GET',
        '$kMusicCtlRoot/artists',
        body: <String, Object?>{'search': 'aim'},
      );
      expect(asMap(listOf(artists, 'artists').single)['uid'], 'ar-aimer');
      final Object? byArtist = await call(
        'GET',
        '$kMusicCtlRoot/tracks',
        body: <String, Object?>{'artist': 'ar-aimer'},
      );
      expect(asMap(byArtist)['total'], 2);
      final Object? byAlbumTitle = await call(
        'GET',
        '$kMusicCtlRoot/tracks',
        body: <String, Object?>{'search': 'walpurgis'},
      );
      // 「Walpurgis」既是专辑名也是曲名：专辑 al-2 的两首都命中。
      expect(asMap(byAlbumTitle)['total'], 2);
      final Object? kana = await call(
        'GET',
        '$kMusicCtlRoot/tracks',
        body: <String, Object?>{'search': 'カケル'},
      );
      // 片假名 → 平假名不等于汉字：只是不报错、按统一口径算。
      expect(asMap(kana)['total'], 0);
    });

    test('曲目详情带识别结论与候选；歌单只读列出', () async {
      final Object? track = await call(
        'GET',
        '$kMusicCtlRoot/tracks/:uid',
        params: <String, String>{'uid': 't-3'},
      );
      final Map<String, Object?> id = asMap(asMap(track)['identification']);
      expect(id['status'], 'unmatched');
      expect(
        asMap((id['candidates']! as List<Object?>).single)['recordingId'],
        '22222222-2222-2222-2222-222222222222',
      );
      final Object? none = await call(
        'GET',
        '$kMusicCtlRoot/tracks/:uid',
        params: <String, String>{'uid': 't-1'},
      );
      expect(asMap(asMap(none)['identification'])['status'], 'none');
      final Object? playlists = await call('GET', '$kMusicCtlRoot/playlists');
      expect(asMap(listOf(playlists, 'playlists').single)['name'], 'Drive');
    });

    test('音乐模块关闭一律 422', () async {
      enabled = false;
      expect(() => call('GET', '$kMusicCtlRoot/albums'), _status(422));
      expect(() => call('GET', '$kMusicCtlRoot/player'), _status(422));
    });
  });

  group('识别', () {
    test('单曲识别：手动录音 id 透传给 scrapeTrack；坏 id 400、不存在 404', () async {
      final Object? result = await call(
        'POST',
        '$kMusicCtlRoot/tracks/:uid/scrape',
        params: <String, String>{'uid': 't-3'},
        body: <String, Object?>{
          'recordingId': '22222222-2222-2222-2222-222222222222',
        },
      );
      expect(
        scraper.calls.single.manual,
        '22222222-2222-2222-2222-222222222222',
      );
      expect(asMap(result)['status'], 'matched');
      expect(asMap(asMap(result)['identification'])['method'], 'manual');
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/tracks/:uid/scrape',
          params: <String, String>{'uid': 't-3'},
          body: <String, Object?>{'recordingId': 'not-a-mbid'},
        ),
        _status(400),
      );
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/tracks/:uid/scrape',
          params: <String, String>{'uid': 'nope'},
        ),
        _status(404),
      );
      readonly = true;
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/tracks/:uid/scrape',
          params: <String, String>{'uid': 't-1'},
        ),
        _status(422),
      );
    });

    test('整库识别后台跑：重复启动 409、进度可查、取消后停在 cancelled', () async {
      final Object? started = await call('POST', '$kMusicCtlRoot/scrape');
      final String taskId = asMap(started)['taskId']! as String;
      expect(asMap(started)['status'], 'running');
      expect(() => call('POST', '$kMusicCtlRoot/scrape'), _status(409));
      final Object? status = await call('GET', '$kMusicCtlRoot/scrape');
      expect(asMap(status)['id'], taskId);
      expect(asMap(status)['total'], 3);
      await call('POST', '$kMusicCtlRoot/scrape/cancel');
      scraper.gate.complete();
      await pumpEventQueue();
      final Object? done = await call('GET', '$kMusicCtlRoot/scrape');
      expect(asMap(done)['status'], 'cancelled');
      expect(asMap(done)['active'], isFalse);
      expect(asMap(asMap(done)['report'])['matched'], 0);
      expect(() => call('POST', '$kMusicCtlRoot/scrape/cancel'), _status(404));
    });

    test('整库识别跑完 = done，报告带回', () async {
      scraper.gate.complete();
      await call('POST', '$kMusicCtlRoot/scrape');
      await pumpEventQueue();
      final Object? done = await call('GET', '$kMusicCtlRoot/scrape');
      expect(asMap(done)['status'], 'done');
      expect(asMap(asMap(done)['report'])['matched'], 3);
      expect(asMap(done)['finishedAt'], 4242);
    });
  });

  group('扫描根', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('fushi_music_ctl_');
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('添加 → 列出 → 重复添加不新建 → 移除（曲目软删）', () async {
      final Object? added = await call(
        'POST',
        '$kMusicCtlRoot/sources',
        body: <String, Object?>{'path': dir.path},
      );
      expect(asMap(added)['added'], isTrue);
      final int id = asMap(added)['id']! as int;
      final Object? listed = await call('GET', '$kMusicCtlRoot/sources');
      expect(asMap(listOf(listed, 'sources').single)['id'], id);
      final Object? again = await call(
        'POST',
        '$kMusicCtlRoot/sources',
        body: <String, Object?>{'path': dir.path},
      );
      expect(asMap(again)['added'], isFalse);

      // 这个根下有一首曲目：移除时随根软删。
      await db.customStatement(
        "UPDATE music_tracks SET source_id = $id WHERE track_uid = 't-4'",
      );
      expect(
        () => call(
          'DELETE',
          '$kMusicCtlRoot/sources/:id',
          params: <String, String>{'id': '$id'},
        ),
        _status(400),
      );
      final Object? removed = await call(
        'DELETE',
        '$kMusicCtlRoot/sources/:id',
        params: <String, String>{'id': '$id'},
        body: <String, Object?>{'confirm': true},
      );
      expect(asMap(removed)['tracksRemoved'], 1);
      expect(removedSources, <int>[id]);
      expect((await db.getMusicTrack('t-4'))!.deletedAt, 4242);
      expect(
        () => call(
          'DELETE',
          '$kMusicCtlRoot/sources/:id',
          params: <String, String>{'id': '$id'},
          body: <String, Object?>{'confirm': true},
        ),
        _status(404),
      );
    });

    test('非音乐来源不认；相对路径 400、不存在的目录 404', () async {
      final int videoId = await db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'v',
          mediaKind: 'video',
          createdAt: 1,
          rootPath: dir.path,
        ),
      );
      expect(
        () => call(
          'DELETE',
          '$kMusicCtlRoot/sources/:id',
          params: <String, String>{'id': '$videoId'},
          body: <String, Object?>{'confirm': true},
        ),
        _status(404),
      );
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/sources',
          body: <String, Object?>{'path': 'relative/dir'},
        ),
        _status(400),
      );
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/sources',
          body: <String, Object?>{
            'path': '${dir.path}${Platform.pathSeparator}nope',
          },
        ),
        _status(404),
      );
    });

    test('重新扫描：只扫音乐来源，指定不存在的根 404', () async {
      final Object? added = await call(
        'POST',
        '$kMusicCtlRoot/sources',
        body: <String, Object?>{'path': dir.path},
      );
      final Object? scanned = await call('POST', '$kMusicCtlRoot/scan');
      expect(
        asMap(listOf(scanned, 'results').single)['id'],
        asMap(added)['id'],
      );
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/scan',
          body: <String, Object?>{'source': 999},
        ),
        _status(404),
      );
    });
  });

  group('播放遥控', () {
    test('没有队列：status inactive，续播 / 暂停 409', () async {
      final Object? status = await call('GET', '$kMusicCtlRoot/player');
      expect(asMap(status)['active'], isFalse);
      expect(() => call('POST', '$kMusicCtlRoot/player/play'), _status(409));
      expect(() => call('POST', '$kMusicCtlRoot/player/pause'), _status(409));
    });

    test('放专辑 = 专辑语境、按轨号排；暂停 / 续播 / 下一首 / 上一首 / 跳转', () async {
      final Object? playing = await call(
        'POST',
        '$kMusicCtlRoot/player/play',
        body: <String, Object?>{'album': 'al-1'},
      );
      expect(player.lastContext, MusicQueueContext.album);
      expect(asMap(playing)['queue'], <String>['t-1', 't-2']);
      expect(asMap(asMap(playing)['track'])['uid'], 't-1');
      expect(asMap(playing)['playing'], isTrue);

      final Object? paused = await call('POST', '$kMusicCtlRoot/player/pause');
      expect(asMap(paused)['playing'], isFalse);
      await call('POST', '$kMusicCtlRoot/player/play');
      expect(player.playing, isTrue);

      final Object? next = await call('POST', '$kMusicCtlRoot/player/next');
      expect(asMap(next)['index'], 1);
      final Object? prev = await call('POST', '$kMusicCtlRoot/player/previous');
      expect(asMap(prev)['index'], 0);
      final Object? jumped = await call(
        'POST',
        '$kMusicCtlRoot/player/jump',
        body: <String, Object?>{'index': 1},
      );
      expect(asMap(asMap(jumped)['track'])['uid'], 't-2');
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/player/jump',
          body: <String, Object?>{'index': 5},
        ),
        _status(400),
      );
    });

    test('按曲目放：顺序照给出的、index 起播；参数冲突 / 不存在 / 越界', () async {
      final Object? playing = await call(
        'POST',
        '$kMusicCtlRoot/player/play',
        body: <String, Object?>{
          'tracks': <String>['t-3', 't-1'],
          'index': 1,
          'shuffle': true,
        },
      );
      expect(asMap(playing)['queue'], <String>['t-3', 't-1']);
      expect(asMap(playing)['index'], 1);
      expect(player.lastContext, MusicQueueContext.mixed);
      expect(player.lastShuffle, isTrue);
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/player/play',
          body: <String, Object?>{
            'album': 'al-1',
            'tracks': <String>['t-1'],
          },
        ),
        _status(400),
      );
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/player/play',
          body: <String, Object?>{
            'tracks': <String>['nope'],
          },
        ),
        _status(404),
      );
      expect(
        () => call(
          'POST',
          '$kMusicCtlRoot/player/play',
          body: <String, Object?>{'album': 'al-1', 'index': 9},
        ),
        _status(400),
      );
    });
  });
}

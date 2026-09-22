import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/media/manga/mihon/mihon_bridge_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/video/online/anime_source_video_client.dart';
import 'package:fushi/src/sync/remote_cover_fetcher.dart';
import 'package:fushi/src/sync/remote_video_client.dart';

/// 视频源扩展 → 播放页契约：一集一条 `RemoteVideoInfo`、稳定 id、按集取流 +
/// 防盗链头经 [RemoteVideoStreamHeaders] 暴露、字幕同站才带头。
void main() {
  late Directory root;
  late FushiDatabase database;
  late _VideoRuntime runtime;
  late MihonManager manager;
  const MihonAnime anime = MihonAnime(
    url: '/anime/1',
    title: 'Fixture Show',
    coverUrl: 'https://site.example/cover.jpg',
  );
  const List<MihonEpisode> episodes = <MihonEpisode>[
    MihonEpisode(url: '/ep/2', name: 'Episode 2', uploadedAt: 2, number: 2),
    MihonEpisode(url: '/ep/1', name: 'Episode 1', uploadedAt: 1, number: 1),
  ];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hibiki-anime-client-');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    runtime = _VideoRuntime();
    manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: runtime,
      kind: MihonMediaKind.anime,
      ownsRuntime: false,
    );
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  AnimeSourceVideoClient client({http.Client? httpClient}) =>
      AnimeSourceVideoClient(
        manager: manager,
        context: _context,
        anime: anime,
        episodes: sortEpisodesForPlayback(episodes),
        httpClient:
            httpClient ?? MockClient((_) async => http.Response('', 404)),
      );

  test('episodes become playlist members with stable url-based ids', () {
    final AnimeSourceVideoClient c = client();
    final List<RemoteVideoInfo> videos = c.remoteVideos;
    expect(videos.map((RemoteVideoInfo v) => v.title), <String>[
      'Episode 1',
      'Episode 2',
    ]);
    expect(
      videos.first.id,
      'anime-source:eu.kanade.tachiyomi.animeextension.all.fixture:42:/ep/1',
    );
    expect(videos.first.collection?.collectionType, 'playlist');
    expect(videos.first.collection?.collectionName, 'Fixture Show');
    expect(videos.map((RemoteVideoInfo v) => v.collection!.sortIndex), <int>[
      0,
      1,
    ]);
    expect(videos.first.coverUrl, anime.coverUrl);
    expect(c, isA<RemoteVideoClient>());
    expect(c, isA<RemoteCoverFetcher>());
    expect(c.coverCacheNamespace, c.remoteLibrarySourceId);
    expect(
      c.remoteLibrarySourceId,
      'anime-source:eu.kanade.tachiyomi.animeextension.all.fixture:42',
    );
  });

  test(
    'stream resolution picks the preferred candidate and exposes its headers',
    () async {
      runtime.videos = <Object?>[
        <Object?, Object?>{
          'url': 'https://cdn.example/720.m3u8',
          'quality': '720p',
          'headers': <Object?, Object?>{'Referer': 'https://site.example/'},
        },
        <Object?, Object?>{
          'url': 'https://cdn.example/1080.m3u8',
          'videoUrl': 'https://cdn.example/1080.m3u8',
          'videoTitle': '1080p',
          'resolution': 1080,
          'preferred': true,
          'headers': <Object?, Object?>{'Referer': 'https://site.example/1080'},
          'subtitleTracks': <Object?>[
            <Object?, Object?>{
              'url': 'https://cdn.example/ja.vtt',
              'lang': '日本語',
            },
          ],
        },
      ];
      final AnimeSourceVideoClient c = client();
      expect(c.httpHeaderFields, isEmpty);
      final String id = c.remoteVideos.first.id;
      final RemoteVideoStreamUrls urls = await c.remoteVideoStreamUrls(id);
      expect(runtime.lastEpisodeUrl, '/ep/1');
      expect(urls.streamUrl, 'https://cdn.example/1080.m3u8');
      expect(urls.subtitleUrl, 'https://cdn.example/ja.vtt');
      expect(urls.subtitleFileName, 'episode_1.日本語.vtt');
      // HLS 不是原容器：内嵌字幕回落路不可用。
      expect(urls.streamIsOriginalContainer, isFalse);
      expect(c.httpHeaderFields, <String, String>{
        'Referer': 'https://site.example/1080',
      });
      // 再次起播同一集要重新问扩展：hoster 给的是一次性 / 短 TTL 地址，重放旧的
      // 等于「重试多少次都失败」（BUG-2617）。
      runtime.videoListCalls = 0;
      await c.remoteVideoStreamUrls(id);
      expect(runtime.videoListCalls, 1);
    },
  );

  test('a pinned candidate wins over the default policy', () async {
    runtime.videos = <Object?>[
      <Object?, Object?>{
        'url': 'https://cdn.example/1080.mp4',
        'quality': '1080p',
      },
      <Object?, Object?>{
        'url': 'https://cdn.example/480.mp4',
        'quality': '480p',
      },
    ];
    final AnimeSourceVideoClient c = client();
    final MihonEpisode first = c.episodes.first;
    final List<MihonVideo> candidates = await c.resolveVideos(first);
    c.pinVideo(first, candidates.last);
    final RemoteVideoStreamUrls urls = await c.remoteVideoStreamUrls(
      c.episodeVideoId(first),
    );
    expect(urls.streamUrl, 'https://cdn.example/480.mp4');
    expect(urls.streamIsOriginalContainer, isTrue);
  });

  test(
    'stream variants list the current episode and switching pins a line '
    'whose headers follow',
    () async {
      runtime.videos = <Object?>[
        <Object?, Object?>{
          'url': 'https://a.example/1080.m3u8',
          'quality': 'A · 1080p',
          'headers': <Object?, Object?>{'Referer': 'https://a.example/'},
        },
        <Object?, Object?>{
          'url': 'https://b.example/720.mp4',
          'quality': '',
          'headers': <Object?, Object?>{'Referer': 'https://b.example/'},
        },
      ];
      final AnimeSourceVideoClient c = client();
      // 尚未取流：没有「当前集」，菜单为空、下标 -1、设下标是 no-op。
      expect(c.streamVariants, isEmpty);
      expect(c.streamVariantIndex, -1);
      c.streamVariantIndex = 1;
      final String id = c.remoteVideos.first.id;
      final RemoteVideoStreamUrls first = await c.remoteVideoStreamUrls(id);
      expect(first.streamUrl, 'https://a.example/1080.m3u8');
      // 没给画质名的候选退到主机名，仍能分辨是哪家 hoster。
      expect(
        c.streamVariants.map((RemoteVideoStreamVariant v) => v.label).toList(),
        <String>['A · 1080p', 'b.example'],
      );
      expect(c.streamVariantIndex, 0);
      c.streamVariantIndex = 1;
      // 设下标只是钉住：要等播放页重新取流才切换（当前流的头也随之换）。
      expect(c.httpHeaderFields, <String, String>{
        'Referer': 'https://a.example/',
      });
      final RemoteVideoStreamUrls switched = await c.remoteVideoStreamUrls(id);
      expect(switched.streamUrl, 'https://b.example/720.mp4');
      expect(c.streamVariantIndex, 1);
      expect(c.httpHeaderFields, <String, String>{
        'Referer': 'https://b.example/',
      });
      // 换到另一集：菜单跟着变成那一集的候选，钉住的选择只对原来那集有效。
      runtime.videos = <Object?>[
        <Object?, Object?>{'url': 'https://c.example/ep2.mp4', 'quality': 'C'},
      ];
      final RemoteVideoStreamUrls second = await c.remoteVideoStreamUrls(
        c.remoteVideos.last.id,
      );
      expect(second.streamUrl, 'https://c.example/ep2.mp4');
      expect(
        c.streamVariants.map((RemoteVideoStreamVariant v) => v.label).toList(),
        <String>['C'],
      );
      expect(c.streamVariantIndex, 0);
      // 越界下标不改变钉住的选择。回到第一集会重新问扩展（一次性地址不重放），
      // 钉住的那条按菜单标签在新一批候选里重新认出来——哪怕它这次排在别的位置。
      c.streamVariantIndex = 5;
      runtime.videos = <Object?>[
        <Object?, Object?>{
          'url': 'https://b.example/720.mp4',
          'quality': '',
          'headers': <Object?, Object?>{'Referer': 'https://b.example/'},
        },
        <Object?, Object?>{
          'url': 'https://a.example/1080.m3u8',
          'quality': 'A · 1080p',
          'headers': <Object?, Object?>{'Referer': 'https://a.example/'},
        },
      ];
      final RemoteVideoStreamUrls back = await c.remoteVideoStreamUrls(id);
      expect(back.streamUrl, 'https://b.example/720.mp4');
    },
  );

  test(
    'switching lines reuses the menu, everything else re-resolves (BUG-2617)',
    () async {
      runtime.videos = <Object?>[
        <Object?, Object?>{'url': 'https://a.example/1.m3u8', 'quality': 'A'},
        <Object?, Object?>{'url': 'https://b.example/1.m3u8', 'quality': 'B'},
      ];
      final AnimeSourceVideoClient c = client();
      final String id = c.remoteVideos.first.id;
      await c.remoteVideoStreamUrls(id);

      // 换线路：用户刚看过这批候选，不该再等一轮扩展取流。
      runtime.videoListCalls = 0;
      c.streamVariantIndex = 1;
      final RemoteVideoStreamUrls switched = await c.remoteVideoStreamUrls(id);
      expect(runtime.videoListCalls, 0);
      expect(switched.streamUrl, 'https://b.example/1.m3u8');

      // 复用只放行一次：紧接着的重试（同一集、没再换线路）必须重新解析。
      runtime.videos = <Object?>[
        <Object?, Object?>{'url': 'https://a.example/2.m3u8', 'quality': 'A'},
        <Object?, Object?>{'url': 'https://b.example/2.m3u8', 'quality': 'B'},
      ];
      final RemoteVideoStreamUrls retried = await c.remoteVideoStreamUrls(id);
      expect(runtime.videoListCalls, 1);
      // 新地址，且仍是用户钉住的那条线路。
      expect(retried.streamUrl, 'https://b.example/2.m3u8');
    },
  );

  test('episodes sharing a url still get distinct ids', () async {
    // 有的扩展把集身份放在集号上、url 全部相同（甚至为空）。
    const List<MihonEpisode> sameUrl = <MihonEpisode>[
      MihonEpisode(url: '/watch', name: 'Episode 1', uploadedAt: 1, number: 1),
      MihonEpisode(url: '/watch', name: 'Episode 2', uploadedAt: 2, number: 2),
      MihonEpisode(url: '/watch', name: 'Episode 2b', uploadedAt: 3, number: 2),
      MihonEpisode(url: '/other', name: 'Special', uploadedAt: 4, number: 3),
    ];
    final AnimeSourceVideoClient c = AnimeSourceVideoClient(
      manager: manager,
      context: _context,
      anime: anime,
      episodes: sameUrl,
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final List<String> ids = c.remoteVideos
        .map((RemoteVideoInfo v) => v.id)
        .toList();
    expect(ids.toSet().length, 4);
    // 撞车的按集号去重，集号也撞的再追下标；没撞的（/other）保持原样。
    expect(ids[0], endsWith(':/watch#1'));
    expect(ids[1], endsWith(':/watch#2/1'));
    expect(ids[2], endsWith(':/watch#2/2'));
    expect(ids[3], endsWith(':/other'));
    // 每个 id 都解析回自己那一集（不是第一个同 url 的集）。
    for (int i = 0; i < sameUrl.length; i++) {
      expect(c.episodeForVideoId(ids[i]), same(sameUrl[i]));
      expect(c.episodeVideoId(sameUrl[i]), ids[i]);
    }
    runtime.videos = <Object?>[
      <Object?, Object?>{'url': 'https://cdn.example/x.mp4', 'quality': 'x'},
    ];
    await c.remoteVideoStreamUrls(ids[2]);
    expect(runtime.lastEpisodeUrl, '/watch');
  });

  test('empty candidate list is a typed NO_VIDEOS failure', () async {
    runtime.videos = <Object?>[];
    final AnimeSourceVideoClient c = client();
    await expectLater(
      () => c.remoteVideoStreamUrls(c.remoteVideos.first.id),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException e) => e.code,
          'code',
          'NO_VIDEOS',
        ),
      ),
    );
    await expectLater(
      () => c.remoteVideoStreamUrls('anime-source:other:1:/x'),
      throwsA(isA<ArgumentError>()),
    );
  });

  test(
    'subtitle download sends stream headers only to the same site',
    () async {
      final List<http.Request> requests = <http.Request>[];
      final MockClient httpClient = MockClient((http.Request request) async {
        requests.add(request);
        return http.Response('WEBVTT', 200);
      });
      runtime.videos = <Object?>[
        <Object?, Object?>{
          'url': 'https://cdn.example/ep.m3u8',
          'quality': '1080p',
          'headers': <Object?, Object?>{'Referer': 'https://site.example/'},
          'subtitleTracks': <Object?>[
            <Object?, Object?>{
              'url': 'https://cdn.example/ja.vtt',
              'lang': 'ja',
            },
          ],
        },
      ];
      final AnimeSourceVideoClient sameSite = client(httpClient: httpClient);
      final String id = sameSite.remoteVideos.first.id;
      await sameSite.remoteVideoStreamUrls(id);
      final File dest = File('${root.path}/ja.vtt');
      await sameSite.getRemoteVideoSubtitle(id, dest);
      expect(await dest.readAsString(), 'WEBVTT');
      expect(requests.single.headers['Referer'], 'https://site.example/');

      requests.clear();
      runtime.videos = <Object?>[
        <Object?, Object?>{
          'url': 'https://cdn.example/ep.m3u8',
          'quality': '1080p',
          'headers': <Object?, Object?>{'Referer': 'https://site.example/'},
          'subtitleTracks': <Object?>[
            <Object?, Object?>{
              'url': 'https://subs.other/ja.vtt',
              'lang': 'ja',
            },
          ],
        },
      ];
      final AnimeSourceVideoClient crossSite = client(httpClient: httpClient);
      await crossSite.remoteVideoStreamUrls(crossSite.remoteVideos.first.id);
      await crossSite.getRemoteVideoSubtitle(
        crossSite.remoteVideos.first.id,
        File('${root.path}/other.vtt'),
      );
      expect(requests.single.headers.containsKey('Referer'), isFalse);
    },
  );

  test(
    'covers go through the extension client, positions are local-only',
    () async {
      final AnimeSourceVideoClient c = client();
      expect(await c.fetchRemoteCover('https://site.example/cover.jpg'), <int>[
        1,
        2,
      ]);
      expect(runtime.fetchedImageUrls, <String>[
        'https://site.example/cover.jpg',
      ]);
      expect(await c.remoteVideoPosition(c.remoteVideos.first.id), (
        positionMs: 0,
        updatedAtMs: 0,
      ));
      await expectLater(
        () => c.downloadRemoteVideo(
          c.remoteVideos.first.id,
          File('${root.path}/x'),
        ),
        throwsA(isA<UnsupportedError>()),
      );
    },
  );

  test('audioTracks are dub alternatives, never exposed as audioStreamUrl',
      () async {
    // Aniyomi 的 audioTracks 是替代配音轨；audioStreamUrl 契约是 audio-only 分离流，
    // 塞进去播放页会 audio-add 并选中它——默认切到配音、制卡也从它裁。
    runtime.videos = <Object?>[
      <Object?, Object?>{
        'url': 'https://cdn.example/1080.mp4',
        'quality': '1080p',
        'audioTracks': <Object?>[
          <Object?, Object?>{'url': 'https://cdn.example/dub.aac', 'lang': 'en'},
        ],
      },
    ];
    final AnimeSourceVideoClient c = client();
    final RemoteVideoStreamUrls urls =
        await c.remoteVideoStreamUrls(c.remoteVideos.first.id);
    expect(urls.streamUrl, 'https://cdn.example/1080.mp4');
    expect(urls.audioStreamUrl, isNull);
  });

  test('playback order is by episode number then upload time', () {
    final List<MihonEpisode> sorted =
        sortEpisodesForPlayback(const <MihonEpisode>[
          MihonEpisode(url: '/c', name: 'c', uploadedAt: 3, number: 2),
          MihonEpisode(url: '/b', name: 'b', uploadedAt: 1, number: 2),
          MihonEpisode(url: '/a', name: 'a', uploadedAt: 9, number: 1),
        ]);
    expect(sorted.map((MihonEpisode e) => e.url), <String>['/a', '/b', '/c']);
    // 扩展已按用户偏好排过序：第一条就是它认为最合适的，不再按行数硬推最高。
    expect(
      chooseBestAnimeVideo(const <MihonVideo>[
        MihonVideo(url: 'x', quality: '720p'),
        MihonVideo(url: 'y', quality: '480p'),
        MihonVideo(url: 'z', quality: 'Doodstream 1080p'),
      ]).url,
      'x',
    );
    // lib 16 的 `preferred` 优先于顺序（与 Aniyomi `selectBestVideo` 同口径）。
    expect(
      chooseBestAnimeVideo(const <MihonVideo>[
        MihonVideo(url: 'x', quality: 'Server A'),
        MihonVideo(url: 'y', quality: 'Server B', preferred: true),
      ]).url,
      'y',
    );
  });

  /// BUG-2626：字幕检索要按集号筛版本，而 `RemoteVideoInfo` 能给的两个数字都不是集号
  /// ——`title` 是分集标题（`Episode 1`）、`collection.sortIndex` 是播放序。集号只有
  /// 扩展自己知道（`episode_number`），所以 client 实现 [RemoteVideoEpisodeNumber]。
  test('remoteVideoEpisodeNumber 报扩展给的集号，不是播放序', () {
    final AnimeSourceVideoClient c = client();
    expect(c, isA<RemoteVideoEpisodeNumber>());
    final List<RemoteVideoInfo> videos = c.remoteVideos;
    expect(c.remoteVideoEpisodeNumber(videos[0].id), 1);
    expect(c.remoteVideoEpisodeNumber(videos[1].id), 2);
    // 认不出的 id 一律 null（调用方据此回落，不许拿 0 或序号冒充集号）。
    expect(c.remoteVideoEpisodeNumber('anime-source:nope'), isNull);
  });

  test('集号缺失/小数 → null（宁可留空，不填到隔壁那一集）', () {
    final AnimeSourceVideoClient c = AnimeSourceVideoClient(
      manager: manager,
      context: _context,
      anime: anime,
      episodes: const <MihonEpisode>[
        // 扩展没给 episode_number（`MihonEpisode.number` 解析时回落 0）。
        MihonEpisode(url: '/ep/x', name: 'Special', uploadedAt: 1, number: 0),
        // 总集篇/特别篇的小数号：字幕站的 episode 字段放不下，四舍五入会指错集。
        MihonEpisode(url: '/ep/y', name: 'Recap', uploadedAt: 2, number: 1.5),
      ],
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    for (final RemoteVideoInfo v in c.remoteVideos) {
      expect(c.remoteVideoEpisodeNumber(v.id), isNull);
    }
  });
}

const MihonSourceContext _context = MihonSourceContext(
  extension: MihonExtensionRef(
    packageName: 'eu.kanade.tachiyomi.animeextension.all.fixture',
    apkPath: '/tmp/fixture.apk',
  ),
  source: MihonSource(
    extensionPackage: 'eu.kanade.tachiyomi.animeextension.all.fixture',
    id: '42',
    name: 'Fixture',
    language: 'all',
    baseUrl: 'https://site.example',
  ),
  preferences: <MihonPreference>[],
);

class _VideoRuntime extends MihonBridgeRuntime {
  Object? videos = <Object?>[];
  String? lastEpisodeUrl;
  int videoListCalls = 0;
  final List<String> fetchedImageUrls = <String>[];

  @override
  Future<Object?> invokeBridge(
    MihonExtensionRef extension,
    String method,
    Map<String, Object?> arguments, {
    MihonSource? source,
  }) async {
    if (method == 'getVideoList') {
      videoListCalls++;
      lastEpisodeUrl =
          (arguments['episodeData']! as Map<String, Object?>)['url']
              ?.toString();
      return videos;
    }
    throw UnimplementedError(method);
  }

  @override
  Future<Uint8List> fetchSourceImage(
    MihonExtensionRef extension,
    MihonSource source,
    String url, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    fetchedImageUrls.add(url);
    return Uint8List.fromList(<int>[1, 2]);
  }

  @override
  Future<Uint8List> fetchImage(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) => throw UnimplementedError();

  @override
  Future<MihonCapabilities> getCapabilities() => throw UnimplementedError();

  @override
  Future<MihonExtensionInspection> inspectExtension(String apkPath) =>
      throw UnimplementedError();

  @override
  Future<String> installPrivateExtension(String apkPath) =>
      throw UnimplementedError();

  @override
  Future<void> uninstallPrivateExtension(String packageName) =>
      throw UnimplementedError();

  @override
  Future<void> clearSourceData(
    MihonExtensionRef extension,
    MihonSource source,
  ) => throw UnimplementedError();

  @override
  Future<void> invalidateExtension(String packageName) =>
      throw UnimplementedError();

  @override
  Future<void> invalidateExtensions(Iterable<String> packageNames) =>
      throw UnimplementedError();

  @override
  Future<void> dispose() async {}
}

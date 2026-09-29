import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_bridge_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';

/// Aniyomi（视频）调用面的 wire 契约：方法名、入参键、响应解码。桌面 sidecar
/// 与 Android 宿主两侧的分发表都按这些名字实现，改一处必须两侧同改。
void main() {
  group('MihonMediaKind', () {
    test('inspection kind defaults to manga for hosts without the field', () {
      final MihonExtensionInspection inspection =
          MihonExtensionInspection.fromJson(const <String, Object?>{
            'packageName': 'eu.kanade.tachiyomi.extension.ja.fixture',
            'name': 'Fixture',
            'versionCode': 1,
            'versionName': '1.4.1',
            'libVersion': '1.4',
            'signerSha256': 'aabb',
            'sourceClasses': <String>['.Fixture'],
          });
      expect(inspection.kind, MihonMediaKind.manga);
      expect(
        MihonExtensionInspection.fromJson(const <String, Object?>{
          'packageName': 'eu.kanade.tachiyomi.animeextension.all.fixture',
          'name': 'Fixture',
          'versionCode': 9,
          'versionName': '14.9',
          'libVersion': '14',
          'signerSha256': 'aabb',
          'sourceClasses': <String>['.Fixture'],
          'kind': 'anime',
        }).kind,
        MihonMediaKind.anime,
      );
    });

    test('lib gate is per ecosystem: manga 1.4/1.6, anime 14 only', () {
      expect(MihonMediaKind.manga.supportedLibVersions, <String>['1.4', '1.6']);
      expect(MihonMediaKind.anime.supportedLibVersions, <String>[
        '14',
        '15',
        '16',
      ]);
      expect(MihonMediaKind.fromDbValue('anime'), MihonMediaKind.anime);
      expect(MihonMediaKind.fromDbValue(null), MihonMediaKind.manga);
    });
  });

  group('MihonVideo', () {
    test('decodes the sidecar projection and resolves the playable url', () {
      final MihonVideo video = MihonVideo.fromJson(const <String, Object?>{
        'url': 'https://site.example/watch/1',
        'quality': 'Vidstream 1080p',
        'videoUrl': 'https://cdn.example/ep1.m3u8',
        'headers': <Object?, Object?>{'Referer': 'https://site.example/'},
        'subtitleTracks': <Object?>[
          <Object?, Object?>{
            'url': 'https://cdn.example/ja.vtt',
            'lang': '日本語',
          },
          <Object?, Object?>{'url': '', 'lang': 'dropped'},
        ],
      });
      expect(video.resolvedUrl, 'https://cdn.example/ep1.m3u8');
      expect(video.headers, <String, String>{
        'Referer': 'https://site.example/',
      });
      expect(video.subtitleTracks.map((MihonVideoTrack t) => t.lang), <String>[
        '日本語',
      ]);
      expect(video.resolutionHint, 1080);
    });

    test('lib-16 wire: videoTitle, resolution and preferred are decoded', () {
      final MihonVideo video = MihonVideo.fromJson(const <String, Object?>{
        'url': 'https://cdn.example/ep1.m3u8',
        'quality': '',
        'videoUrl': 'https://cdn.example/ep1.m3u8',
        'videoTitle': 'Japanese - 1080p',
        'resolution': 1080,
        'bitrate': 4000000,
        'preferred': true,
        'mpvArgs': <Object?>[
          <Object?, Object?>{
            'key': 'http-header-fields',
            'value': 'Referer: https://site.example/',
          },
        ],
      });
      expect(video.quality, 'Japanese - 1080p');
      expect(video.resolution, 1080);
      expect(video.bitrate, 4000000);
      expect(video.preferred, isTrue);
      expect(video.resolutionHint, 1080);
      expect(video.mpvArgs.single.key, 'http-header-fields');
      // 自报行数优先于画质文本里猜出来的数字。
      expect(
        MihonVideo.fromJson(const <String, Object?>{
          'url': 'x',
          'quality': '720p',
          'resolution': 1080,
        }).resolutionHint,
        1080,
      );
    });

    test(
      'lib-14 convention: a null or "null" videoUrl means url is the stream',
      () {
        expect(
          MihonVideo.fromJson(const <String, Object?>{
            'url': 'https://cdn.example/direct.mp4',
            'quality': 'Auto',
            'videoUrl': 'null',
          }).resolvedUrl,
          'https://cdn.example/direct.mp4',
        );
        expect(
          MihonVideo.fromJson(const <String, Object?>{
            'url': 'https://cdn.example/direct.mp4',
            'quality': 'Auto',
          }).resolutionHint,
          isNull,
        );
      },
    );
  });

  group('MihonBridgeRuntime anime methods', () {
    late _RecordingBridge bridge;
    const MihonExtensionRef extension = MihonExtensionRef(
      packageName: 'eu.kanade.tachiyomi.animeextension.all.fixture',
      apkPath: '/tmp/fixture.apk',
    );
    const MihonSource source = MihonSource(
      extensionPackage: 'eu.kanade.tachiyomi.animeextension.all.fixture',
      id: '42',
      name: 'Fixture',
      language: 'all',
      baseUrl: 'https://site.example',
    );

    setUp(() => bridge = _RecordingBridge());

    test('listAnimeSources uses sourcesAnime', () async {
      bridge.response = <Object?>[
        <Object?, Object?>{
          'id': '42',
          'name': 'Fixture',
          'lang': 'all',
          'baseUrl': 'https://site.example',
        },
      ];
      final List<MihonSource> sources = await bridge.listAnimeSources(
        extension,
      );
      expect(bridge.lastMethod, 'sourcesAnime');
      expect(sources.single.id, '42');
      expect(sources.single.extensionPackage, extension.packageName);
    });

    test(
      'browse methods send animeData / episodeData and decode pages',
      () async {
        bridge.response = <Object?, Object?>{
          'animes': <Object?>[
            <Object?, Object?>{'url': '/a/1', 'title': 'One'},
          ],
          'hasNextPage': true,
        };
        final MihonAnimePage popular = await bridge.getPopularAnime(
          extension,
          source,
          page: 2,
        );
        expect(bridge.lastMethod, 'getPopularAnime');
        expect(bridge.lastArguments['page'], 2);
        expect(popular.items.single.title, 'One');
        expect(popular.hasNextPage, isTrue);

        await bridge.searchAnime(
          extension,
          source,
          page: 1,
          query: 'ラブ',
          filters: const <MihonFilter>[
            MihonFilter(name: 'Sort', kind: MihonFilterKind.select, state: 1),
          ],
        );
        expect(bridge.lastMethod, 'getSearchAnime');
        expect(bridge.lastArguments['search'], 'ラブ');
        final List<Object?> filterList =
            bridge.lastArguments['filterList']! as List<Object?>;
        expect((filterList.single as Map<String, Object?>)['stateInt'], 1);

        bridge.response = <Object?, Object?>{
          'url': '',
          'title': 'One (details)',
          'description': 'desc',
        };
        final MihonAnime details = await bridge.getAnimeDetails(
          extension,
          source,
          const MihonAnime(url: '/a/1', title: 'One'),
        );
        expect(bridge.lastMethod, 'getDetailsAnime');
        expect(
          (bridge.lastArguments['animeData']! as Map<String, Object?>)['url'],
          '/a/1',
        );
        // 详情是增量：身份 url 只来自入参。
        expect(details.url, '/a/1');
        expect(details.title, 'One (details)');

        bridge.response = <Object?>[
          <Object?, Object?>{
            'url': '/e/2',
            'name': 'Episode 2',
            'episode_number': 2.0,
            'date_upload': 5,
          },
        ];
        final List<MihonEpisode> episodes = await bridge.getEpisodes(
          extension,
          source,
          details,
        );
        expect(bridge.lastMethod, 'getEpisodeList');
        expect(episodes.single.number, 2.0);

        bridge.response = <Object?>[
          <Object?, Object?>{
            'url': 'https://cdn.example/a.m3u8',
            'quality': '720p',
          },
          <Object?, Object?>{'url': '', 'quality': 'broken'},
        ];
        final List<MihonVideo> videos = await bridge.getVideos(
          extension,
          source,
          episodes.single,
        );
        expect(bridge.lastMethod, 'getVideoList');
        expect(
          (bridge.lastArguments['episodeData']! as Map<String, Object?>)['url'],
          '/e/2',
        );
        // 没有可播地址的候选在这里就滤掉，播放器不吃空串。
        expect(videos.map((MihonVideo v) => v.quality), <String>['720p']);
      },
    );

    test(
      'filters accept both envelopes and preferences use the anime names',
      () async {
        bridge.response = <Object?, Object?>{
          'filterList': <Object?>[
            <Object?, Object?>{
              'name': 'Genre',
              'type': 'select',
              'values': <Object?>['A'],
            },
          ],
        };
        final List<MihonFilter> wrapped = await bridge.getAnimeFilters(
          extension,
          source,
        );
        expect(bridge.lastMethod, 'filtersAnime');
        expect(wrapped.single.kind, MihonFilterKind.select);

        bridge.response = <Object?>[
          <Object?, Object?>{'name': 'Done', 'type': 'triState', 'state': 2},
        ];
        final List<MihonFilter> bare = await bridge.getAnimeFilters(
          extension,
          source,
        );
        expect(bare.single.kind, MihonFilterKind.triState);

        bridge.response = <Object?>[];
        await bridge.getAnimePreferences(extension, source);
        expect(bridge.lastMethod, 'preferencesAnime');
        await bridge.setAnimePreference(
          extension,
          source,
          const MihonPreference(
            key: 'quality',
            kind: MihonPreferenceKind.text,
            title: 'Quality',
            value: '1080p',
          ),
          persisted: const <MihonPreference>[],
        );
        expect(bridge.lastMethod, 'setPreferenceAnime');
        final List<Object?> prefs =
            bridge.lastArguments['preferences']! as List<Object?>;
        expect(
          (prefs.first as Map<String, Object?>)['changedPreferenceKey'],
          'quality',
        );
      },
    );

    test('bridge runtimes expose the anime capability by type', () {
      expect(bridge, isA<AnimeMihonRuntime>());
    });
  });
}

class _RecordingBridge extends MihonBridgeRuntime {
  Object? response;
  String? lastMethod;
  Map<String, Object?> lastArguments = const <String, Object?>{};

  @override
  Future<Object?> invokeBridge(
    MihonExtensionRef extension,
    String method,
    Map<String, Object?> arguments, {
    MihonSource? source,
  }) async {
    lastMethod = method;
    lastArguments = arguments;
    return response;
  }

  @override
  Future<Uint8List> fetchImage(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) => throw UnimplementedError();

  @override
  Future<Uint8List> fetchSourceImage(
    MihonExtensionRef extension,
    MihonSource source,
    String url, {
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

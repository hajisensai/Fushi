// BUG-4056：资料语言留空 = 每部作品按它自己的原语言刮，而不是界面语言。
//
// 钉三层：配置（留空 → followsWorkOriginalLanguage，界面语言只当兜底；服务端
// 显式配置不跟随）、装配（全局跟随时三家 provider 都拿到开关，来源级显式覆盖
// 不跟随）、TMDB 请求端（先查作品 original_language，再按它请求文字与图片）。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_service.dart';
import 'package:fushi_engine/media/video/metadata/anidb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/mal_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/tmdb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('配置：留空 = 按作品原语言', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;
    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
    });
    tearDown(() async {
      prefs.dispose();
      await db.close();
    });

    VideoSourceScrapeGlobalConfig read({bool follow = true}) =>
        VideoSourceScrapeGlobalConfig.fromPreferences(
          prefs,
          resolvedTmdbApiKey: '',
          uiLocaleTag: 'zh-CN',
          emptyLocaleFollowsWorkOriginal: follow,
        );

    test('从没设过资料语言：跟随原语言，界面语言只作兜底', () {
      final VideoSourceScrapeGlobalConfig config = read();
      expect(config.followsWorkOriginalLanguage, isTrue);
      expect(config.locale, 'zh-CN', reason: '原语言推不出时 / 非刮削用途的兜底');
    });

    test('显式设成空白也算留空', () async {
      await prefs.setPref(kVideoMetadataLocalePref, '   ');
      expect(read().followsWorkOriginalLanguage, isTrue);
    });

    test('显式资料语言不跟随原语言，且进运行期指纹', () async {
      final String followFingerprint = read().runtimeFingerprint;
      await prefs.setPref(kVideoMetadataLocalePref, 'zh-CN');
      final VideoSourceScrapeGlobalConfig explicit = read();
      expect(explicit.followsWorkOriginalLanguage, isFalse);
      expect(explicit.locale, 'zh-CN');
      expect(
        explicit.runtimeFingerprint,
        isNot(followFingerprint),
        reason: 'locale 串相同但语义不同，协调器必须重建',
      );
    });

    test('无头服务端（显式 metadata_locale）留空也不跟随原语言', () {
      final VideoSourceScrapeGlobalConfig server = read(follow: false);
      expect(server.followsWorkOriginalLanguage, isFalse);
      expect(server.locale, 'zh-CN');
    });
  });

  group('装配：三家 provider 同一开关', () {
    const VideoSourceScrapeGlobalConfig follow = VideoSourceScrapeGlobalConfig(
      tmdbApiKey: 'KEY',
      locale: 'zh-CN',
      followsWorkOriginalLanguage: true,
    );

    T providerOf<T extends VideoMetadataProvider>(
      VideoMetadataProviderRegistry registry,
      VideoMetadataProviderKind kind,
    ) => registry.provider(kind)! as T;

    test('跟随全局且全局留空 → 都跟随原语言', () {
      final VideoMetadataProviderRegistry registry =
          VideoMetadataProviderRegistry.production(follow);
      expect(
        providerOf<TmdbVideoMetadataProvider>(
          registry,
          VideoMetadataProviderKind.tmdb,
        ).followOriginalLanguage,
        isTrue,
      );
      expect(
        providerOf<AniDbVideoMetadataProvider>(
          registry,
          VideoMetadataProviderKind.anidb,
        ).followOriginalLanguage,
        isTrue,
      );
      expect(
        providerOf<MalVideoMetadataProvider>(
          registry,
          VideoMetadataProviderKind.mal,
        ).followOriginalLanguage,
        isTrue,
      );
    });

    test('来源级显式覆盖 → 按覆盖语言，不跟随原语言', () {
      final VideoMetadataProviderRegistry registry =
          VideoMetadataProviderRegistry.production(follow, locale: 'zh-CN');
      final TmdbVideoMetadataProvider tmdb = providerOf(
        registry,
        VideoMetadataProviderKind.tmdb,
      );
      expect(tmdb.followOriginalLanguage, isFalse);
      expect(tmdb.language, 'zh-CN');
      expect(
        providerOf<AniDbVideoMetadataProvider>(
          registry,
          VideoMetadataProviderKind.anidb,
        ).followOriginalLanguage,
        isFalse,
      );
    });
  });

  // 发现页不跟随作品原语言（BUG-4056 只改刮削）：资料语言留空时发现页的详情 /
  // 身份解析 provider 仍按资料语言兜底（界面语言）取，和详情合并的
  // metadataLocale 同源。
  test('发现页：资料语言留空也按资料语言兜底取，不跟随原语言', () {
    const VideoSourceScrapeGlobalConfig follow = VideoSourceScrapeGlobalConfig(
      tmdbApiKey: 'KEY',
      locale: 'zh-CN',
      followsWorkOriginalLanguage: true,
    );
    final VideoDiscoveryService service = VideoDiscoveryService.production(
      follow,
      discoveryAvailable: true,
    );
    addTearDown(service.close);
    final TmdbVideoMetadataProvider tmdb =
        service.metadataProviderForTesting(VideoMetadataProviderKind.tmdb)!
            as TmdbVideoMetadataProvider;
    expect(tmdb.followOriginalLanguage, isFalse);
    expect(tmdb.language, 'zh-CN');
    final MalVideoMetadataProvider mal =
        service.metadataProviderForTesting(VideoMetadataProviderKind.mal)!
            as MalVideoMetadataProvider;
    expect(mal.followOriginalLanguage, isFalse);
    final AniDbVideoMetadataProvider anidb =
        service.metadataProviderForTesting(VideoMetadataProviderKind.anidb)!
            as AniDbVideoMetadataProvider;
    expect(anidb.followOriginalLanguage, isFalse);
    expect(anidb.language, 'zh-CN');
  });

  group('TMDB：按作品 original_language 请求文字与图片', () {
    http.Response json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );

    const VideoMetadataLookup lookup = VideoMetadataLookup(
      provider: VideoMetadataProviderKind.tmdb,
      externalId: '100',
      mediaKind: VideoMetadataMediaKind.tv,
    );

    MockClient client(List<Uri> requests) =>
        MockClient((http.Request request) async {
          requests.add(request.url);
          final String language = request.url.queryParameters['language'] ?? '';
          final bool japanese = language.startsWith('ja');
          if (request.url.path.endsWith('/tv/100')) {
            return json(<String, Object?>{
              'id': 100,
              'name': japanese ? 'フリーレン' : 'Furilian',
              'original_name': 'フリーレン',
              'original_language': 'ja',
              'overview': japanese ? 'ja-overview' : 'zh-overview',
            });
          }
          return json(<String, Object?>{'results': <Object?>[]});
        });

    test('跟随原语言：界面 zh-CN 也拿日文资料与日文图片', () async {
      final List<Uri> requests = <Uri>[];
      final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
        apiKey: 'KEY',
        client: client(requests),
        language: 'zh-CN',
        followOriginalLanguage: true,
      );
      addTearDown(provider.close);

      final VideoMetadataWork work = (await provider.fetchWork(lookup))!;
      expect(work.title, 'フリーレン');
      expect(work.plot, 'ja-overview');
      final Uri details = requests.singleWhere(
        (Uri uri) => uri.queryParameters.containsKey('append_to_response'),
      );
      expect(details.queryParameters['language'], 'ja');
      expect(
        details.queryParameters['include_image_language'],
        'ja,en,null',
        reason: '图片语言与文字同源，按原语言',
      );

      // 原语言探针与详情都走缓存：再取一次不再多打请求。
      final int before = requests.length;
      await provider.fetchWork(lookup);
      expect(requests.length, before);
    });

    test('不跟随原语言：照旧按资料语言', () async {
      final List<Uri> requests = <Uri>[];
      final TmdbVideoMetadataProvider provider = TmdbVideoMetadataProvider(
        apiKey: 'KEY',
        client: client(requests),
        language: 'zh-CN',
      );
      addTearDown(provider.close);
      expect((await provider.fetchWork(lookup))!.title, 'Furilian');
      final List<Uri> details = requests
          .where((Uri uri) => uri.path.endsWith('/tv/100'))
          .toList();
      expect(details, hasLength(1), reason: '不另查原语言');
      expect(details.single.queryParameters['language'], 'zh-CN');
    });
  });
}

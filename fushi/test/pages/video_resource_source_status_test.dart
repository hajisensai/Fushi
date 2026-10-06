// BUG-2794：资源搜索页（发现 → 搜索资源）端到端：
// ① TMDB 卡片没有罗马字别名时，页面先经宿主端口补齐别名，再搜——搜索框预填词
//    随之换成罗马字，Nyaa 同时补查日文原名；
// ② 结果上方逐源显示「N 条（查询词 …）/ 失败原因」，成功但 0 条的源也在。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';
import 'package:fushi_engine/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

import '../torrent/nyaa_html_fixture.dart';
import '../helpers/glass_unwrap.dart';

class _TimeoutProvider implements VideoResourceProvider {
  @override
  String get id => 'torznab';
  @override
  int get priority => 300;
  @override
  Set<VideoDiscoveryCategory> get categories =>
      const <VideoDiscoveryCategory>{};
  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async => ProviderBatchResult<VideoResourceCandidate>.failure(
    const ExternalProviderFailure(
      providerId: 'torznab',
      operation: 'search',
      kind: ExternalProviderFailureKind.timeout,
      message: 'timed out',
    ),
  );
  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) =>
      throw UnimplementedError();
  @override
  void close() {}
}

const MediaSourceRow _source = MediaSourceRow(
  videoGroupingMode: 'series',
  id: 1,
  label: 'Videos',
  mediaKind: 'video',
  transport: 'local',
  rootPath: 'D:/videos',
  mediaCount: 0,
  recursive: true,
  sortOrder: 0,
  createdAt: 1,
);

VideoDiscoveryItem _tmdbCard() => VideoDiscoveryItem(
  reference: VideoMediaReference(
    providerId: 'tmdb',
    mediaId: '209867',
    mediaKind: VideoMetadataMediaKind.tv,
    discoveryCategory: VideoDiscoveryCategory.anime,
    title: '葬送的芙莉莲',
    originalTitle: '葬送のフリーレン',
    aliases: const <String>['葬送のフリーレン'],
    tmdbId: 209867,
  ),
);

VideoResourceRegistry _registry(List<String> queries) =>
    VideoResourceRegistry(<VideoResourceProvider>[
      NyaaVideoResourceProvider(
        client: NyaaClient(
          minRequestInterval: Duration.zero,
          client: MockClient((http.Request request) async {
            final String query = request.url.queryParameters['q']!;
            queries.add(query);
            if (!query.contains('Frieren')) {
              return http.Response(kNyaaNoResultsHtml, 200);
            }
            return http.Response(
              nyaaSearchHtml(<NyaaHtmlRow>[
                NyaaHtmlRow(
                  title: '[SubsPlease] Sousou no Frieren - 01 (1080p)',
                  infoHash: 'a' * 40,
                  id: '1',
                  seeders: 30,
                ),
              ]),
              200,
            );
          }),
        ),
      ),
      _TimeoutProvider(),
    ]);

Future<void> _pump(
  WidgetTester tester, {
  required VideoResourceRegistry registry,
  VideoDiscoveryItemAliasResolver? resolveAliases,
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(registry.close);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: VideoResourceSearchSurface(
            pageMode: true,
            initialItem: _tmdbCard(),
            registry: registry,
            sources: const <MediaSourceRow>[_source],
            resolveAliases: resolveAliases,
            onSubmit: (_) async {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String _statusText(WidgetTester tester, String providerId) {
  final Finder row = find.byKey(
    ValueKey<String>('video-resource-source-status-$providerId'),
  );
  expect(row, findsOneWidget);
  return tester
      .widget<Text>(find.descendant(of: row, matching: find.byType(Text)))
      .data!;
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('没有罗马字的卡片：先补齐别名，Nyaa 用罗马字 + 日文原名各查一次', (
    WidgetTester tester,
  ) async {
    final List<String> queries = <String>[];
    int resolveCalls = 0;
    await _pump(
      tester,
      registry: _registry(queries),
      resolveAliases: (VideoDiscoveryItem item) async {
        resolveCalls += 1;
        return item.withReference(
          item.reference.withLeadingAliases(<String?>['Sousou no Frieren']),
        );
      },
    );

    expect(resolveCalls, 1);
    // 预填词跟着换成补齐后的首选罗马字。
    final TextField field = tester.widget<TextField>(glassUnwrap<TextField>(find.byKey(const ValueKey<String>('video-resource-query'))),);
    expect(field.controller!.text, 'Sousou no Frieren');
    expect(queries, <String>['Sousou no Frieren', '葬送のフリーレン']);
    expect(
      _statusText(tester, kNyaaResourceProviderId),
      t.video_resource_source_result(
        name: 'Nyaa',
        n: 1,
        queries: 'Sousou no Frieren 1 · 葬送のフリーレン 0',
      ),
    );
    expect(
      _statusText(tester, 'torznab'),
      t.video_resource_source_failed(
        name: 'Torznab',
        reason: t.video_resource_failure_timeout,
      ),
    );
    expect(
      find.text(
        '[SubsPlease] Sousou no Frieren - 01 (1080p)',
        skipOffstage: false,
      ),
      findsWidgets,
    );
  });

  testWidgets('补齐不到罗马字时：Nyaa 如实显示「0 条（日文原名 0）」而不是隐形', (
    WidgetTester tester,
  ) async {
    final List<String> queries = <String>[];
    await _pump(
      tester,
      registry: _registry(queries),
      resolveAliases: (VideoDiscoveryItem item) async => item,
    );

    expect(queries, <String>['葬送のフリーレン']);
    expect(
      _statusText(tester, kNyaaResourceProviderId),
      t.video_resource_source_result(name: 'Nyaa', n: 0, queries: '葬送のフリーレン 0'),
    );
  });

  testWidgets('卡片已有罗马字：不调补齐端口', (WidgetTester tester) async {
    int resolveCalls = 0;
    final List<String> queries = <String>[];
    final VideoResourceRegistry registry = _registry(queries);
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(registry.close);
    final VideoDiscoveryItem card = _tmdbCard();
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: VideoResourceSearchSurface(
              pageMode: true,
              initialItem: card.withReference(
                card.reference.withLeadingAliases(<String?>[
                  'Sousou no Frieren',
                ]),
              ),
              registry: registry,
              sources: const <MediaSourceRow>[_source],
              resolveAliases: (VideoDiscoveryItem item) async {
                resolveCalls += 1;
                return item;
              },
              onSubmit: (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(resolveCalls, 0);
    expect(queries, <String>['Sousou no Frieren', '葬送のフリーレン']);
  });
}

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart'
    as discovery;
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/pages/implementations/video_discovery_page.dart';

typedef _LoadHandler = Future<ProviderBatchResult<discovery.VideoDiscoveryPage>>
    Function(
  discovery.VideoDiscoveryRequest request,
);

class _FakeDiscoveryController implements VideoDiscoveryController {
  _FakeDiscoveryController(this.handler);

  final _LoadHandler handler;
  final List<discovery.VideoDiscoveryRequest> requests =
      <discovery.VideoDiscoveryRequest>[];

  @override
  Future<ProviderBatchResult<discovery.VideoDiscoveryPage>> load(
    discovery.VideoDiscoveryRequest request,
  ) {
    requests.add(request);
    return handler(request);
  }
}

discovery.VideoDiscoveryItem _item(
  String id,
  String title, {
  discovery.VideoDiscoveryCategory category =
      discovery.VideoDiscoveryCategory.movie,
  VideoMetadataMediaKind mediaKind = VideoMetadataMediaKind.movie,
  String? posterUrl,
  List<String> genres = const <String>['Drama'],
}) {
  return discovery.VideoDiscoveryItem(
    reference: discovery.VideoMediaReference(
      providerId: 'test',
      mediaId: id,
      mediaKind: mediaKind,
      discoveryCategory: category,
      title: title,
      year: 2026,
    ),
    posterUrl: posterUrl,
    genres: genres,
    score: 8.4,
  );
}

ProviderBatchResult<discovery.VideoDiscoveryPage> _result(
  List<discovery.VideoDiscoveryItem> items, {
  bool hasMore = false,
  List<ExternalProviderFailure> failures = const <ExternalProviderFailure>[],
  int successfulProviderCount = 1,
}) {
  return ProviderBatchResult<discovery.VideoDiscoveryPage>(
    items: <discovery.VideoDiscoveryPage>[
      discovery.VideoDiscoveryPage(
        items: items,
        page: 1,
        hasMore: hasMore,
      ),
    ],
    failures: failures,
    successfulProviderCount: successfulProviderCount,
  );
}

Widget _harness(
  VideoDiscoveryController controller, {
  ValueChanged<discovery.VideoDiscoveryItem>? onOpenItem,
}) {
  return TranslationProvider(
    child: MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: VideoDiscoveryPage(
          navigation: const Text('video navigation'),
          controller: controller,
          onOpenItem: onOpenItem,
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('默认同时加载热门、本季动漫和全部作品', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (discovery.VideoDiscoveryRequest request) async {
        return switch (request.feed) {
          discovery.VideoDiscoveryFeed.trending =>
            _result(<discovery.VideoDiscoveryItem>[
              _item('popular', '热门作品'),
            ]),
          discovery.VideoDiscoveryFeed.airing =>
            _result(<discovery.VideoDiscoveryItem>[
              _item(
                'anime',
                '本季动画',
                category: discovery.VideoDiscoveryCategory.anime,
                mediaKind: VideoMetadataMediaKind.tv,
              ),
            ]),
          _ => _result(<discovery.VideoDiscoveryItem>[
              _item('all', '全部作品条目'),
            ]),
        };
      },
    );

    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    expect(controller.requests, hasLength(3));
    expect(
      find.byKey(const ValueKey<String>('video-discovery-popular')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-discovery-seasonal-anime')),
      findsOneWidget,
    );
    expect(find.text('热门作品'), findsOneWidget);
    expect(find.text('本季动画'), findsOneWidget);
    expect(find.text('全部作品条目'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('video-discovery-category-all')),
      findsOneWidget,
    );
  });

  testWidgets('搜索 350ms 防抖且旧请求不能覆盖新结果', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final Completer<ProviderBatchResult<discovery.VideoDiscoveryPage>> old =
        Completer<ProviderBatchResult<discovery.VideoDiscoveryPage>>();
    final Completer<ProviderBatchResult<discovery.VideoDiscoveryPage>> fresh =
        Completer<ProviderBatchResult<discovery.VideoDiscoveryPage>>();
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (discovery.VideoDiscoveryRequest request) {
        return switch (request.query) {
          'old' => old.future,
          'new' => fresh.future,
          _ => Future<ProviderBatchResult<discovery.VideoDiscoveryPage>>.value(
              _result(const <discovery.VideoDiscoveryItem>[]),
            ),
        };
      },
    );

    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();
    final Finder editable = find.descendant(
      of: find.byKey(const ValueKey<String>('video-discovery-search')),
      matching: find.byType(EditableText),
    );

    await tester.enterText(editable, 'old');
    await tester.pump(const Duration(milliseconds: 349));
    expect(
      controller.requests.where((request) => request.query == 'old'),
      isEmpty,
    );
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      controller.requests.where((request) => request.query == 'old'),
      hasLength(1),
    );

    await tester.enterText(editable, 'new');
    old.complete(_result(<discovery.VideoDiscoveryItem>[
      _item('old', '过期请求结果'),
    ]));
    await tester.pump(const Duration(milliseconds: 349));
    expect(find.text('过期请求结果'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    fresh.complete(_result(<discovery.VideoDiscoveryItem>[
      _item('new', '新请求结果'),
    ]));
    await tester.pump();
    await tester.pump();
    expect(find.text('新请求结果'), findsOneWidget);

    expect(find.text('新请求结果'), findsOneWidget);
    expect(find.text('过期请求结果'), findsNothing);
  });

  testWidgets('筛选态隐藏推荐横栏并显示搜索结果网格', (WidgetTester tester) async {
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (_) async => _result(<discovery.VideoDiscoveryItem>[
        _item('result', '筛选结果'),
      ]),
    );
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('video-discovery-popular')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('video-discovery-category-movie')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('video-discovery-popular')),
      findsNothing,
    );
    expect(find.text(t.video_discovery_search_results), findsOneWidget);
    expect(
      controller.requests.last.category,
      discovery.VideoDiscoveryCategory.movie,
    );
  });

  testWidgets('紧凑布局将搜索与筛选分行且不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(480, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (_) async => _result(<discovery.VideoDiscoveryItem>[
        _item('compact', '紧凑布局作品'),
      ]),
    );

    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('video-discovery-search')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-discovery-filter-year')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('年份、国家、类型和排序筛选控件等高', (WidgetTester tester) async {
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (_) async => _result(<discovery.VideoDiscoveryItem>[
        _item('aligned-filters', '等高筛选控件'),
      ]),
    );
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    final double expectedHeight = tester
        .getSize(
          find.byKey(
            const ValueKey<String>('video-discovery-filter-year'),
          ),
        )
        .height;
    for (final String key in <String>[
      'video-discovery-filter-region',
      'video-discovery-filter-genre',
      'video-discovery-filter-sort',
    ]) {
      expect(
        tester.getSize(find.byKey(ValueKey<String>(key))).height,
        expectedHeight,
      );
    }
  });

  testWidgets('年份输入与题材菜单不依赖首批趋势卡片', (WidgetTester tester) async {
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (_) async => _result(<discovery.VideoDiscoveryItem>[
        _item('current', '首批作品'),
      ]),
    );
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    final Finder yearFinder =
        find.byKey(const ValueKey<String>('video-discovery-filter-year'));
    expect(find.descendant(of: yearFinder, matching: find.byType(TextField)),
        findsOneWidget);
    await tester.enterText(
      find.descendant(of: yearFinder, matching: find.byType(TextField)),
      '1999',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(controller.requests.last.year, 1999);

    final Finder genreFinder =
        find.byKey(const ValueKey<String>('video-discovery-filter-genre'));
    final PopupMenuButton<String> genreMenu =
        tester.widget<PopupMenuButton<String>>(genreFinder);
    final List<PopupMenuEntry<String>> genreEntries =
        genreMenu.itemBuilder(tester.element(genreFinder));
    expect(
      genreEntries
          .whereType<PopupMenuItem<String>>()
          .map((entry) => entry.value),
      contains('Mecha'),
    );
  });

  testWidgets('题材菜单不接纳来源返回的日期类脏值', (WidgetTester tester) async {
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (_) async => _result(<discovery.VideoDiscoveryItem>[
        _item(
          'dirty-genres',
          '异常题材作品',
          genres: const <String>[
            '1993',
            '1993年1月',
            '2000-2009',
            '201707',
            'Drama',
          ],
        ),
      ]),
    );
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    final Finder genreFinder =
        find.byKey(const ValueKey<String>('video-discovery-filter-genre'));
    final PopupMenuButton<String> genreMenu =
        tester.widget<PopupMenuButton<String>>(genreFinder);
    final Iterable<String?> values = genreMenu
        .itemBuilder(tester.element(genreFinder))
        .whereType<PopupMenuItem<String>>()
        .map((PopupMenuItem<String> entry) => entry.value);

    expect(values, contains('Drama'));
    expect(values, isNot(contains('1993')));
    expect(values, isNot(contains('1993年1月')));
    expect(values, isNot(contains('2000-2009')));
    expect(values, isNot(contains('201707')));
  });

  testWidgets('远端封面使用磁盘缓存图片 provider', (WidgetTester tester) async {
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (_) async => _result(<discovery.VideoDiscoveryItem>[
        _item(
          'cached-cover',
          '缓存封面作品',
          posterUrl: 'https://example.com/poster.jpg',
        ),
      ]),
    );
    await tester.pumpWidget(_harness(controller));
    await tester.pump();

    final PortraitCoverImage cover = tester
        .widget<PortraitCoverImage>(find.byType(PortraitCoverImage).first);
    expect(cover.image, isA<CachedNetworkImageProvider>());
  });

  test('年份输入仅接受完整有效年份，空值清除筛选', () {
    expect(parseVideoDiscoveryYearInput('', newestYear: 2028), 0);
    expect(parseVideoDiscoveryYearInput('1999', newestYear: 2028), 1999);
    expect(parseVideoDiscoveryYearInput('20', newestYear: 2028), isNull);
    expect(parseVideoDiscoveryYearInput('1899', newestYear: 2028), isNull);
    expect(parseVideoDiscoveryYearInput('2029', newestYear: 2028), isNull);
  });

  testWidgets('部分来源失败保留结果并展示来源警告', (WidgetTester tester) async {
    const ExternalProviderFailure failure = ExternalProviderFailure(
      providerId: 'bangumi',
      operation: 'discover',
      kind: ExternalProviderFailureKind.timeout,
      message: 'provider request timed out',
      retryable: true,
    );
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (_) async => _result(
        <discovery.VideoDiscoveryItem>[_item('ok', '可用结果')],
        failures: const <ExternalProviderFailure>[failure],
      ),
    );

    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    expect(find.text('可用结果'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('video-discovery-provider-warning')),
      findsOneWidget,
    );
    expect(find.text('bangumi'), findsOneWidget);
  });

  testWidgets('所有来源失败展示可重试错误态', (WidgetTester tester) async {
    const ExternalProviderFailure failure = ExternalProviderFailure(
      providerId: 'tmdb',
      operation: 'discover',
      kind: ExternalProviderFailureKind.network,
      message: 'provider network request failed',
      retryable: true,
    );
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (_) async => ProviderBatchResult<discovery.VideoDiscoveryPage>.failure(
        failure,
      ),
    );

    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('video-discovery-retry')),
      findsOneWidget,
    );
    expect(find.text(t.video_discovery_load_failed), findsOneWidget);
  });
}

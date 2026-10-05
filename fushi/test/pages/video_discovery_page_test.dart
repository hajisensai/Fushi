import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, TextInputAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart'
    as discovery;
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart'
    show VideoDiscoveryActions;
import 'package:fushi/src/pages/implementations/video_discovery_page.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_widgets.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import '../helpers/glass_unwrap.dart';

typedef _LoadHandler = Future<ProviderBatchResult<discovery.VideoDiscoveryPage>>
    Function(
  discovery.VideoDiscoveryRequest request,
);

typedef _ProgressCallback = void Function(
  ProviderBatchResult<discovery.VideoDiscoveryPage> partial,
);

class _FakeDiscoveryController implements VideoDiscoveryController {
  _FakeDiscoveryController(this.handler);

  final _LoadHandler handler;
  final List<discovery.VideoDiscoveryRequest> requests =
      <discovery.VideoDiscoveryRequest>[];

  /// 每次 load 收到的渐进回调（测试据此模拟「快的来源先回来」）。
  final List<_ProgressCallback?> progress = <_ProgressCallback?>[];

  @override
  Future<ProviderBatchResult<discovery.VideoDiscoveryPage>> load(
    discovery.VideoDiscoveryRequest request, {
    _ProgressCallback? onProgress,
  }) {
    requests.add(request);
    progress.add(onProgress);
    return handler(request);
  }

  /// 测试里来源名就是 id 的大写形态，足以把「横幅印的是显示名而不是原始 id」这条
  /// 不变式钉死。
  @override
  String displayNameFor(String providerId) => providerId.toUpperCase();
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
  double scale = 1,
  VideoDiscoveryActions actions = const VideoDiscoveryActions(),
  bool embedded = false,
}) {
  return TranslationProvider(
    child: MaterialApp(
      builder: (BuildContext context, Widget? child) => FushiAppUiScale(
        scale: scale,
        child: child!,
      ),
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: VideoDiscoveryPage(
          navigation: const Text('video navigation'),
          controller: controller,
          actions: actions,
          onOpenItem: onOpenItem,
          embedded: embedded,
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('「AI 下视频」入口只在宿主接线时渲染，点击直接调端口', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (_) async => _result(<discovery.VideoDiscoveryItem>[]),
    );

    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('video-discovery-ai-acquire')),
      findsNothing,
    );

    int opened = 0;
    await tester.pumpWidget(_harness(
      controller,
      actions: VideoDiscoveryActions(onAiAcquire: (_) => opened++),
    ));
    await tester.pumpAndSettle();
    final Finder entry =
        find.byKey(const ValueKey<String>('video-discovery-ai-acquire'));
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await tester.pump();
    expect(opened, 1);
  });

  // PR #1707 审查：浏览页以 embedded 挂视频发现，页头不渲染；放送日历入口原本只在
  // 页头，嵌进浏览后全仓再没有能打开日历的地方。三种宽度（手机 / 中宽 / 桌面）下
  // embedded 都必须能找到可点的日历入口，独立页面时只在页头出现一次。
  for (final double width in <double>[500, 800, 1280]) {
    testWidgets('embedded 时放送日历入口在搜索行可达（宽 $width）',
        (WidgetTester tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final _FakeDiscoveryController controller = _FakeDiscoveryController(
        (_) async => _result(<discovery.VideoDiscoveryItem>[]),
      );
      const ValueKey<String> calendarKey =
          ValueKey<String>('video-discovery-open-calendar');

      await tester.pumpWidget(_harness(controller, embedded: true));
      await tester.pumpAndSettle();
      expect(find.text('video navigation'), findsNothing);
      final Finder entry = find.byKey(calendarKey);
      expect(entry, findsOneWidget);
      final IconButton button = tester.widget<IconButton>(glassUnwrap<IconButton>(entry));
      expect(button.onPressed, isNotNull);
      expect(tester.getRect(entry).right, lessThanOrEqualTo(width));

      await tester.pumpWidget(_harness(controller));
      await tester.pumpAndSettle();
      expect(find.byKey(calendarKey), findsOneWidget);
    });
  }

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

  // 2026-10-05 移动端截图：筛选 chip 下方一条空的暗色胶囊。热门没有数据时
  // Hero 位必须整块不渲染（骨架只在首屏加载中出现），不能留一张空卡壳。
  testWidgets('热门无数据时 Hero 不渲染空壳', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (discovery.VideoDiscoveryRequest request) async =>
          request.feed == discovery.VideoDiscoveryFeed.trending
              ? _result(const <discovery.VideoDiscoveryItem>[])
              : _result(<discovery.VideoDiscoveryItem>[
                  _item('all-${request.feed.name}', '全部作品条目'),
                ]),
    );

    await tester.pumpWidget(_harness(controller, embedded: true));
    await tester.pumpAndSettle();

    expect(find.text('全部作品条目'), findsWidgets);
    expect(find.byType(DiscoveryHeroCarousel), findsNothing);
    expect(find.byType(DiscoveryHeroBanner), findsNothing);
    expect(find.byType(DiscoveryHeroSkeleton), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('video-discovery-popular')),
      findsNothing,
    );
  });

  testWidgets('热门有多条时 Hero 是轮播，滚动后顶缘渐隐、回顶收起',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (discovery.VideoDiscoveryRequest request) async =>
          _result(<discovery.VideoDiscoveryItem>[
        for (int i = 0; i < 8; i++)
          _item('${request.feed.name}-$i', '${request.feed.name} $i'),
      ]),
    );

    await tester.pumpWidget(_harness(controller, embedded: true));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('video-discovery-hero-carousel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('discovery-hero-dot-4')),
      findsOneWidget,
    );
    double fadeOpacity() => tester
        .widget<AnimatedOpacity>(
          find.descendant(
            of: find.byKey(const ValueKey<String>('discovery-scroll-top-fade')),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;
    expect(fadeOpacity(), 0);

    await tester.drag(
      find.byKey(const PageStorageKey<String>('video-discovery-scroll')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(fadeOpacity(), 1);

    await tester.drag(
      find.byKey(const PageStorageKey<String>('video-discovery-scroll')),
      const Offset(0, 600),
    );
    await tester.pumpAndSettle();
    expect(fadeOpacity(), 0);
  });

  // BUG-2620：输入后按回车不搜索——提交动作没有声明，默认 `done` 的收尾又会把
  // 焦点丢掉，观感是「文字被全选、结果还是默认热门」。回车这一路必须确定性地
  // 走到搜索，不能只指望平台 text-input 桥。
  testWidgets('物理回车立即搜索，不必等防抖', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (discovery.VideoDiscoveryRequest request) =>
          Future<ProviderBatchResult<discovery.VideoDiscoveryPage>>.value(
        _result(const <discovery.VideoDiscoveryItem>[]),
      ),
    );

    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();
    final Finder editable = find.descendant(
      of: find.byKey(const ValueKey<String>('video-discovery-search')),
      matching: find.byType(EditableText),
    );

    await tester.enterText(editable, 'Revue Starlight');
    await tester.pump();
    expect(
      controller.requests.where(
        (discovery.VideoDiscoveryRequest request) =>
            request.query == 'Revue Starlight',
      ),
      isEmpty,
      reason: '防抖还没到期，此时只有回车能触发搜索',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      controller.requests.where(
        (discovery.VideoDiscoveryRequest request) =>
            request.query == 'Revue Starlight',
      ),
      hasLength(1),
      reason: '回车必须立即发起搜索',
    );

    // 回车吃掉防抖，不能再补发一次同样的请求。
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      controller.requests.where(
        (discovery.VideoDiscoveryRequest request) =>
            request.query == 'Revue Starlight',
      ),
      hasLength(1),
    );
  });

  testWidgets('BUG-2750 搜索默认按相关度，显式选的排序才覆盖，清空回落热度',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (discovery.VideoDiscoveryRequest request) =>
          Future<ProviderBatchResult<discovery.VideoDiscoveryPage>>.value(
        _result(const <discovery.VideoDiscoveryItem>[]),
      ),
    );

    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();
    expect(
      controller.requests.map((discovery.VideoDiscoveryRequest r) => r.sort),
      everyElement(discovery.VideoDiscoverySort.popularity),
      reason: '没有关键词时按热度浏览',
    );

    final Finder editable = find.descendant(
      of: find.byKey(const ValueKey<String>('video-discovery-search')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(editable, 'Frieren');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.requests.last.query, 'Frieren');
    expect(
      controller.requests.last.sort,
      discovery.VideoDiscoverySort.relevance,
      reason: '搜索按热度重排会把沾边的热门作品顶到精确命中前面',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('video-discovery-filter-sort')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.video_discovery_sort_rating).last);
    await tester.pumpAndSettle();
    expect(controller.requests.last.query, 'Frieren');
    expect(
      controller.requests.last.sort,
      discovery.VideoDiscoverySort.rating,
      reason: '用户显式选的排序必须原样下发',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('video-discovery-filter-sort')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.search).last);
    await tester.pumpAndSettle();
    expect(
      controller.requests.last.sort,
      discovery.VideoDiscoverySort.relevance,
    );

    await tester.enterText(editable, '');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.requests.last.query, isEmpty);
    expect(
      controller.requests.last.sort,
      discovery.VideoDiscoverySort.popularity,
      reason: '相关度只对搜索有意义，清空关键词后回落热度',
    );
  });

  testWidgets('搜索框保留回车提交语义且不丢焦点', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (discovery.VideoDiscoveryRequest request) =>
          Future<ProviderBatchResult<discovery.VideoDiscoveryPage>>.value(
        _result(const <discovery.VideoDiscoveryItem>[]),
      ),
    );

    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();
    final Finder editable = find.descendant(
      of: find.byKey(const ValueKey<String>('video-discovery-search')),
      matching: find.byType(EditableText),
    );
    final EditableText field = tester.widget<EditableText>(editable);
    expect(
      field.textInputAction,
      TextInputAction.search,
      reason: '不声明提交动作时平台给的是 done，收尾会 unfocus',
    );

    await tester.enterText(editable, 'Revue Starlight');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(
      controller.requests.where(
        (discovery.VideoDiscoveryRequest request) =>
            request.query == 'Revue Starlight',
      ),
      hasLength(1),
    );
    expect(
      field.focusNode.hasFocus,
      isTrue,
      reason: '提交后焦点要留在框里：掉焦点会被焦点系统以编程方式还回来，'
          '桌面端随即整段选中文本',
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

  testWidgets('搜索一开始旧的热门列表立即撤下，不在「搜索结果」下冒充结果',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final Completer<ProviderBatchResult<discovery.VideoDiscoveryPage>> search =
        Completer<ProviderBatchResult<discovery.VideoDiscoveryPage>>();
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (discovery.VideoDiscoveryRequest request) => request.isSearch
          ? search.future
          : Future<ProviderBatchResult<discovery.VideoDiscoveryPage>>.value(
              _result(<discovery.VideoDiscoveryItem>[
                _item('hot', '热门作品'),
              ]),
            ),
    );

    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();
    expect(find.text('热门作品'), findsWidgets);

    final Finder editable = find.descendant(
      of: find.byKey(const ValueKey<String>('video-discovery-search')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(editable, 'FX戦士くるみちゃん');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(find.text('热门作品'), findsNothing, reason: '搜索还没返回也不能显示旧列表');

    search.complete(_result(<discovery.VideoDiscoveryItem>[
      _item('fx', 'FX戦士くるみちゃん'),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('FX戦士くるみちゃん'), findsWidgets);
    expect(find.text('热门作品'), findsNothing);
  });

  testWidgets('快的来源先显示并挂细进度条，全部返回后进度条消失',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final Completer<ProviderBatchResult<discovery.VideoDiscoveryPage>> search =
        Completer<ProviderBatchResult<discovery.VideoDiscoveryPage>>();
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (discovery.VideoDiscoveryRequest request) => request.isSearch
          ? search.future
          : Future<ProviderBatchResult<discovery.VideoDiscoveryPage>>.value(
              _result(const <discovery.VideoDiscoveryItem>[]),
            ),
    );

    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();
    final Finder editable = find.descendant(
      of: find.byKey(const ValueKey<String>('video-discovery-search')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(editable, 'Frieren');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final _ProgressCallback onProgress = controller.progress.last!;
    onProgress(_result(<discovery.VideoDiscoveryItem>[
      _item('tmdb', '快来源结果'),
    ]));
    await tester.pump();
    expect(find.text('快来源结果'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('video-discovery-partial-loading')),
      findsOneWidget,
    );

    search.complete(_result(<discovery.VideoDiscoveryItem>[
      _item('tmdb', '快来源结果'),
      _item('mal', '慢来源结果'),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('慢来源结果'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('video-discovery-partial-loading')),
      findsNothing,
    );
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

  testWidgets('手机保留分类和排序，高级筛选在底部面板统一应用', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (_) async => _result(<discovery.VideoDiscoveryItem>[
        _item('compact', '窄屏里仍然完整容纳两行的作品标题'),
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
      findsNothing,
    );
    final Finder search = find.byKey(
      const ValueKey<String>('video-discovery-search'),
    );
    final Finder sort = find.byKey(
      const ValueKey<String>('video-discovery-filter-sort'),
    );
    final Finder category = find.byKey(
      const ValueKey<String>('video-discovery-category-all'),
    );
    expect(
      tester.getCenter(sort).dy,
      closeTo(tester.getCenter(category).dy, 1),
    );
    // 窄屏：搜索框独占整行；日历 / AI / 筛选入口并进分类 chip 行行尾、与排序
    // 同排，不再单占一行（2026-10-05：那一行左半边恒空，白占纵向空间）。
    final Finder openFiltersButton = find.byKey(
      const ValueKey<String>('video-discovery-open-filters'),
    );
    expect(
      tester.getTopLeft(openFiltersButton).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(search).dy),
      reason: '窄屏搜索框应独占一整行',
    );
    expect(
      tester.getCenter(openFiltersButton).dy,
      closeTo(tester.getCenter(category).dy, 1),
      reason: '筛选入口与分类 chip、排序同一行',
    );
    expect(
      tester.getTopLeft(openFiltersButton).dx,
      lessThan(tester.getTopLeft(sort).dx),
    );
    expect(
      tester.getBottomRight(sort).dy - tester.getTopLeft(search).dy,
      lessThan(120),
    );
    final int originalRequests = controller.requests.length;
    await tester.tap(
      find.byKey(const ValueKey<String>('video-discovery-open-filters')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('video-discovery-filter-year')),
    );
    await tester.pumpAndSettle();
    final int year = DateTime.now().year + 1;
    await tester.tap(find.text('$year').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('video-discovery-filter-region')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('JP').last);
    await tester.pumpAndSettle();
    expect(controller.requests, hasLength(originalRequests));
    await tester.tap(
      find.byKey(const ValueKey<String>('video-discovery-apply-filters')),
    );
    await tester.pumpAndSettle();
    expect(controller.requests, hasLength(originalRequests + 1));
    expect(controller.requests.last.year, year);
    expect(controller.requests.last.region, 'JP');
    expect(
      find.byKey(const ValueKey<String>('video-discovery-filter-sheet')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机筛选重置可取消，再次打开保留已应用值', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (_) async => _result(<discovery.VideoDiscoveryItem>[
        _item('narrow', '更窄屏幕也容纳两行标题和年份评分'),
      ]),
    );
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();
    final Finder openFilters = find.byKey(
      const ValueKey<String>('video-discovery-open-filters'),
    );
    final Finder region = find.byKey(
      const ValueKey<String>('video-discovery-filter-region'),
    );
    final Finder apply = find.byKey(
      const ValueKey<String>('video-discovery-apply-filters'),
    );
    final Finder reset = find.byKey(
      const ValueKey<String>('video-discovery-reset-filters'),
    );
    await tester.tap(openFilters);
    await tester.pumpAndSettle();
    await tester.tap(region);
    await tester.pumpAndSettle();
    await tester.tap(find.text('JP').last);
    await tester.pumpAndSettle();
    await tester.tap(apply);
    await tester.pumpAndSettle();
    final int appliedRequests = controller.requests.length;

    await tester.tap(openFilters);
    await tester.pumpAndSettle();
    await tester.tap(reset);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(controller.requests, hasLength(appliedRequests));
    await tester.tap(openFilters);
    await tester.pumpAndSettle();
    expect(tester.widget<PopupMenuButton<String>>(glassUnwrap<PopupMenuButton<String>>(region)).initialValue, 'JP');
    await tester.tap(reset);
    await tester.pumpAndSettle();
    await tester.tap(apply);
    await tester.pumpAndSettle();
    expect(controller.requests.last.region, isNull);
    expect(controller.requests.last.year, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机缩小界面后仍将高级筛选收进面板', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (_) async => _result(const <discovery.VideoDiscoveryItem>[]),
    );
    await tester.pumpWidget(_harness(controller, scale: 0.6));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('video-discovery-open-filters')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('video-discovery-filter-year')),
        findsNothing);
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

  testWidgets('年份与题材菜单不依赖首批趋势卡片', (WidgetTester tester) async {
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (_) async => _result(<discovery.VideoDiscoveryItem>[
        _item('current', '首批作品'),
      ]),
    );
    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    final Finder yearFinder =
        find.byKey(const ValueKey<String>('video-discovery-filter-year'));
    final PopupMenuButton<int> yearMenu =
        tester.widget<PopupMenuButton<int>>(glassUnwrap<PopupMenuButton<int>>(yearFinder));
    final Iterable<int?> yearValues = yearMenu
        .itemBuilder(tester.element(yearFinder))
        .whereType<PopupMenuItem<int>>()
        .map((PopupMenuItem<int> entry) => entry.value);
    expect(yearValues, containsAll(<int>[0, 1999, DateTime.now().year + 2]));
    yearMenu.onSelected!(1999);
    await tester.pumpAndSettle();
    expect(controller.requests.last.year, 1999);

    final Finder genreFinder =
        find.byKey(const ValueKey<String>('video-discovery-filter-genre'));
    final PopupMenuButton<String> genreMenu =
        tester.widget<PopupMenuButton<String>>(glassUnwrap<PopupMenuButton<String>>(genreFinder));
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
        tester.widget<PopupMenuButton<String>>(glassUnwrap<PopupMenuButton<String>>(genreFinder));
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
    // BUG-2430：横幅印的是用户可见来源名，不是接线用的 provider id。
    expect(find.text('bangumi'), findsNothing);
    expect(find.text('BANGUMI'), findsOneWidget);
    // timeout 属于「暂时失败」，不该说成「暂不可用」。
    expect(find.text(t.video_discovery_provider_failed), findsOneWidget);
  });

  testWidgets('限流失败说的是稍后再试，不是来源不可用', (WidgetTester tester) async {
    const ExternalProviderFailure failure = ExternalProviderFailure(
      providerId: 'mal',
      operation: 'search-tv',
      kind: ExternalProviderFailureKind.rateLimited,
      message: 'provider returned HTTP 429',
      statusCode: 429,
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

    expect(find.text(t.video_discovery_provider_rate_limited), findsOneWidget);
    expect(find.text(t.video_discovery_provider_warning), findsNothing);
    expect(find.text('MAL'), findsOneWidget);
  });

  testWidgets('真正的不可用仍然说不可用', (WidgetTester tester) async {
    const ExternalProviderFailure failure = ExternalProviderFailure(
      providerId: 'tmdb',
      operation: 'discover',
      kind: ExternalProviderFailureKind.unavailable,
      message: 'metadata provider is not configured',
    );
    final _FakeDiscoveryController controller = _FakeDiscoveryController(
      (_) async => _result(
        <discovery.VideoDiscoveryItem>[_item('ok', '可用结果')],
        failures: const <ExternalProviderFailure>[failure],
      ),
    );

    await tester.pumpWidget(_harness(controller));
    await tester.pumpAndSettle();

    expect(find.text(t.video_discovery_provider_warning), findsOneWidget);
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

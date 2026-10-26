// 反馈 XFsZIWYbr8：手机竖屏上资源搜索页 / 番剧下载选种页的结果区太扁——
// 查询 / 筛选头部固定在上方，结果只能在中间一条窄缝里滚。
// 契约：窄屏（< 600）结果列表与头部同属一个滚动视图（结果视口吃满头部以下的屏幕），
// 上滑时头部随结果滚走；宽屏头部固定在滚动区外只滚结果。资源搜索页的顶栏标题保持原位不动。
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/anime_download_dialog.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';
import 'package:fushi_core/fushi_core.dart' show MediaSourceRow;
import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart'
    show TorrentAddPayload;
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

import '../helpers/test_platform_services.dart';
import '../torrent/nyaa_html_fixture.dart';

/// 用户机型（vivo V2339FA）的逻辑尺寸 384×853。
const Size _phone = Size(384, 853);
const double _dpr = 3;

void _usePhoneView(WidgetTester tester) {
  tester.view.physicalSize = _phone * _dpr;
  tester.view.devicePixelRatio = _dpr;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// [target] 所在的最近一层纵向滚动视图的视口高度。
double _viewportHeightOf(WidgetTester tester, Finder target) {
  final ScrollableState scrollable = Scrollable.of(tester.element(target));
  return scrollable.position.viewportDimension;
}

class _FakeResource extends VideoResourceCandidate {
  _FakeResource({
    required super.remoteId,
    required super.title,
    super.releaseGroup,
    super.resolution,
    super.seeders,
  }) : super(
         providerId: 'nyaa',
         providerInstanceId: 'nyaa',
         providerPriority: 100,
       );
}

class _SeededProvider implements VideoResourceProvider {
  _SeededProvider(this.items);

  final List<VideoResourceCandidate> items;

  @override
  String get id => 'nyaa';

  @override
  Set<VideoDiscoveryCategory> get categories =>
      const <VideoDiscoveryCategory>{};

  @override
  int get priority => 10;

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async => ProviderBatchResult<VideoResourceCandidate>.success(items);

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      throw UnimplementedError();

  @override
  void close() {}
}

/// 20 个不同发布组 → 20 张版本卡，足以超出一屏。
List<VideoResourceCandidate> _resources() => <VideoResourceCandidate>[
  for (int i = 0; i < 20; i++)
    _FakeResource(
      remoteId: 'r$i',
      title: '[Group$i] Ikoku Nikki - 01 (1080p)',
      releaseGroup: 'Group$i',
      resolution: '1080p',
      seeders: 100 - i,
    ),
];

const MediaSourceRow _source = MediaSourceRow(
  videoGroupingMode: 'series',
  id: 1,
  label: 'videos',
  mediaKind: 'video',
  transport: 'local',
  rootPath: r'D:\media',
  mediaCount: 0,
  recursive: true,
  sortOrder: 0,
  createdAt: 1,
);

VideoDiscoveryItem _item() => VideoDiscoveryItem(
  reference: VideoMediaReference(
    providerId: 'anilist',
    mediaId: '42',
    mediaKind: VideoMetadataMediaKind.tv,
    discoveryCategory: VideoDiscoveryCategory.anime,
    title: 'Ikoku Nikki',
    anilistId: 42,
  ),
);

/// 挂出番剧下载弹窗的选种段（20 条种子）。
Future<void> _pumpAnimeTorrentStage(WidgetTester tester) async {
  final String nyaaHtml = nyaaSearchHtml(<NyaaHtmlRow>[
    for (int i = 0; i < 20; i++)
      NyaaHtmlRow(
        title:
            '[SubsPlease] Ikoku Nikki - ${(i + 1).toString().padLeft(2, '0')} (1080p).mkv',
        infoHash: (i.toRadixString(16).padLeft(2, '0') * 20),
        seeders: 100 - i,
        trusted: true,
      ),
  ]);
  Future<http.Response> handler(http.Request request) async {
    final String url = request.url.toString();
    if (url.contains('nyaa.si')) return http.Response(nyaaHtml, 200);
    return http.Response(
      '[]',
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }

  final _FakeAppModel appModel = _FakeAppModel(handler);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: AnimeDownloadDialog(
              embedded: true,
              showTasks: false,
              initialMedia: const AniListMedia(id: 42, romaji: 'Ikoku Nikki'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('资源搜索页：结果与头部同滚，结果视口吃满屏幕，顶栏不动', (WidgetTester tester) async {
    _usePhoneView(tester);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: VideoDiscoveryResourceSearchPage(
            item: _item(),
            registry: VideoResourceRegistry(<VideoResourceProvider>[
              _SeededProvider(_resources()),
            ]),
            sources: const <MediaSourceRow>[_source],
            defaultSourceId: 1,
            onSubmit: (VideoDiscoveryDownloadSelection selection) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder scroll = find.byKey(
      const ValueKey<String>('video-resource-scroll'),
    );
    final Finder query = find.byKey(
      const ValueKey<String>('video-resource-query'),
    );
    final Finder firstCard = find
        .byWidgetPredicate(
          (Widget w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'resource-version-',
              ),
        )
        .first;
    expect(firstCard, findsOneWidget);

    // 版本卡直接挂在页级滚动视图里，不再嵌一层自带滚动的结果列表。
    expect(find.descendant(of: scroll, matching: firstCard), findsOneWidget);
    expect(
      find.ancestor(of: firstCard, matching: find.byType(ListView)),
      findsNothing,
      reason: '结果若仍是独立 ListView，就只能在头部下方的窄缝里滚',
    );
    final double viewport = _viewportHeightOf(tester, firstCard);
    expect(
      viewport,
      greaterThan(_phone.height * 0.55),
      reason: '结果视口应是顶栏与底部提交区之间的整块区域，而不是头部下方的残余',
    );

    final Finder title = find.text(t.video_discovery_resource_search);
    final Rect titleBefore = tester.getRect(title);
    final double queryTopBefore = tester.getTopLeft(query).dy;

    await tester.drag(scroll, const Offset(0, -500));
    await tester.pumpAndSettle();

    expect(
      Scrollable.of(tester.element(firstCard)).position.pixels,
      greaterThan(0),
    );
    // 头部（搜索框）随结果滚走，顶栏标题原地不动（不随滚动收起，见
    // VideoDiscoveryResourceSearchPage 的 notificationPredicate）。
    expect(
      query.evaluate().isEmpty ||
          tester.getTopLeft(query).dy < queryTopBefore - 200,
      isTrue,
      reason: '查询头部应随结果一起上滑让出屏幕',
    );
    expect(tester.getRect(title), titleBefore);
    expect(
      find.byKey(const ValueKey<String>('video-resource-submit')),
      findsOneWidget,
      reason: '提交按钮固定在滚动视图之外，滚到哪都能提交',
    );
  });

  testWidgets('资源搜索页：宽屏（1280）搜索头固定在滚动区外，只有结果滚', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800) * _dpr;
    tester.view.devicePixelRatio = _dpr;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: VideoDiscoveryResourceSearchPage(
            item: _item(),
            registry: VideoResourceRegistry(<VideoResourceProvider>[
              _SeededProvider(_resources()),
            ]),
            sources: const <MediaSourceRow>[_source],
            defaultSourceId: 1,
            onSubmit: (VideoDiscoveryDownloadSelection selection) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder scroll = find.byKey(
      const ValueKey<String>('video-resource-scroll'),
    );
    final Finder query = find.byKey(
      const ValueKey<String>('video-resource-query'),
    );
    final Finder firstCard = find
        .byWidgetPredicate(
          (Widget w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'resource-version-',
              ),
        )
        .first;
    expect(firstCard, findsOneWidget);
    expect(
      find.descendant(of: scroll, matching: query),
      findsNothing,
      reason: '宽屏搜索头应在滚动视图之外',
    );
    final double queryTopBefore = tester.getTopLeft(query).dy;

    await tester.drag(scroll, const Offset(0, -500));
    await tester.pumpAndSettle();

    expect(
      Scrollable.of(tester.element(firstCard)).position.pixels,
      greaterThan(0),
      reason: '结果应当滚动了',
    );
    expect(query, findsOneWidget);
    expect(tester.getTopLeft(query).dy, queryTopBefore);
  });

  testWidgets('番剧下载选种段：种子列表与查询 / 筛选头部同滚', (WidgetTester tester) async {
    _usePhoneView(tester);
    await _pumpAnimeTorrentStage(tester);

    final Finder scroll = find.byKey(
      const ValueKey<String>('anime-download-torrent-scroll'),
    );
    expect(scroll, findsOneWidget);
    final Finder firstRow = find.textContaining('Ikoku Nikki - 01');
    expect(firstRow, findsOneWidget);
    expect(
      find.ancestor(of: firstRow, matching: find.byType(ListView)),
      findsNothing,
      reason: '种子行应直接挂在选种段的滚动视图里',
    );
    expect(
      _viewportHeightOf(tester, firstRow),
      greaterThan(_phone.height * 0.8),
      reason: '种子列表视口应吃满整个阶段区域',
    );
    // 合集 / 单集筛选仍在头部。
    expect(
      find.byKey(const ValueKey<String>('anime-download-scope-batch')),
      findsOneWidget,
    );
    final Finder queryField = find.widgetWithText(
      TextField,
      t.anime_download_nyaa_query,
    );
    final double queryTopBefore = tester.getTopLeft(queryField).dy;

    await tester.drag(scroll, const Offset(0, -500));
    await tester.pumpAndSettle();

    expect(
      queryField.evaluate().isEmpty ||
          tester.getTopLeft(queryField).dy < queryTopBefore - 200,
      isTrue,
      reason: '查询 / 筛选头部应随种子列表一起上滑',
    );
  });

  testWidgets('番剧下载选种段：宽屏（1280）查询头固定，只滚种子列表', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800) * _dpr;
    tester.view.devicePixelRatio = _dpr;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpAnimeTorrentStage(tester);

    final Finder scroll = find.byKey(
      const ValueKey<String>('anime-download-torrent-scroll'),
    );
    expect(scroll, findsOneWidget);
    final Finder queryField = find.widgetWithText(
      TextField,
      t.anime_download_nyaa_query,
    );
    expect(queryField, findsOneWidget);
    expect(
      find.descendant(of: scroll, matching: queryField),
      findsNothing,
      reason: '宽屏查询头应在滚动视图之外',
    );
    final double queryTopBefore = tester.getTopLeft(queryField).dy;

    await tester.drag(scroll, const Offset(0, -500));
    await tester.pumpAndSettle();

    expect(
      tester
          .state<ScrollableState>(
            find.descendant(of: scroll, matching: find.byType(Scrollable)),
          )
          .position
          .pixels,
      greaterThan(0),
    );
    expect(tester.getTopLeft(queryField).dy, queryTopBefore);
  });
}

class _FakeAppModel extends AppModel {
  _FakeAppModel(this._httpHandler) : super(testPlatformServices());

  // Fushi 不内置 BT 站：番剧选种走用户添加的 Nyaa 式站点。
  @override
  List<BtSiteConfig> get btSites => <BtSiteConfig>[
    BtSiteConfig(
      id: 'test-anime-site',
      baseUrl: Uri.parse('https://nyaa.si'),
      format: BtSiteFormat.nyaa,
      domains: const <BtSiteDomain>{BtSiteDomain.anime},
      nyaaCategories: const <BtSiteDomain, String>{BtSiteDomain.anime: '1_0'},
    ),
  ];

  final Future<http.Response> Function(http.Request request) _httpHandler;
  final _MemPlanStore store = _MemPlanStore();

  @override
  String get jimakuApiKey => 'key';

  @override
  QbConnectionConfig? get qbConnectionConfig => const QbConnectionConfig(
    backend: QbConnectionConfig.backendQbittorrent,
    baseUrl: 'http://127.0.0.1:1',
  );

  @override
  bool get torrentUploadIntroShown => true;

  @override
  bool get p2pDownloadNoticeDismissed => true;

  @override
  AnimeDownloadPlanStore? get animeDownloadPlanStore => store;

  @override
  Future<http.Client> createDownloadHttpClient() async =>
      MockClient(_httpHandler);
}

/// 纯内存计划存储（widget 测试不碰真实文件）。
class _MemPlanStore extends AnimeDownloadPlanStore {
  _MemPlanStore() : super(baseDir: Directory('unused-mem-store'));

  @override
  Future<List<AnimeDownloadPlan>> loadAll() async =>
      const <AnimeDownloadPlan>[];

  @override
  Future<bool> save(AnimeDownloadPlan plan) async => true;

  @override
  Future<void> delete(String id) async {}
}

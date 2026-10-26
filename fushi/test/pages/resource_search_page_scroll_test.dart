// 反馈 XFsZIWYbr8：手机竖屏上资源搜索页的结果区太扁——
// 查询 / 筛选头部固定在上方，结果只能在中间一条窄缝里滚。
// 契约：窄屏（< 600）结果列表与头部同属一个滚动视图（结果视口吃满头部以下的屏幕），
// 上滑时头部随结果滚走；宽屏头部固定在滚动区外只滚结果。资源搜索页的顶栏标题保持原位不动。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';
import 'package:fushi_core/fushi_core.dart' show MediaSourceRow;
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart'
    show TorrentAddPayload;
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

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
         providerId: 'rss',
         providerInstanceId: 'rss:test',
         providerPriority: 100,
       );
}

class _SeededProvider implements VideoResourceProvider {
  _SeededProvider(this.items);

  final List<VideoResourceCandidate> items;

  @override
  String get id => 'rss';

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
}

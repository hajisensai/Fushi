// B2 资源选版：版本卡列表 widget + 下载模式 surface 集成。
// 契约：① 下载模式默认版本卡视图；② 单条组点卡直接选中；③ 多条组点卡展开、
// 点行选中并使提交可用；④「全部条目」开关切回平铺列表。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_download_backend_identity.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';
import 'package:fushi/src/media/video/download/video_resource_version_groups.dart';
import 'package:fushi/src/media/video/episode_span_format.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart'
    show TorrentAddPayload;
import 'package:fushi_core/fushi_core.dart' show MediaSourceRow;

class _FakeResource extends VideoResourceCandidate {
  _FakeResource({
    required super.remoteId,
    required super.title,
    super.providerId = 'nyaa',
    super.providerInstanceId = 'nyaa',
    super.providerPriority = 100,
    super.releaseGroup,
    super.resolution,
    super.seeders,
  });
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

List<VideoResourceCandidate> _items() => <VideoResourceCandidate>[
  for (int ep = 1; ep <= 3; ep++)
    _FakeResource(
      remoteId: 'sp$ep',
      title: '[SubsPlease] Show - 0$ep (1080p)',
      releaseGroup: 'SubsPlease',
      resolution: '1080p',
      seeders: 30,
    ),
  _FakeResource(
    remoteId: 'movie',
    title: '[Erai-raws] Show Movie [720p]',
    releaseGroup: 'Erai-raws',
    resolution: '720p',
    seeders: 5,
  ),
];

VideoDiscoveryItem _item() => VideoDiscoveryItem(
  reference: VideoMediaReference(
    providerId: 'anilist',
    mediaId: '42',
    mediaKind: VideoMetadataMediaKind.tv,
    discoveryCategory: VideoDiscoveryCategory.anime,
    title: 'Show',
    anilistId: 42,
  ),
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('BUG-1986 非连续集号按真实连续段显示，不伪装成 min-max 全范围', () {
    expect(
      formatEpisodeSpans(<int>{17, 1, 4, 2, 16}),
      'EP1–EP2, EP4, EP16–EP17',
    );
  });

  test('BUG-1986 单集与完整连续集保持紧凑显示', () {
    expect(formatEpisodeSpans(<int>{7}), 'EP7');
    expect(formatEpisodeSpans(<int>{1, 2, 3, 4}), 'EP1–EP4');
    expect(formatEpisodeSpans(<int>{}), isEmpty);
  });

  test('BUG-1986 段数超上限时收成「首几段 + 省略号 + 末段」，不让元信息行爆炸', () {
    // 元信息行是 maxLines:1 + ellipsis，段串排在 parts 第一位。不封顶时一个组
    // 吃满 provider 单次上限（100 条）就能展开到几百字符，把后面的相对时间 /
    // 体积 / **做种数**整体挤出可视区——做种数恰恰是这张卡最重要的选择信号。
    final Set<int> scattered = <int>{for (int i = 1; i <= 47; i += 2) i};
    final String out = formatEpisodeSpans(scattered);
    expect(out, 'EP1, EP3, EP5, …, EP47',
        reason: '24 个离散段不封顶会展开成 137 字符，把做种数整条截掉');
    expect(out.length, lessThan(40),
        reason: '上限必须真的把长度框住，而不只是看着短');
    // 末段保留是刻意的：只截前几段会丢掉上界，读者无法判断覆盖到第几集。
    expect(out, contains('EP47'), reason: '上界必须留住');
    expect(out, isNot(contains('EP1–EP47')),
        reason: '收缩后仍然不得伪装成连续范围——那正是 BUG-1986 本体');
  });

  test('BUG-1986 段数正好等于上限时不收缩（边界不 off-by-one）', () {
    // 上限 = 4「段」：4 段原样全出；5 段起收成「前 3 段 + 省略号 + 末段」，
    // 仍然是 4 段真内容，只是中间那段换成省略号。
    expect(formatEpisodeSpans(<int>{1, 3, 5, 7}), 'EP1, EP3, EP5, EP7');
    expect(formatEpisodeSpans(<int>{1, 3, 5, 7, 9}), 'EP1, EP3, EP5, …, EP9');
    // maxSpans == 1 退化成「首段 + 省略号 + 末段」，仍不伪装成连续范围。
    expect(formatEpisodeSpans(<int>{1, 3, 9}, maxSpans: 1), '…, EP9');
  });

  Future<void> pumpSurface(
    WidgetTester tester, {
    VideoDiscoveryDownloadSubmit? onSubmit,
    List<VideoResourceCandidate>? items,
  }) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: VideoDiscoveryResourceSearchDialog(
              item: _item(),
              registry: VideoResourceRegistry(<VideoResourceProvider>[
                _SeededProvider(items ?? _items()),
              ]),
              sources: const <MediaSourceRow>[
                MediaSourceRow(
                  id: 1,
                  label: 'videos',
                  mediaKind: 'video',
                  transport: 'local',
                  rootPath: r'D:\media',
                  mediaCount: 0,
                  recursive: true,
                  sortOrder: 0,
                  createdAt: 1,
                ),
              ],
              defaultSourceId: 1,
              onSubmit:
                  onSubmit ??
                  (VideoDiscoveryDownloadSelection selection) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('下载模式默认版本卡；单条组点卡直选；提交可用', (WidgetTester tester) async {
    await pumpSurface(tester);
    expect(
      find.byKey(const ValueKey<String>('video-resource-version-groups')),
      findsOneWidget,
      reason: '下载模式默认走版本卡视图',
    );
    final List<VideoResourceVersionGroup> groups =
        buildVideoResourceVersionGroups(_items());
    final VideoResourceVersionGroup movie = groups.firstWhere(
      (VideoResourceVersionGroup group) => group.releaseGroup == 'Erai-raws',
    );
    await tester.tap(
      find.byKey(ValueKey<String>('resource-version-${movie.key}')),
    );
    await tester.pumpAndSettle();
    final FilledButton submit = tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('video-resource-submit')),
    );
    expect(submit.onPressed, isNotNull, reason: '选中即可提交');
  });

  testWidgets('BUG-1986 版本卡元信息展示真实非连续集号段', (WidgetTester tester) async {
    await pumpSurface(
      tester,
      items: <VideoResourceCandidate>[
        for (final int episode in <int>[1, 2, 4, 16, 17])
          _FakeResource(
            remoteId: 'episode-$episode',
            title: '[Group] Show S02E$episode 1080p WEB H264',
            releaseGroup: 'Group',
            resolution: '1080p',
          ),
      ],
    );

    expect(find.textContaining('EP1–EP2, EP4, EP16–EP17'), findsOneWidget);
    expect(
      find.textContaining('(EP1–EP17)'),
      findsNothing,
      reason: '5 个离散集号不能显示成包含 17 集的连续范围',
    );
  });

  testWidgets('多条组点卡展开、点行选中', (WidgetTester tester) async {
    await pumpSurface(tester);
    final List<VideoResourceVersionGroup> groups =
        buildVideoResourceVersionGroups(_items());
    final VideoResourceVersionGroup sp = groups.firstWhere(
      (VideoResourceVersionGroup group) => group.releaseGroup == 'SubsPlease',
    );
    await tester.tap(
      find.byKey(ValueKey<String>('resource-version-${sp.key}')),
    );
    await tester.pumpAndSettle();
    final Finder row = find.byKey(
      ValueKey<String>('resource-release-${sp.members[1].identityKey}'),
    );
    expect(row, findsOneWidget, reason: '多条组点卡应展开而不是瞎选');
    await tester.tap(row);
    await tester.pumpAndSettle();
    final FilledButton submit = tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('video-resource-submit')),
    );
    expect(submit.onPressed, isNotNull, reason: '点行选中后提交可用');
  });

  testWidgets('「全部条目」开关切回平铺列表', (WidgetTester tester) async {
    await pumpSurface(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('video-resource-flat-toggle')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('video-resource-results')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-resource-version-groups')),
      findsNothing,
    );
  });

  testWidgets('下载运行时缺失只在提交时提示，资源页保持可用', (WidgetTester tester) async {
    await pumpSurface(
      tester,
      onSubmit: (VideoDiscoveryDownloadSelection selection) async {
        throw const VideoDownloadBackendUnavailable(
          videoDownloadEmbeddedBackendUnavailableMessage,
        );
      },
    );
    final VideoResourceVersionGroup movie =
        buildVideoResourceVersionGroups(_items()).firstWhere(
          (VideoResourceVersionGroup group) =>
              group.releaseGroup == 'Erai-raws',
        );
    await tester.tap(
      find.byKey(ValueKey<String>('resource-version-${movie.key}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('video-resource-submit')),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(videoDownloadEmbeddedBackendUnavailableMessage),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-resource-version-groups')),
      findsOneWidget,
      reason: '提交失败后仍应留在资源搜索页',
    );
    final FilledButton submit = tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('video-resource-submit')),
    );
    expect(submit.onPressed, isNotNull, reason: '提示后应允许用户重试');
  });
}

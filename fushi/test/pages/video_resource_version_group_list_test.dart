// B2 资源选版：版本卡列表 widget + 下载模式 surface 集成。
// 契约：① 下载模式默认版本卡视图；② 单条组点卡直接选中；③ 多条组点卡展开、
// 点行选中并使提交可用；④「全部条目」开关切回平铺列表。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';
import 'package:fushi/src/media/video/download/video_resource_version_groups.dart';
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
  ) async =>
      ProviderBatchResult<VideoResourceCandidate>.success(items);

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

  Future<void> pumpSurface(WidgetTester tester) async {
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
              registry: VideoResourceRegistry(
                <VideoResourceProvider>[_SeededProvider(_items())],
              ),
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
              onSubmit: (VideoDiscoveryDownloadSelection selection) async {},
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
}

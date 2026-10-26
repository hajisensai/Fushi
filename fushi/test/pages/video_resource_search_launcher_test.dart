// 旧「番剧下载」对话框删除后，合集详情页「去下载 / 补齐缺集 / 相关作品去下载」与
// 作品图谱灰卡「去搜」都改走视频资源搜索页（openVideoResourceSearch）。这些入口
// 有时只有标题、没有作品身份：页面进手动身份模式，标题预填进搜索框，且在用户补齐
// 身份前不发起搜索（不造假身份）。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';
import 'package:fushi/src/pages/implementations/video_resource_search_launcher.dart';
import 'package:fushi_core/fushi_core.dart' show MediaSourceRow;
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart'
    show TorrentAddPayload;
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';

class _CountingProvider implements VideoResourceProvider {
  int searches = 0;

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
  ) async {
    searches++;
    return ProviderBatchResult<VideoResourceCandidate>.success(
      const <VideoResourceCandidate>[],
    );
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      throw UnimplementedError();

  @override
  void close() {}
}

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

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('resourceSearchSeedQuery 只剥尾部年份括号（反馈 4Np5-EyJgE）', () {
    expect(resourceSearchSeedQuery('Title (2026)'), 'Title');
    expect(resourceSearchSeedQuery('Title（2026）'), 'Title');
    expect(resourceSearchSeedQuery('Title [1999]'), 'Title');
    expect(
      resourceSearchSeedQuery('Re:Zero (2016) Season 2'),
      'Re:Zero (2016) Season 2',
    );
    expect(resourceSearchSeedQuery('Title 2026'), 'Title 2026');
    expect(resourceSearchSeedQuery('(2026)'), '(2026)');
    expect(resourceSearchSeedQuery('  Title  '), 'Title');
  });

  testWidgets('只有标题的入口：搜索框预填标题，补齐身份前不搜', (WidgetTester tester) async {
    final _CountingProvider provider = _CountingProvider();
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: VideoDiscoveryResourceSearchPage(
            item: null,
            initialQuery: 'Ikoku Nikki',
            registry: VideoResourceRegistry(<VideoResourceProvider>[provider]),
            sources: const <MediaSourceRow>[_source],
            defaultSourceId: 1,
            onSubmit: (VideoDiscoveryDownloadSelection selection) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder query = find.descendant(
      of: find.byKey(const ValueKey<String>('video-resource-query')),
      matching: find.byType(EditableText),
    );
    expect(query, findsOneWidget);
    expect(tester.widget<EditableText>(query).controller.text, 'Ikoku Nikki');
    expect(provider.searches, 0, reason: '没有作品身份时不得自动发起搜索');
  });
}

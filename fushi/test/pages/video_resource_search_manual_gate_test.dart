// BUG-1539 守卫：下载「资源」tab 的手动搜索按钮在元数据身份（外部 ID/年份）
// 未填齐时按设计禁用，但必须给出可见的禁用原因（tooltip + 内联提示），
// 且身份填齐后按钮必须真正可点并触发搜索。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';

class _RecordingResourceProvider implements VideoResourceProvider {
  final List<VideoResourceSearchRequest> requests =
      <VideoResourceSearchRequest>[];

  @override
  String get id => 'torznab';

  @override
  Set<VideoDiscoveryCategory> get categories =>
      const <VideoDiscoveryCategory>{};

  @override
  int get priority => 10;

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    requests.add(request);
    return ProviderBatchResult<VideoResourceCandidate>.success(
      const <VideoResourceCandidate>[],
    );
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) =>
      throw UnimplementedError();

  @override
  void close() {}
}

Widget _surface(VideoResourceRegistry registry) => MaterialApp(
      home: Scaffold(
        body: VideoResourceSearchSurface(
          registry: registry,
          sources: const <MediaSourceRow>[],
          onSubmit: (VideoDiscoveryDownloadSelection selection) async {},
        ),
      ),
    );

Finder _searchButton() => find.widgetWithIcon(IconButton, Icons.search_rounded);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('BUG-1539 只填标题时按钮禁用且给出可见原因，不静默吞点击', (WidgetTester tester) async {
    final _RecordingResourceProvider provider = _RecordingResourceProvider();
    final VideoResourceRegistry registry =
        VideoResourceRegistry(<VideoResourceProvider>[provider]);
    await tester.pumpWidget(_surface(registry));

    await tester.enterText(
      find.byKey(const ValueKey<String>('video-resource-query')),
      'hibike!',
    );
    await tester.pump();

    final IconButton button = tester.widget<IconButton>(_searchButton());
    expect(button.onPressed, isNull, reason: '缺外部 ID/年份时必须禁用');
    expect(
      button.tooltip,
      t.video_discovery_manual_identity_hint,
      reason: '禁用时 tooltip 必须解释原因，不能继续写「搜索」',
    );
    expect(
      find.byKey(const ValueKey<String>('video-resource-identity-hint')),
      findsOneWidget,
      reason: '不悬停也要能看到禁用原因',
    );

    await tester.tap(_searchButton(), warnIfMissed: false);
    await tester.pump();
    expect(provider.requests, isEmpty);
  });

  testWidgets('BUG-1539 填齐标题+外部 ID+年份后按钮可点并真正触发搜索',
      (WidgetTester tester) async {
    final _RecordingResourceProvider provider = _RecordingResourceProvider();
    final VideoResourceRegistry registry =
        VideoResourceRegistry(<VideoResourceProvider>[provider]);
    await tester.pumpWidget(_surface(registry));

    await tester.enterText(
      find.byKey(const ValueKey<String>('video-resource-query')),
      'hibike!',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('video-resource-external-id')),
      '21085',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('video-resource-year')),
      '2016',
    );
    await tester.pump();

    final IconButton button = tester.widget<IconButton>(_searchButton());
    expect(button.onPressed, isNotNull);
    expect(button.tooltip, t.dialog_search);
    expect(
      find.byKey(const ValueKey<String>('video-resource-identity-hint')),
      findsNothing,
    );

    await tester.tap(_searchButton());
    await tester.pump();

    expect(provider.requests, hasLength(1));
    final VideoResourceSearchRequest request = provider.requests.single;
    expect(request.query, 'hibike!');
    expect(request.media?.providerId, 'anilist');
    expect(request.media?.anilistId, 21085);
    expect(request.media?.year, 2016);
  });
}

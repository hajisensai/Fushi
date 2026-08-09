import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/video/discovery/video_discovery_provider.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:hibiki/src/pages/implementations/video_discovery_detail_page.dart';

VideoDiscoveryItem _item(String id, String title) {
  return VideoDiscoveryItem(
    reference: VideoMediaReference(
      providerId: 'tmdb',
      mediaId: id,
      mediaKind: VideoMetadataMediaKind.tv,
      discoveryCategory: VideoDiscoveryCategory.tv,
      title: title,
      originalTitle: 'Original $title',
      year: 2026,
    ),
    overview: '这是一段在线作品简介。',
    score: 8.8,
    genres: const <String>['科幻', '冒险'],
  );
}

Widget _harness(VideoDiscoveryDetailPage page) {
  return TranslationProvider(
    child: MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: page,
    ),
  );
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('详情固定提供资源、字幕、订阅动作并呈现实时状态', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    bool searchedResource = false;
    bool searchedSubtitle = false;
    bool subscribed = false;
    bool played = false;
    int statusWatches = 0;
    final VideoDiscoveryItem item = _item('100', '星环纪元');
    final VideoDiscoveryActions actions = VideoDiscoveryActions(
      loadDetails: (_) async => VideoDiscoveryDetailData(
        item: item,
        facts: const <VideoDiscoveryFact>[
          VideoDiscoveryFact(label: '集数', value: '12'),
        ],
        people: const <VideoDiscoveryPerson>[
          VideoDiscoveryPerson(name: '演员甲', role: '主角'),
        ],
      ),
      watchStatus: (_) {
        statusWatches += 1;
        return Stream<VideoDiscoveryAcquisitionState>.value(
          const VideoDiscoveryAcquisitionState(
            statusLabel: '字幕处理中',
            isSubscribed: true,
            isInLibrary: true,
          ),
        );
      },
      onSearchResource: (_, __) async => searchedResource = true,
      onSearchSubtitle: (_, __) async => searchedSubtitle = true,
      onSubscribe: (_, __) async => subscribed = true,
      onPlay: (_, __) async => played = true,
    );

    await tester.pumpWidget(
      _harness(VideoDiscoveryDetailPage(item: item, actions: actions)),
    );
    await tester.pumpAndSettle();

    expect(find.text('星环纪元'), findsOneWidget);
    expect(find.text('这是一段在线作品简介。'), findsOneWidget);
    expect(find.text('演员甲'), findsOneWidget);
    expect(find.text('字幕处理中'), findsOneWidget);
    expect(statusWatches, 1);
    expect(find.text(t.video_discovery_subscription_manage), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('video-discovery-play')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('video-discovery-search-resource')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-discovery-search-subtitle')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-discovery-subscribe')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('video-discovery-play')),
    );
    await tester.pump();

    expect(searchedResource, isTrue);
    expect(searchedSubtitle, isTrue);
    expect(subscribed, isTrue);
    expect(played, isTrue);
  });

  testWidgets('详情加载失败可重试且不丢失 hero 摘要', (WidgetTester tester) async {
    int attempts = 0;
    final VideoDiscoveryItem item = _item('200', '重试作品');
    final VideoDiscoveryActions actions = VideoDiscoveryActions(
      loadDetails: (_) async {
        attempts += 1;
        if (attempts == 1) throw StateError('offline');
        return VideoDiscoveryDetailData(
          item: item,
          facts: const <VideoDiscoveryFact>[
            VideoDiscoveryFact(label: '状态', value: '更新中'),
          ],
        );
      },
    );

    await tester.pumpWidget(
      _harness(VideoDiscoveryDetailPage(item: item, actions: actions)),
    );
    await tester.pumpAndSettle();

    expect(find.text('重试作品'), findsOneWidget);
    expect(find.text(t.video_discovery_details_load_failed), findsOneWidget);
    await tester.tap(find.text(t.retry));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('更新中'), findsOneWidget);
    expect(find.text(t.video_discovery_details_load_failed), findsNothing);
  });

  testWidgets('活动下载只禁用新资源与订阅且仍可附加字幕', (WidgetTester tester) async {
    bool searchedSubtitle = false;
    final VideoDiscoveryItem item = _item('active', '下载中的作品');
    await tester.pumpWidget(
      _harness(
        VideoDiscoveryDetailPage(
          item: item,
          actions: VideoDiscoveryActions(
            watchStatus: (_) => Stream<VideoDiscoveryAcquisitionState>.value(
              const VideoDiscoveryAcquisitionState(
                statusLabel: '下载中',
                isBusy: true,
              ),
            ),
            onSearchResource: (_, __) async {},
            onSearchSubtitle: (_, __) async => searchedSubtitle = true,
            onSubscribe: (_, __) async {},
          ),
        ),
      ),
    );
    // busy 状态行含不定进度动画，固定推进帧而非等待永不 settle 的动画。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final OutlinedButton resource = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey<String>('video-discovery-search-resource')),
    );
    final OutlinedButton subtitle = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey<String>('video-discovery-search-subtitle')),
    );
    final FilledButton subscribe = tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('video-discovery-subscribe')),
    );
    expect(resource.onPressed, isNull);
    expect(subscribe.onPressed, isNull);
    expect(subtitle.onPressed, isNotNull);

    await tester.tap(
      find.byKey(const ValueKey<String>('video-discovery-search-subtitle')),
    );
    await tester.pump();
    expect(searchedSubtitle, isTrue);
  });

  testWidgets('紧凑详情中的三项动作与长标题不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final VideoDiscoveryItem item = _item(
      'compact',
      '这是一个用于验证紧凑窗口详情布局的超长在线作品标题',
    );

    await tester.pumpWidget(
      _harness(
        VideoDiscoveryDetailPage(
          item: item,
          actions: VideoDiscoveryActions(
            onSearchResource: (_, __) async {},
            onSearchSubtitle: (_, __) async {},
            onSubscribe: (_, __) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('video-discovery-search-resource')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-discovery-search-subtitle')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-discovery-subscribe')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

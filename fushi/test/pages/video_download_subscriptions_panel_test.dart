import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/video_download_subscriptions_panel.dart';

VideoDownloadSubscriptionRow _subscription({
  bool enabled = true,
  String? lastError = 'Indexer temporarily unavailable; token was redacted.',
}) =>
    VideoDownloadSubscriptionRow(
      subscriptionId: 'subscription-1',
      resourceProvider: 'nyaa:default',
      metadataProvider: 'anilist',
      externalId: '100',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      title: 'A deliberately long anime subscription title for narrow screens',
      year: 2026,
      season: 1,
      coverUrl: null,
      searchQuery: 'Example anime',
      filterJson: '{"strict":true,"releaseGroup":"Group",'
          '"resolution":"1080p","trusted":true}',
      mode: 'ongoing',
      startAfterEpisode: 3,
      backendKind: 'embedded',
      backendProfileId: null,
      fingerprint: 'embedded-test',
      category: 'fushi-video',
      targetSourceId: null,
      collectionId: null,
      organizationPolicy: 'library',
      subtitlePolicy: 'bestEffort',
      enabled: enabled,
      nextCheckAt: null,
      claimedBy: null,
      claimExpiresAt: null,
      retryCount: 0,
      lastCheckedAt: DateTime.utc(2026, 8, 9).millisecondsSinceEpoch,
      lastMatchedAt: null,
      fulfilledAt: null,
      lastError: lastError,
      createdAt: 1,
      updatedAt: 2,
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<VideoDownloadSubscriptionRow> subscriptions,
  required VideoDownloadSubscriptionToggle onToggle,
  required VideoDownloadSubscriptionAction onCheck,
  required VideoDownloadSubscriptionAction onDelete,
  Size size = const Size(360, 720),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: VideoDownloadSubscriptionsView(
            subscriptions: subscriptions,
            checkingAll: false,
            onCheckAll: () async {},
            onToggle: onToggle,
            onCheck: onCheck,
            onDelete: onDelete,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('strict filter summary is ordered and ignores unknown fields', () {
    expect(
      videoDownloadSubscriptionFilterSummary(
        '{"token":"secret","codec":"HEVC","resolution":"1080p",'
        '"releaseGroup":"Group","trusted":true}',
      ),
      <String>['Group', '1080p', 'HEVC', t.anime_download_trusted],
    );
    expect(videoDownloadSubscriptionFilterSummary('invalid'), isEmpty);
  });

  testWidgets('v78 subscription is manageable without narrow-screen overflow',
      (WidgetTester tester) async {
    final List<String> actions = <String>[];
    final VideoDownloadSubscriptionRow subscription = _subscription();
    await _pump(
      tester,
      subscriptions: <VideoDownloadSubscriptionRow>[subscription],
      onToggle: (
        VideoDownloadSubscriptionRow row,
        bool enabled,
      ) async =>
          actions.add('toggle:${row.subscriptionId}:$enabled'),
      onCheck: (VideoDownloadSubscriptionRow row) async =>
          actions.add('check:${row.subscriptionId}'),
      onDelete: (VideoDownloadSubscriptionRow row) async =>
          actions.add('delete:${row.subscriptionId}'),
    );

    expect(find.text('Group'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
    expect(find.text(t.anime_download_trusted), findsOneWidget);
    expect(
        find.textContaining('Indexer temporarily unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(
      find.byKey(
        const ValueKey<String>('video-subscription-check-subscription-1'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('video-subscription-toggle-subscription-1'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<String>('video-subscription-delete-subscription-1'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      actions,
      <String>[
        'check:subscription-1',
        'toggle:subscription-1:false',
        'delete:subscription-1',
      ],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty v78 subscription state is explicit',
      (WidgetTester tester) async {
    await _pump(
      tester,
      subscriptions: const <VideoDownloadSubscriptionRow>[],
      onToggle: (_, __) async {},
      onCheck: (_) async {},
      onDelete: (_) async {},
    );

    expect(find.text(t.download_subscription_empty_title), findsOneWidget);
    expect(find.text(t.download_subscription_empty_body), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide subscription header and cards fill the page width',
      (WidgetTester tester) async {
    await _pump(
      tester,
      size: const Size(1400, 800),
      subscriptions: <VideoDownloadSubscriptionRow>[_subscription()],
      onToggle: (_, __) async {},
      onCheck: (_) async {},
      onDelete: (_) async {},
    );

    expect(
      tester
          .getSize(
            find.byKey(
              const ValueKey<String>('video-subscriptions-header'),
            ),
          )
          .width,
      greaterThan(1300),
    );
    expect(
      tester
          .getSize(
            find.byKey(
              const ValueKey<String>(
                'video-subscription-card-subscription-1',
              ),
            ),
          )
          .width,
      greaterThan(1300),
    );
    expect(tester.takeException(), isNull);
  });

  // B3 订阅管理重做（2026-08-21）：搜索/排序、编辑入口、逐集视图、legacy 显式。
  test('B3：摘要函数支持 List 值（torznab 多值规则不再漏显）', () {
    expect(
      videoDownloadSubscriptionFilterSummary(
        '{"strict":true,"language":["Japanese","Chinese"],"codec":"HEVC"}',
      ),
      containsAll(<String>['Japanese', 'Chinese', 'HEVC']),
    );
  });

  test('B3：搜索与排序纯函数', () {
    VideoDownloadSubscriptionRow row(
      String id,
      String title, {
      int createdAt = 0,
      int? lastMatchedAt,
    }) =>
        VideoDownloadSubscriptionRow(
          subscriptionId: id,
          resourceProvider: 'nyaa:default',
          metadataProvider: 'anilist',
          externalId: id,
          mediaKind: 'tv',
          discoveryCategory: 'anime',
          title: title,
          year: null,
          season: null,
          coverUrl: null,
          searchQuery: 'query-$id',
          filterJson: '{}',
          mode: 'ongoing',
          startAfterEpisode: null,
          backendKind: 'embedded',
          backendProfileId: null,
          fingerprint: 'f',
          category: 'c',
          targetSourceId: null,
          collectionId: null,
          organizationPolicy: 'library',
          subtitlePolicy: 'none',
          enabled: true,
          nextCheckAt: null,
          claimedBy: null,
          claimExpiresAt: null,
          retryCount: 0,
          lastCheckedAt: null,
          lastMatchedAt: lastMatchedAt,
          fulfilledAt: null,
          lastError: null,
          createdAt: createdAt,
          updatedAt: 0,
        );

    final List<VideoDownloadSubscriptionRow> rows =
        <VideoDownloadSubscriptionRow>[
      row('a', 'Beta Show', createdAt: 10),
      row('b', 'Alpha Show', createdAt: 20, lastMatchedAt: 5),
    ];
    expect(
      filterVideoDownloadSubscriptions(
        <VideoDownloadSubscriptionRow>[row('c', 'Ｆａｔｅ Show')],
        'fate',
      ),
      hasLength(1),
      reason: '全角标题归一化后可被半角查询命中',
    );
    expect(
      filterVideoDownloadSubscriptions(rows, 'alpha').single.subscriptionId,
      'b',
    );
    expect(
      sortedVideoDownloadSubscriptions(
        rows,
        VideoDownloadSubscriptionSort.titleAsc,
      ).first.subscriptionId,
      'b',
    );
    expect(
      sortedVideoDownloadSubscriptions(
        rows,
        VideoDownloadSubscriptionSort.lastMatchedDesc,
      ).first.subscriptionId,
      'b',
      reason: '有命中时间的排在没有的前面',
    );
    expect(
      sortedVideoDownloadSubscriptions(
        rows,
        VideoDownloadSubscriptionSort.createdDesc,
      ).first.subscriptionId,
      'b',
    );
  });

  testWidgets('B3：编辑入口回调、逐集视图展开、legacy 行显式处理', (WidgetTester tester) async {
    final List<String> actions = <String>[];
    final VideoDownloadSubscriptionRow normal = _subscription();
    final VideoDownloadSubscriptionRow legacy = VideoDownloadSubscriptionRow(
      subscriptionId: 'legacy-1',
      resourceProvider: 'nyaa:default',
      metadataProvider: 'anilist',
      externalId: '200',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      title: 'Legacy imported show',
      year: null,
      season: null,
      coverUrl: null,
      searchQuery: 'legacy',
      filterJson: '{}',
      mode: 'ongoing',
      startAfterEpisode: null,
      backendKind: 'legacy',
      backendProfileId: null,
      fingerprint: 'legacy',
      category: 'c',
      targetSourceId: null,
      collectionId: null,
      organizationPolicy: 'legacy',
      subtitlePolicy: 'none',
      enabled: true,
      nextCheckAt: null,
      claimedBy: null,
      claimExpiresAt: null,
      retryCount: 0,
      lastCheckedAt: null,
      lastMatchedAt: null,
      fulfilledAt: null,
      lastError: 'Legacy organization subscriptions require ...',
      createdAt: 0,
      updatedAt: 0,
    );
    final VideoDownloadSubscriptionItemRow item =
        VideoDownloadSubscriptionItemRow(
      id: 1,
      subscriptionId: normal.subscriptionId,
      logicalItemKey: 'S01E05',
      resourceProvider: 'nyaa:default',
      selectedResourceId: 'r1',
      torrentHash: null,
      title: '[Group] Show - 05 (1080p)',
      season: 1,
      episode: 5,
      publishedAt: null,
      jobId: null,
      status: VideoDownloadSubscriptionItemStatus.processed,
      error: null,
      discoveredAt: 0,
      updatedAt: 0,
    );

    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: VideoDownloadSubscriptionsView(
              subscriptions: <VideoDownloadSubscriptionRow>[normal, legacy],
              checkingAll: false,
              onCheckAll: () async {},
              onToggle: (_, __) async {},
              onCheck: (_) async {},
              onDelete: (_) async {},
              onEdit: (VideoDownloadSubscriptionRow row) async =>
                  actions.add('edit:${row.subscriptionId}'),
              itemsWatcher: (String id) =>
                  Stream<List<VideoDownloadSubscriptionItemRow>>.value(
                id == normal.subscriptionId
                    ? <VideoDownloadSubscriptionItemRow>[item]
                    : const <VideoDownloadSubscriptionItemRow>[],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // legacy：徽章 + 提示语可见，编辑/立即检查入口都不给。
    expect(find.text(t.subscription_legacy_badge), findsOneWidget);
    expect(find.text(t.subscription_legacy_hint), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('video-subscription-edit-legacy-1')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('video-subscription-check-legacy-1')),
      findsNothing,
      reason: '新调度器对 legacy 恒报配置错误，检查按钮只会制造红字',
    );
    expect(
      find.textContaining('Legacy organization subscriptions'),
      findsNothing,
      reason: 'legacy 用提示语替代原始英文错误串',
    );

    // 编辑回调。
    await tester.tap(
      find.byKey(
        const ValueKey<String>('video-subscription-edit-subscription-1'),
      ),
    );
    await tester.pumpAndSettle();
    expect(actions, <String>['edit:subscription-1']);

    // 逐集视图展开。
    await tester.ensureVisible(
      find.byKey(
        const ValueKey<String>('video-subscription-expand-subscription-1'),
      ),
    );
    await tester.tap(
      find.byKey(
        const ValueKey<String>('video-subscription-expand-subscription-1'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('video-subscription-item-1')),
      findsOneWidget,
    );
    expect(find.textContaining('S01E05'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('B3：搜索框过滤订阅卡片', (WidgetTester tester) async {
    await _pump(
      tester,
      size: const Size(700, 900),
      subscriptions: <VideoDownloadSubscriptionRow>[_subscription()],
      onToggle: (_, __) async {},
      onCheck: (_) async {},
      onDelete: (_) async {},
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('video-subscription-search')),
      'zzz-no-match',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey<String>('video-subscription-card-subscription-1'),
      ),
      findsNothing,
    );
    expect(find.text(t.subscription_no_match), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

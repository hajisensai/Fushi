// BUG-2619 守卫：一条追更订阅查过却一条发布都没跟踪到时，空列表原先只说
// 「还没有跟踪到任何发布」——「番还没更新」和「规则结构上对不上」是两件完全
// 不同的事，用这一句话说它们，用户无从分辨。查过之后仍为空必须补一句可操作的
// 解释（完结作品 / 整包请改用一次性下载）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/video_download_subscriptions_panel.dart';

VideoDownloadSubscriptionRow _row({
  required String id,
  required String mode,
  int? lastCheckedAt,
  int? lastMatchedAt,
}) =>
    VideoDownloadSubscriptionRow(
      subscriptionId: id,
      resourceProvider: 'nyaa:default',
      metadataProvider: 'tmdb',
      externalId: '77777',
      mediaKind: 'tv',
      discoveryCategory: 'anime',
      title: 'Shoujo Kageki Revue Starlight',
      year: 2018,
      season: 1,
      coverUrl: null,
      searchQuery: 'Revue Starlight',
      filterJson: '{"strict":true,"releaseGroup":"VCB-Studio",'
          '"resolution":"1080p","trusted":true}',
      mode: mode,
      startAfterEpisode: 1,
      backendKind: 'embedded',
      backendProfileId: null,
      fingerprint: 'embedded-test',
      category: 'fushi-video',
      targetSourceId: null,
      collectionId: null,
      organizationPolicy: 'library',
      subtitlePolicy: 'bestEffort',
      enabled: true,
      nextCheckAt: null,
      claimedBy: null,
      claimExpiresAt: null,
      retryCount: 0,
      lastCheckedAt: lastCheckedAt,
      lastMatchedAt: lastMatchedAt,
      fulfilledAt: null,
      lastError: null,
      createdAt: 1,
      updatedAt: 2,
    );

Future<void> _pumpExpanded(
  WidgetTester tester,
  VideoDownloadSubscriptionRow row,
) async {
  tester.view.physicalSize = const Size(700, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: VideoDownloadSubscriptionsView(
            subscriptions: <VideoDownloadSubscriptionRow>[row],
            checkingAll: false,
            onCheckAll: () async {},
            onToggle: (_, __) async {},
            onCheck: (_) async {},
            onDelete: (_) async {},
            itemsWatcher: (String id) =>
                Stream<List<VideoDownloadSubscriptionItemRow>>.value(
              const <VideoDownloadSubscriptionItemRow>[],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(ValueKey<String>(
      'video-subscription-expand-${row.subscriptionId}',
    )),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  final Finder hint = find.byKey(
    const ValueKey<String>('video-subscription-never-matched-hint'),
  );

  testWidgets('追更订阅查过仍为空时解释为什么', (WidgetTester tester) async {
    await _pumpExpanded(
      tester,
      _row(id: 'dead', mode: 'ongoing', lastCheckedAt: 1000),
    );

    expect(find.text(t.subscription_items_empty), findsOneWidget);
    expect(hint, findsOneWidget);
    expect(
      find.text(t.subscription_items_empty_ongoing_hint),
      findsOneWidget,
    );
  });

  testWidgets('还没查过时不猜原因', (WidgetTester tester) async {
    await _pumpExpanded(tester, _row(id: 'fresh', mode: 'ongoing'));

    expect(find.text(t.subscription_items_empty), findsOneWidget);
    expect(hint, findsNothing, reason: '一次都没查过，没有任何证据说规则对不上');
  });

  testWidgets('匹配过的订阅不提示', (WidgetTester tester) async {
    await _pumpExpanded(
      tester,
      _row(
        id: 'alive',
        mode: 'ongoing',
        lastCheckedAt: 1000,
        lastMatchedAt: 900,
      ),
    );

    expect(hint, findsNothing);
  });

  testWidgets('一次性订阅不提示追更语义', (WidgetTester tester) async {
    await _pumpExpanded(
      tester,
      _row(id: 'oneshot', mode: 'oneShot', lastCheckedAt: 1000),
    );

    expect(hint, findsNothing, reason: '一次性订阅本来就不追更，这句解释不适用');
  });
}

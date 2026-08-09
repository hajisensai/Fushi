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
}

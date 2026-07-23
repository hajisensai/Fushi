import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/media/torrent/anime_download_subscription.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/download_subscriptions_panel.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/pages/implementations/downloads_page.dart';

import '../helpers/test_platform_services.dart';

class _MemorySubscriptionStore extends AnimeDownloadSubscriptionStore {
  _MemorySubscriptionStore()
      : super(baseDir: Directory('unused-subscription-store'));

  final Map<String, AnimeDownloadSubscription> values =
      <String, AnimeDownloadSubscription>{};

  @override
  Future<List<AnimeDownloadSubscription>> loadAll() async =>
      values.values.toList();

  @override
  Future<void> save(AnimeDownloadSubscription subscription) async {
    values[subscription.id] = subscription;
    revision.value++;
  }

  @override
  Future<void> delete(String id) async {
    values.remove(id);
    revision.value++;
  }
}

class _MemoryPlanStore extends AnimeDownloadPlanStore {
  _MemoryPlanStore() : super(baseDir: Directory('unused-plan-store'));

  @override
  Future<List<AnimeDownloadPlan>> loadAll() async =>
      const <AnimeDownloadPlan>[];
}

class _NoopBackend implements TorrentBackend {
  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async =>
      true;

  @override
  void close() {}

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async =>
      const <TorrentFileEntry>[];

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async =>
      const <TorrentSnapshot>[];

  @override
  Future<bool> prepareCategory(String category) async => true;

  @override
  Future<String?> probeConnection() async => 'noop';
}

class _FakeAppModel extends AppModel {
  _FakeAppModel(this.store, this.planStore, this.service)
      : super(testPlatformServices());

  final _MemorySubscriptionStore store;
  final _MemoryPlanStore planStore;
  final AnimeDownloadSubscriptionService service;

  @override
  AnimeDownloadSubscriptionStore? get animeDownloadSubscriptionStore => store;

  @override
  AnimeDownloadSubscriptionService? get animeDownloadSubscriptionService =>
      service;
  @override
  AnimeDownloadPlanStore? get animeDownloadPlanStore => planStore;

  @override
  String get jimakuApiKey => '';

  @override
  QbConnectionConfig? get qbConnectionConfig => const QbConnectionConfig();

  @override
  bool get torrentUploadIntroShown => true;
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Future<(_FakeAppModel, AnimeDownloadSubscriptionService)> pumpPanel(
    WidgetTester tester, {
    required Size size,
    bool withSubscription = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final _MemorySubscriptionStore store = _MemorySubscriptionStore();
    if (withSubscription) {
      final AnimeDownloadSubscription subscription =
          AnimeDownloadSubscription.fromSelection(
        anilistId: 42,
        seriesTitle: 'A Rather Long Example Anime Series Title',
        nyaaQuery: 'Example',
        category: '1_2',
        releaseGroup: 'A-Rather-Long-Release-Group',
        resolution: '1080p',
        startAfterEpisode: 12,
        now: DateTime.utc(2026, 7, 1),
      ).copyWith(
        processedEpisodes: <int>{13},
        lastCheckedAtMs: DateTime.utc(2026, 7, 23).millisecondsSinceEpoch,
      );
      store.values[subscription.id] = subscription;
    }
    final _MemoryPlanStore planStore = _MemoryPlanStore();
    final AnimeDownloadSubscriptionService service =
        AnimeDownloadSubscriptionService(
      store: store,
      planStore: planStore,
      configProvider: () => const QbConnectionConfig(),
      backendFactory: (_) => _NoopBackend(),
      search: (_) async => const [],
    );
    final _FakeAppModel appModel = _FakeAppModel(store, planStore, service);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: const MaterialApp(
            home: Scaffold(body: DownloadSubscriptionsPanel()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (appModel, service);
  }

  testWidgets('subscription card has no overflow on a narrow phone',
      (WidgetTester tester) async {
    final (_FakeAppModel appModel, AnimeDownloadSubscriptionService service) =
        await pumpPanel(
      tester,
      size: const Size(360, 720),
    );

    expect(
        find.text('A Rather Long Example Anime Series Title'), findsOneWidget);
    expect(find.textContaining('A-Rather-Long-Release-Group'), findsOneWidget);
    expect(tester.takeException(), isNull);

    service.checking.dispose();
    appModel.store.revision.dispose();
  });

  testWidgets('subscription panel remains bounded on desktop',
      (WidgetTester tester) async {
    final (_FakeAppModel appModel, AnimeDownloadSubscriptionService service) =
        await pumpPanel(
      tester,
      size: const Size(1200, 800),
    );

    final Finder card = find.byType(HibikiCard);
    expect(card, findsWidgets);
    expect(
      tester.getSize(card.last).width,
      lessThanOrEqualTo(760),
    );
    expect(tester.takeException(), isNull);

    service.checking.dispose();
    appModel.store.revision.dispose();
  });

  testWidgets('empty state explains how to create a subscription',
      (WidgetTester tester) async {
    final (_FakeAppModel appModel, AnimeDownloadSubscriptionService service) =
        await pumpPanel(
      tester,
      size: const Size(360, 720),
      withSubscription: false,
    );

    expect(find.text(t.download_subscription_empty_title), findsOneWidget);
    expect(find.text(t.download_subscription_empty_body), findsOneWidget);

    service.checking.dispose();
    appModel.store.revision.dispose();
  });

  testWidgets(
      'downloads page switches between discover, tasks and subscriptions',
      (WidgetTester tester) async {
    final _MemorySubscriptionStore store = _MemorySubscriptionStore();
    final _MemoryPlanStore planStore = _MemoryPlanStore();
    final AnimeDownloadSubscriptionService service =
        AnimeDownloadSubscriptionService(
      store: store,
      planStore: planStore,
      configProvider: () => const QbConnectionConfig(),
      backendFactory: (_) => _NoopBackend(),
      search: (_) async => const [],
    );
    final _FakeAppModel appModel = _FakeAppModel(store, planStore, service);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: const MaterialApp(home: DownloadsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.download_discover_tab), findsOneWidget);
    await tester.tap(find.text(t.download_tasks_tab));
    await tester.pumpAndSettle();
    expect(find.text(t.anime_download_no_tasks), findsOneWidget);

    await tester.tap(find.text(t.download_subscriptions_tab));
    await tester.pumpAndSettle();
    expect(find.text(t.download_subscription_empty_title), findsOneWidget);
    expect(tester.takeException(), isNull);

    service.checking.dispose();
    store.revision.dispose();
  });
}

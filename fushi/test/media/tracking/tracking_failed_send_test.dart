// A send that fails (T1 F3 item 1a): it is listed under "Needs attention" on
// the Tracking page with its error and a retry that works, and a send that
// keeps failing backs off instead of looping while it stays visible. Real
// tracking service, in-memory database, a stand-in site.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/page/tracking_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/tracking/tracking_provider.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

final class _Session implements TrackingProviderSession {
  @override
  void close() {}
}

/// A signed-in anime site whose sends fail while [error] is set.
final class _FlakySite implements TrackingProvider {
  Exception? error;
  int attempts = 0;
  final List<PendingTrackingUpdate> pushed = <PendingTrackingUpdate>[];

  @override
  String get id => 'flaky';

  @override
  String get displayName => 'Flaky site';

  @override
  String get siteHost => 'flaky.example';

  @override
  TrackingProviderCapabilities get capabilities =>
      const TrackingProviderCapabilities(
        kinds: <TrackingKind>{TrackingKind.anime},
        progressModes: <TrackingProgressMode>{TrackingProgressMode.episode},
      );

  @override
  bool get isConfigured => true;

  @override
  Future<TrackingProviderSession> openSession() async => _Session();

  @override
  Future<void> push(
    TrackingProviderSession session,
    PendingTrackingUpdate update,
  ) async {
    attempts++;
    final Exception? value = error;
    if (value != null) throw value;
    pushed.add(update);
  }

  @override
  TrackingFailureKind classify(Object error) => TrackingFailureKind.transient;
}

final class _FakeTimer implements Timer {
  _FakeTimer(this.delay, this.callback);

  final Duration delay;
  final void Function() callback;
  bool cancelled = false;

  /// Runs the callback once, as a real timer does when it is due.
  void fire() {
    cancelled = true;
    callback();
  }

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;
}

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late MediaTrackingRepository repository;
  late MediaTrackingService service;
  late _FlakySite site;
  late List<_FakeTimer> timers;

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<void> build() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    repository = MediaTrackingRepository(db);
    site = _FlakySite();
    timers = <_FakeTimer>[];
    service = MediaTrackingService(
      repository: repository,
      preferences: prefs,
      userAgent: 'test-agent',
      extraProviders: <TrackingProvider>[site],
      retryTimerFactory: (Duration delay, void Function() callback) {
        final _FakeTimer timer = _FakeTimer(delay, callback);
        timers.add(timer);
        return timer;
      },
    );
  }

  Future<void> tearDownAll() async {
    service.dispose();
    prefs.dispose();
    await db.close();
  }

  /// A linked episode that was watched: one row queued for the site.
  Future<void> watchLinkedEpisode() async {
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'v1',
        title: 'Frieren 01',
        videoPath: '/anime/v1.mkv',
      ),
    );
    await repository.saveMapping(
      mediaType: TrackingMediaType.video,
      mediaKey: 'v1',
      mediaTitle: 'Frieren 01',
      kind: TrackingKind.anime,
      subjectId: 101,
      subjectName: 'Sousou no Frieren',
      progressMode: TrackingProgressMode.episode,
      progressOffset: 1,
      provider: site.id,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.video,
      mediaKey: 'v1',
      localProgress: 0,
      completed: false,
      provider: site.id,
    );
  }

  Future<MediaTrackingProviderStatus> statusOfSite() async =>
      (await service.loadProviderStatuses()).firstWhere(
        (MediaTrackingProviderStatus s) => s.providerId == site.id,
      );

  group('service', () {
    setUp(build);
    tearDown(tearDownAll);

    test('a send that keeps failing backs off, never loops, and stays '
        'listed with its error', () async {
      await watchLinkedEpisode();
      site.error = Exception('HTTP 503 down');

      final List<int> delays = <int>[];
      for (int round = 1; round <= 4; round++) {
        final MediaTrackingSyncResult result = await service.syncNow();
        expect(result.failed, 1, reason: 'round $round');
        expect(site.attempts, round, reason: 'one request per round');

        final PendingTrackingUpdate row = (await repository.allPending(
          provider: site.id,
        )).single;
        expect(row.outbox.attemptCount, round);
        final MediaTrackingFailure failure =
            (await statusOfSite()).failures.single;
        expect(failure.error, contains('HTTP 503 down'));
        expect(failure.attemptCount, round);

        // One retry timer at a time, armed for the backoff, not sooner.
        expect(timers.where((_FakeTimer t) => t.isActive), hasLength(1));
        final _FakeTimer timer = timers.last;
        delays.add(timer.delay.inMilliseconds);

        // The timer firing before the row is due sends nothing.
        final int before = site.attempts;
        timer.fire();
        await service.syncNow();
        expect(site.attempts, before, reason: 'not due yet: no request');

        // Time passes: the row is due for the next round.
        await repository.retryAllNow(provider: site.id);
      }
      // 30 s, 1 min, 2 min, 4 min (minus the few ms the round took).
      const List<int> backoff = <int>[30000, 60000, 120000, 240000];
      for (int i = 0; i < backoff.length; i++) {
        expect(delays[i], inInclusiveRange(backoff[i] - 5000, backoff[i]));
      }
    });

    test('a forced sync (the page retry) sends at once, inside the '
        'backoff', () async {
      await watchLinkedEpisode();
      site.error = Exception('HTTP 503 down');
      await service.syncNow();
      expect(site.pushed, isEmpty);

      site.error = null;
      expect(
        (await service.syncNow()).succeeded,
        0,
        reason: 'still backed off',
      );
      final MediaTrackingSyncResult retried = await service.syncNow(
        force: true,
      );

      expect(retried.succeeded, 1);
      expect(site.pushed.single.outbox.progress, 1);
      expect(await repository.allPending(provider: site.id), isEmpty);
      expect((await statusOfSite()).failures, isEmpty);
    });
  });

  testWidgets('the page lists the failed send with its error; its retry '
      'sends it and the row goes away', (WidgetTester tester) async {
    await tester.runAsync(() async {
      await build();
      await watchLinkedEpisode();
      site.error = Exception('HTTP 503 down');
      await service.syncNow();
    });
    addTearDown(() async {
      await tester.runAsync(tearDownAll);
    });

    Future<void> settle({int rounds = 12}) async {
      for (int i = 0; i < rounds; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith(
            (Ref ref) => AppModel(testPlatformServices()),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: buildFushiThemeData(
              scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
              textTheme: Typography.material2021().black,
              designSystem: FushiDesignSystem.material,
              glass: FushiGlassMaterial.off,
              glassDesign: false,
            ),
            builder: (BuildContext context, Widget? child) =>
                FushiGlassScope(child: child!),
            home: TrackingPage(
              service: service,
              database: db,
              onOpenSettings: () {},
            ),
          ),
        ),
      ),
    );
    await settle();

    expect(tester.takeException(), isNull);
    expect(find.text('Frieren 01'), findsOneWidget);
    expect(find.textContaining('HTTP 503 down'), findsOneWidget);
    final Finder retry = find.byKey(
      const ValueKey<String>('tracking-attention-retry-0'),
    );
    expect(retry, findsOneWidget);

    site.error = null;
    await tester.tap(retry);
    await settle(rounds: 20);

    expect(site.pushed, hasLength(1));
    expect(find.textContaining('HTTP 503 down'), findsNothing);
    expect(retry, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

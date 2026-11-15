// A site that answers "unauthorized" (T1 F3 item 1b): the Tracking page
// header and its "Needs attention" list, and the Home strip, ask to sign in
// again; nothing is retried in a loop; the state stays until the site accepts
// again; signing in again sends what waited. Real tracking service, in-memory
// database, a stand-in site. (The plugin's settings row reading the same
// state is covered in plugin/tracking_plugins_section_test.dart.)
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
import 'package:fushi/src/pages/implementations/home_tracking_panel.dart';
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

final class _Rejected implements Exception {
  const _Rejected();

  @override
  String toString() => 'HTTP 401 token rejected';
}

/// A signed-in anime site that rejects its token while [rejecting].
final class _Site implements TrackingProvider {
  _Site(this.id);

  @override
  final String id;
  bool rejecting = false;
  int requests = 0;
  final List<PendingTrackingUpdate> pushed = <PendingTrackingUpdate>[];

  @override
  String get displayName => 'Site $id';

  @override
  String get siteHost => '$id.example';

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
    requests++;
    if (rejecting) throw const _Rejected();
    pushed.add(update);
  }

  @override
  TrackingFailureKind classify(Object error) => error is _Rejected
      ? TrackingFailureKind.unauthorized
      : TrackingFailureKind.transient;
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
  late _Site site;
  late _Site other;
  late List<_FakeTimer> timers;

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<void> build() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    repository = MediaTrackingRepository(db);
    site = _Site('a');
    other = _Site('b');
    timers = <_FakeTimer>[];
    service = MediaTrackingService(
      repository: repository,
      preferences: prefs,
      userAgent: 'test-agent',
      extraProviders: <TrackingProvider>[site, other],
      retryTimerFactory: (Duration delay, void Function() callback) {
        final _FakeTimer timer = _FakeTimer(delay, callback);
        timers.add(timer);
        return timer;
      },
    );
  }

  Future<void> close() async {
    service.dispose();
    prefs.dispose();
    await db.close();
  }

  /// A linked episode [uid] watched: one row queued for [provider].
  Future<void> watch(String uid, String provider, {int episode = 0}) async {
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: uid,
        title: 'Video $uid',
        videoPath: '/anime/$uid.mkv',
      ),
    );
    await repository.saveMapping(
      mediaType: TrackingMediaType.video,
      mediaKey: uid,
      mediaTitle: 'Video $uid',
      kind: TrackingKind.anime,
      subjectId: 101,
      subjectName: 'Remote $uid',
      progressMode: TrackingProgressMode.episode,
      progressOffset: 1,
      provider: provider,
    );
    await repository.enqueueProgress(
      mediaType: TrackingMediaType.video,
      mediaKey: uid,
      localProgress: episode,
      completed: false,
      provider: provider,
    );
  }

  Future<bool> signInNeeded(String id) async =>
      (await service.loadProviderStatuses())
          .firstWhere((MediaTrackingProviderStatus s) => s.providerId == id)
          .unauthorized;

  group('service', () {
    setUp(build);
    tearDown(close);

    test('a rejected token: sign-in needed, the Home strip asks to sign in '
        'again, retries back off', () async {
      site.rejecting = true;
      await watch('v1', site.id);

      final MediaTrackingSyncResult result = await service.syncNow();

      expect(result.byProvider[site.id]!.unauthorized, isTrue);
      expect(await signInNeeded(site.id), isTrue);
      expect(await signInNeeded(other.id), isFalse);
      final String strip = homeTrackingPanelText(
        HomeTrackingSummary.of(await service.loadHomeSnapshot()),
        DateTime(2026, 11, 11),
      );
      expect(strip, startsWith(t.home_tracking_panel_sign_in));

      // Not a loop: one request, then a retry armed for the backoff only.
      expect(site.requests, 1);
      expect(timers.single.delay, greaterThan(const Duration(seconds: 25)));
      timers.single.fire();
      await service.syncNow();
      expect(site.requests, 1, reason: 'not due: nothing sent again');
    });

    test('the state stays while nothing was sent to the site (another '
        'site syncing does not clear it)', () async {
      site.rejecting = true;
      await watch('v1', site.id);
      await service.syncNow();
      expect(await signInNeeded(site.id), isTrue);

      // Another site sends something; the rejected site's row is backed off,
      // so this round asks the rejected site nothing.
      await watch('v2', other.id);
      await service.syncNow();

      expect(other.pushed, hasLength(1));
      expect(site.requests, 1);
      expect(
        await signInNeeded(site.id),
        isTrue,
        reason: 'the site was not asked: it has not accepted the sign-in',
      );
    });

    test('signing in again sends what waited at once and clears the '
        'state', () async {
      site.rejecting = true;
      await watch('v1', site.id);
      await service.syncNow();
      // Several rejected rounds: the row is backed off for minutes.
      for (int i = 0; i < 3; i++) {
        await repository.retryAllNow(provider: site.id);
        await service.syncNow();
      }
      expect(site.requests, 4);

      site.rejecting = false;
      final MediaTrackingSyncResult resumed = await service.resumeAfterSignIn(
        site.id,
      );

      expect(resumed.byProvider[site.id]!.succeeded, 1);
      expect(site.pushed.single.outbox.progress, 1);
      expect(await repository.allPending(provider: site.id), isEmpty);
      expect(await signInNeeded(site.id), isFalse);
    });

    test('signing in again with nothing queued clears the state', () async {
      site.rejecting = true;
      await watch('v1', site.id);
      await service.syncNow();
      await repository.deleteMapping(
        (await repository.listMappings(provider: site.id)).single.id,
      );
      expect(await signInNeeded(site.id), isTrue);

      site.rejecting = false;
      await service.resumeAfterSignIn(site.id);

      expect(await signInNeeded(site.id), isFalse);
    });
  });

  testWidgets('the Tracking page shows sign-in needed in its header and '
      'under Needs attention', (WidgetTester tester) async {
    await tester.runAsync(() async {
      await build();
      site.rejecting = true;
      await watch('v1', site.id);
      await service.syncNow();
    });
    addTearDown(() async {
      await tester.runAsync(close);
    });
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
    for (int i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('tracking-page-site-a')),
        matching: find.text(
          t.media_tracking_page_site_sign_in_needed(site: 'Site a'),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.text(t.media_tracking_page_site_signed_in(site: 'Site b')),
      findsOneWidget,
    );
    expect(
      find.text(t.media_tracking_page_sign_in_row(site: 'Site a')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

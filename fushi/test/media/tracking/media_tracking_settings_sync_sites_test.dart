// T1 finding F5: Settings › Media tracking › Sync and the control channel's
// status reported the built-in Bangumi only ("Never synced", pending 0)
// while AniList / MangaBaka synced. Both now report every signed-in site.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/tracking/media_tracking_settings_body.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_settings_body_tracking.dart';
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

final class _Site implements TrackingProvider {
  @override
  String get id => 'anilist';

  @override
  String get displayName => 'AniList';

  @override
  String get siteHost => '';

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
  ) async {}

  @override
  TrackingFailureKind classify(Object error) => TrackingFailureKind.transient;
}

void main() {
  final int syncedAt = DateTime(2026, 11, 11, 12).millisecondsSinceEpoch;

  Future<
    ({
      FushiDatabase db,
      PreferencesRepository prefs,
      MediaTrackingService service,
    })
  >
  open() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    await prefs.setPref(
      TrackingProviderPrefKeys.forProvider('anilist').lastSyncAt,
      syncedAt,
    );
    final MediaTrackingService service = MediaTrackingService(
      repository: MediaTrackingRepository(db),
      preferences: prefs,
      userAgent: 'test-agent',
      builtInBangumi: false,
      extraProviders: <TrackingProvider>[_Site()],
    );
    return (db: db, prefs: prefs, service: service);
  }

  test('the control channel status lists every site and sums the signed-in '
      'ones', () async {
    final (:db, :prefs, :service) = await open();
    try {
      final Map<String, Object?> record = mediaTrackingStatusRecord(
        await service.loadStatus(),
        sites: await service.loadProviderStatuses(),
        siteName: (String id) => service.providers.byId(id)?.displayName ?? id,
      );
      expect(record['configured'], isTrue);
      expect(record['lastSyncAt'], syncedAt);
      final List<Object?> sites = record['sites']! as List<Object?>;
      final Map<String, Object?> aniList = sites
          .cast<Map<String, Object?>>()
          .singleWhere((Map<String, Object?> s) => s['id'] == 'anilist');
      expect(aniList['name'], 'AniList');
      expect(aniList['configured'], isTrue);
      expect(aniList['lastSyncAt'], syncedAt);
    } finally {
      service.dispose();
      prefs.dispose();
      await db.close();
    }
  });

  testWidgets('Settings › Sync shows the signed-in site, not "Never synced" '
      'for Bangumi', (WidgetTester tester) async {
    late final FushiDatabase db;
    late final PreferencesRepository prefs;
    late final MediaTrackingService service;
    late final AppModel appModel;
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'fushi_tracking_sync_sites_',
    );
    await tester.runAsync(() async {
      final ({
        FushiDatabase db,
        PreferencesRepository prefs,
        MediaTrackingService service,
      })
      opened = await open();
      db = opened.db;
      prefs = opened.prefs;
      service = opened.service;
      appModel = AppModel(testPlatformServices())
        ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tempDir)
        ..wireDatabaseForTesting(db)
        ..wireMediaTrackingServiceForTesting(service);
    });
    try {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: SingleChildScrollView(
              child: MediaTrackingSettingsBody(appModel: appModel),
            ),
          ),
        ),
      );
      for (int i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      final Finder row = find.byKey(
        const ValueKey<String>('media-tracking-sync-anilist'),
      );
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('AniList')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('media-tracking-sync-no-site')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      service.dispose();
      await tester.runAsync(() async {
        prefs.dispose();
        await db.close();
      });
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    }
  });
}

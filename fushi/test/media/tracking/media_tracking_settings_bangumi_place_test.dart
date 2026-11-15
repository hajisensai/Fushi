// Settings › Media tracking shows one place for Bangumi: the built-in token
// block where the built-in Dart provider serves the site, and nothing of it
// where the bundled Bangumi plugin serves it (its row in "Tracking plugins"
// is the place there). Spec `docs/specs/2026-11-11-bangumi-bundled-plugin.md`
// step 6.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/tracking/media_tracking_settings_body.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

void main() {
  const Key bangumiBlock = ValueKey<String>('media-tracking-bangumi-account');

  Future<void> pumpBody(
    WidgetTester tester, {
    required bool builtInBangumi,
    required void Function(Finder block) check,
  }) async {
    late final FushiDatabase db;
    late final PreferencesRepository prefs;
    late final MediaTrackingService service;
    late final AppModel appModel;
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'fushi_tracking_bangumi_place_',
    );
    await tester.runAsync(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      service = MediaTrackingService(
        repository: MediaTrackingRepository(db),
        preferences: prefs,
        userAgent: 'test-agent',
        builtInBangumi: builtInBangumi,
      );
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
      check(find.byKey(bangumiBlock));
      expect(
        find.byKey(const ValueKey<String>('bangumi-token-paste')),
        builtInBangumi ? findsOneWidget : findsNothing,
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
  }

  testWidgets('built-in Bangumi: the token block is shown', (
    WidgetTester tester,
  ) async {
    await pumpBody(
      tester,
      builtInBangumi: true,
      check: (Finder block) => expect(block, findsOneWidget),
    );
  });

  testWidgets('bundled plugin serves Bangumi: no token block', (
    WidgetTester tester,
  ) async {
    await pumpBody(
      tester,
      builtInBangumi: false,
      check: (Finder block) => expect(block, findsNothing),
    );
  });
}

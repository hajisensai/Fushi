// Settings › Media tracking on desktop, laid out like the settings page shell
// (one page scroll controller that is also the PrimaryScrollController
// inherited on every platform, `settings_kit_core.dart`). A scroll view in the
// body without its own controller would attach to the page controller and
// the desktop Scrollbar would assert "attached to more than one
// ScrollPosition" (seen in a user test session, 2026-11-10).
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
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
  testWidgets('desktop: no scroll controller of the Media tracking body is '
      'shared by two scroll views', (WidgetTester tester) async {
    late final FushiDatabase db;
    late final PreferencesRepository prefs;
    late final MediaTrackingService service;
    late final AppModel appModel;
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'fushi_tracking_scrollbar_',
    );
    await tester.runAsync(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      await prefs.setPref(kBangumiAccessTokenPref, 'token');
      service = MediaTrackingService(
        repository: MediaTrackingRepository(db),
        preferences: prefs,
        userAgent: 'test-agent',
      );
      appModel = AppModel(testPlatformServices())
        ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tempDir)
        ..wireDatabaseForTesting(db)
        ..wireMediaTrackingServiceForTesting(service);
    });

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      tester.view.physicalSize = const Size(900, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ScrollController page = ScrollController();
      addTearDown(page.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: PrimaryScrollController(
              controller: page,
              automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
              child: SingleChildScrollView(
                controller: page,
                child: MediaTrackingSettingsBody(appModel: appModel),
              ),
            ),
          ),
        ),
      );
      for (int i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }

      final List<String> shared = <String>[
        for (final ScrollableState state in tester.stateList<ScrollableState>(
          find.byType(Scrollable),
        ))
          if ((state.widget.controller?.positions.length ?? 1) > 1)
            '${state.widget.axisDirection} ${state.context.widget}',
      ];
      expect(shared, isEmpty);
      await tester.drag(
        find.byType(MediaTrackingSettingsBody),
        const Offset(0, -300),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
      service.dispose();
      await tester.runAsync(() async {
        prefs.dispose();
        await db.close();
      });
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    }
  });
}

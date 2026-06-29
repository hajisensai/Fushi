import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

/// TODO-973 guard: AppModel is the single source of truth for gamepad
/// auto-immersive. A controller rising/falling edge (driven through the real
/// [GamepadService] presence inference) flips [AppModel.gamepadImmersiveActive]
/// — but ONLY when the user opted into the preference (Never break userspace for
/// opted-out users).
HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_path_provider_gpi');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  late HibikiDatabase db;
  late PreferencesRepository prefs;
  late Directory storeDir;
  late AppModel appModel;

  setUp(() async {
    db = _testDb();
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_app_model_gpi');
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    appModel.gamepadService.dispose();
    prefs.dispose();
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  test('default: gamepadImmersiveActive starts false', () {
    expect(appModel.gamepadImmersiveActive.value, isFalse);
  });

  test(
      'opted in: controller rising edge sets active=true, idle falling edge '
      'clears it', () async {
    await appModel.setGamepadAutoImmersive(true);

    fakeAsync((FakeAsync async) {
      // Rising edge: a real controller event (via the service activity hook)
      // flips the single source of truth on.
      appModel.gamepadService.debugMarkGamepadActivity();
      expect(appModel.gamepadImmersiveActive.value, isTrue,
          reason: 'controller present + opted in -> immersive active');

      // Falling edge: idle past the presence timeout clears it.
      async.elapse(
          GamepadService.debugPresenceIdleTimeout + const Duration(seconds: 1));
      expect(appModel.gamepadImmersiveActive.value, isFalse,
          reason: 'controller gone -> immersive cleared');
    });
  });

  test('opted OUT: controller activity never sets active (userspace unchanged)',
      () async {
    // Default preference is false; do not opt in.
    expect(appModel.gamepadAutoImmersive, isFalse);

    appModel.gamepadService.debugMarkGamepadActivity();
    expect(appModel.gamepadImmersiveActive.value, isFalse,
        reason: 'opted out: a controller must not drive immersive state');
  });

  test('toggling the preference off MID-presence clears active immediately',
      () async {
    await appModel.setGamepadAutoImmersive(true);
    appModel.gamepadService.debugMarkGamepadActivity();
    expect(appModel.gamepadImmersiveActive.value, isTrue);

    // User opts out while a controller is still active. The preference setter
    // re-derives immersive state from current presence — the bars must come back
    // immediately, not wait for the controller to go idle.
    await appModel.setGamepadAutoImmersive(false);
    expect(appModel.gamepadImmersiveActive.value, isFalse,
        reason: 'opting out mid-presence re-gates immersive to false at once');
  });

  test('toggling the preference ON MID-presence sets active immediately',
      () async {
    // Controller is active first, before opting in.
    appModel.gamepadService.debugMarkGamepadActivity();
    expect(appModel.gamepadImmersiveActive.value, isFalse,
        reason: 'opted out: presence alone does not drive immersive');

    await appModel.setGamepadAutoImmersive(true);
    expect(appModel.gamepadImmersiveActive.value, isTrue,
        reason: 'opting in while a controller is present activates immersive');
  });
}

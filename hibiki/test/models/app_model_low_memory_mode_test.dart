import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

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
        Directory.systemTemp.createTempSync('hibiki_path_provider_lmm');
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

  late int prevMaxSize;
  late int prevMaxSizeBytes;

  late HibikiDatabase db;
  late PreferencesRepository prefs;
  late Directory storeDir;
  late AppModel appModel;

  setUp(() async {
    final ImageCache cache = PaintingBinding.instance.imageCache;
    prevMaxSize = cache.maximumSize;
    prevMaxSizeBytes = cache.maximumSizeBytes;

    db = _testDb();
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_app_model_lmm');
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    final ImageCache cache = PaintingBinding.instance.imageCache;
    cache.maximumSize = prevMaxSize;
    cache.maximumSizeBytes = prevMaxSizeBytes;
    prefs.dispose();
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  test(
      'setLowMemoryMode(true) shrinks dictionary history cap and image cache budget',
      () async {
    final ImageCache cache = PaintingBinding.instance.imageCache;

    await appModel.setLowMemoryMode(true);

    expect(appModel.lowMemoryMode, isTrue);
    expect(appModel.maximumDictionaryHistoryItems, 5);
    expect(cache.maximumSize, 50);
    expect(cache.maximumSizeBytes, 20 << 20);
  });

  test(
      'setLowMemoryMode(false) restores normal dictionary history cap and image cache budget',
      () async {
    final ImageCache cache = PaintingBinding.instance.imageCache;

    await appModel.setLowMemoryMode(true);
    await appModel.setLowMemoryMode(false);

    expect(appModel.lowMemoryMode, isFalse);
    expect(appModel.maximumDictionaryHistoryItems, 10);
    expect(cache.maximumSize, 1000);
    expect(cache.maximumSizeBytes, 100 << 20);
  });

  test('low memory mode persists to the database under low_memory_mode key',
      () async {
    await appModel.setLowMemoryMode(true);

    final PreferencesRepository reloaded = PreferencesRepository(db);
    await reloaded.loadFromDb();
    expect(reloaded.lowMemoryMode, isTrue);
    reloaded.dispose();
  });
}

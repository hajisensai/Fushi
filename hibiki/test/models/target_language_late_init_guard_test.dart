import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/models/app_model.dart';

import '../helpers/test_platform_services.dart';

/// Regression guard for TODO-109 / BUG-194.
///
/// `LateInitializationError: Field 'languages' has not been initialized.`
///
/// `AppModel.languages` is a `late` map only assigned inside
/// [AppModel.populateLanguages], which runs partway through
/// [AppModel.initialise] (after the DB open / backup / sync / repository
/// awaits). Any widget that rebuilds during that early init window and reads
/// [AppModel.targetLanguage] used to crash, because the old getter was
/// `languages.values.first` and `languages` was still uninitialised.
///
/// The fix makes [AppModel.targetLanguage] return [JapaneseLanguage.instance]
/// directly — the sole language [populateLanguages] ever registers — so the
/// getter no longer depends on the `late` field's init timing.
///
/// These tests construct a fresh [AppModel] WITHOUT calling [initialise], which
/// reproduces the exact pre-`populateLanguages` state. Reverting the getter to
/// `languages.values.first` turns the first test red with a
/// `LateInitializationError`.
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_target_lang_late_init');
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

  test(
    'targetLanguage does not depend on late languages map (no init run)',
    () {
      // No initialise(), no populateLanguages() — `languages` is uninitialised,
      // exactly the early-init window where the crash happened.
      final AppModel appModel = AppModel(testPlatformServices());

      // Must NOT throw LateInitializationError.
      expect(() => appModel.targetLanguage, returnsNormally);

      // And it must resolve to the one registered language: Japanese.
      expect(appModel.targetLanguage, isA<JapaneseLanguage>());
      expect(
        identical(appModel.targetLanguage, JapaneseLanguage.instance),
        isTrue,
      );
    },
  );

  test(
    'targetLanguage value is identical before and after populateLanguages',
    () {
      final AppModel appModel = AppModel(testPlatformServices());

      // Early-init value (languages still uninitialised).
      final Language earlyValue = appModel.targetLanguage;

      // Simulate the point in initialise() where the language map is built.
      appModel.populateLanguages();

      // Post-populate value must be the SAME instance — no behavioural change
      // for the normal running path (furigana / lookup / fonts still get the
      // Japanese language they always got), and it matches what the old getter
      // (`languages.values.first`) would have returned once initialised.
      final Language lateValue = appModel.targetLanguage;

      expect(identical(earlyValue, lateValue), isTrue);
      expect(identical(lateValue, appModel.languages.values.first), isTrue);
    },
  );

  test('refreshSystemPalette is safe before themeNotifier initialises',
      () async {
    final AppModel appModel = AppModel(testPlatformServices());

    await expectLater(
      Future<void>.sync(appModel.refreshSystemPalette),
      completes,
    );
  });
}

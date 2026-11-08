import 'dart:io';

import 'package:test/test.dart';

/// The `:popup` / second-screen panel processes initialise through
/// `AppModel.initialiseForDictionaryPopup`, not the main `initialise`. The
/// default app theme (`system-theme`) is built from the Android wallpaper
/// palette, so that path must load the palette too; otherwise the panel falls
/// back to the seed colour and its colours do not match the main screen (seen
/// on a dual-screen device: green top, blue bottom).
///
/// AppModel's init chain needs real FFI engines and the file system, so the
/// strongest feasible guard is a source scan (same approach as
/// `dictionary_cache_byte_cap_test.dart`).
void main() {
  test('initialiseForDictionaryPopup loads the system palette after the '
      'theme notifier exists', () {
    final File file = File('lib/src/models/app_model.dart');
    expect(file.existsSync(), isTrue, reason: file.absolute.path);
    final String source = file.readAsStringSync();

    final int start = source.indexOf(
      'Future<void> initialiseForDictionaryPopup() async {',
    );
    expect(start, isNonNegative, reason: 'initialiseForDictionaryPopup gone');
    final int end = source.indexOf('\n  Future<', start + 1);
    expect(end, greaterThan(start));
    final String body = source.substring(start, end);

    final int notifier = body.indexOf('themeNotifier = ThemeNotifier(');
    final int palette = body.indexOf('await refreshSystemPalette();');
    expect(notifier, isNonNegative, reason: 'theme notifier not built here');
    expect(
      palette,
      greaterThan(notifier),
      reason:
          'the panel / popup process must load the wallpaper palette after '
          'building its ThemeNotifier (refreshSystemPalette is a no-op '
          'before that)',
    );
  });

  test('the panel / popup engine registers the dynamic_color plugin', () {
    // Both secondary engines (SecondScreenActivity, the :popup engine) use
    // this hand-written registrant instead of GeneratedPluginRegistrant.
    // Without dynamic_color, getCorePalette throws MissingPluginException,
    // which refreshSystemPalette turns into "no palette" (seed colour).
    final File registrant = File(
      'android/app/src/main/java/app/fushi/reader/'
      'FloatingDictPluginRegistrant.java',
    );
    expect(registrant.existsSync(), isTrue, reason: registrant.absolute.path);
    expect(
      registrant.readAsStringSync().replaceAll(RegExp(r'\s+'), ' '),
      contains(
        'getPlugins().add( new '
        'io.material.plugins.dynamic_color.DynamicColorPlugin())',
      ),
    );
  });
}

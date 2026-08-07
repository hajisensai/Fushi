import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-438 / TODO-889 source-scan guard: every Flutter-host Activity in the
/// Android manifest must list `navigation` in `android:configChanges`.
///
/// Root cause: a gamepad is a *navigation* input device. Plugging or
/// unplugging it raises `CONFIG_NAVIGATION`. If `navigation` is NOT declared
/// in `configChanges`, Android tears down and recreates the Activity instead
/// of calling `onConfigurationChanged`. During that recreate the Samsung
/// system focus rectangle re-appears over Hibiki's own focus ring and the
/// WebView/Flutter UI shows a load spinner (the "book stuck loading after
/// connecting a gamepad" symptom). `keyboard`/`keyboardHidden` alone do not
/// cover gamepad (navigation) plug/unplug.
///
/// A real device's recreate-vs-keep-alive decision happens in the Android
/// framework (can't run here), so this guards the *manifest contract*: if any
/// Activity's `configChanges` drops `navigation`, the gamepad-reconnect path
/// silently regresses and this test goes red.
void main() {
  // Tests run with CWD = `hibiki/`.
  final File manifestFile = File('android/app/src/main/AndroidManifest.xml');

  test('every <activity> android:configChanges includes navigation', () {
    expect(manifestFile.existsSync(), isTrue,
        reason: 'BUG-438/TODO-889 fix lives in this manifest');
    final String manifest = manifestFile.readAsStringSync();

    final RegExp configChangesAttr = RegExp(r'android:configChanges="([^"]*)"');
    final Iterable<RegExpMatch> matches =
        configChangesAttr.allMatches(manifest);

    expect(matches, isNotEmpty,
        reason: 'manifest must declare configChanges on its Flutter-host '
            'activities');

    for (final RegExpMatch m in matches) {
      final String value = m.group(1)!;
      final List<String> flags = value.split('|');
      expect(
        flags.contains('navigation'),
        isTrue,
        reason: 'BUG-438/TODO-889: configChanges "$value" is missing '
            '"navigation"; a gamepad (navigation input) plug/unplug would '
            'recreate this Activity instead of firing onConfigurationChanged, '
            're-exposing the system focus frame and a load spinner',
      );
    }
  });
}

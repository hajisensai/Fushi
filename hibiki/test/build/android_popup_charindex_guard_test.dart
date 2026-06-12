import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guards for BUG-212: the Android floating lyric/subtitle strip
/// lookup regressed in 0.5.0 (commit 0248a0260, "rewrite PopupDict from Java to
/// Kotlin"). The Kotlin rewrite migrated the system PROCESS_TEXT entry points to
/// the keyboard-free Flutter popup (PopupDictFlutterActivity) but left
/// FloatingLyricService pointing at the deactivated native WebView Activity,
/// which (a) opens an EditText search box pre-filled with the whole sentence →
/// pops the soft keyboard, and (b) never reads the tapped charIndex → searches
/// from the sentence head only.
///
/// These guards assert the tapped charIndex now flows end-to-end:
///   FloatingLyricService → PopupDictFlutterActivity → PopupEngineHolder →
///   Dart PopupChannel → _extractWord/wordFromIndex.
///
/// Native Kotlin/Java behaviour cannot run on the Dart host, so we pin the wire
/// contract at the source level. The Dart segmentation half is covered by a
/// real behaviour test in
/// test/pages/popup_floating_lyric_charindex_test.dart.
void main() {
  const String androidRoot =
      '../hibiki/android/app/src/main/java/app/hibiki/reader';

  String read(String relative) =>
      File('$androidRoot/$relative').readAsStringSync();

  group('BUG-212 floating lyric lookup charIndex wiring', () {
    test(
      'FloatingLyricService routes the tap into the Flutter popup, not the '
      'deactivated native PopupDictActivity, and ships the tapped charIndex',
      () {
        final String service = read('FloatingLyricService.java');

        final int startIndex = service.indexOf('private void handleTap');
        expect(startIndex, isNonNegative,
            reason: 'handleTap is the strip tap handler');
        // Inspect only the handleTap body so unrelated comments elsewhere do
        // not satisfy the assertions.
        final int endIndex = service.indexOf('private int getCharIndexAt');
        expect(endIndex, greaterThan(startIndex));
        final String handleTap = service.substring(startIndex, endIndex);

        expect(
          handleTap,
          contains('new Intent(this, PopupDictFlutterActivity.class)'),
          reason: 'must launch the keyboard-free Flutter popup',
        );
        expect(
          handleTap.contains('new Intent(this, PopupDictActivity.class)'),
          isFalse,
          reason: 'the native WebView popup forces a search keyboard and '
              'ignores charIndex — it must not be the tap target',
        );
        expect(
          handleTap,
          contains(
              'putExtra(PopupDictFlutterActivity.EXTRA_CHAR_INDEX, index)'),
          reason: 'the tapped glyph index must travel with the intent',
        );
      },
    );

    test(
      'PopupDictFlutterActivity reads charIndex from the intent and forwards it '
      'to PopupEngineHolder on both cold start and warm reuse',
      () {
        final String activity = read('PopupDictFlutterActivity.kt');

        expect(activity, contains('const val EXTRA_CHAR_INDEX'));
        expect(
          activity,
          contains('intent?.getIntExtra(EXTRA_CHAR_INDEX, -1)'),
          reason: 'charIndex must be parsed from the intent (default -1 for '
              'whole-sentence system lookups)',
        );
        expect(
          activity,
          contains('PopupEngineHolder.setPendingText(text, charIndex)'),
          reason: 'cold-start path must forward the real charIndex',
        );
        expect(
          activity,
          contains('PopupEngineHolder.pushProcessText(text, charIndex)'),
          reason: 'warm-reuse path must forward the real charIndex',
        );
      },
    );

    test(
      'PopupEngineHolder forwards the real charIndex to Dart instead of the '
      'hardcoded -1 it carried before BUG-212',
      () {
        final String holder = read('PopupEngineHolder.kt');

        expect(holder, contains('private var pendingCharIndex: Int = -1'));
        expect(
          holder,
          contains('fun setPendingText(text: String, charIndex: Int = -1)'),
        );
        expect(
          holder,
          contains('fun pushProcessText(text: String, charIndex: Int = -1)'),
        );
        expect(
          holder,
          contains('map["charIndex"] = pendingCharIndex'),
          reason: 'getInitialProcessText (cold start poll) must return the '
              'real pending charIndex',
        );
        expect(
          holder,
          contains('args["charIndex"] = charIndex'),
          reason: 'onNewProcessText (warm reuse) must push the real charIndex',
        );
        expect(
          holder.contains('map["charIndex"] = -1') ||
              holder.contains('args["charIndex"] = -1'),
          isFalse,
          reason: 'charIndex must never be hardcoded to -1 in the wire payload',
        );
      },
    );
  });
}

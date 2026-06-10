import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guards for the desktop floating-lyric strip. The native window
/// and the `Platform.is*` gate cannot be exercised on the host, so these guards
/// pin the load-bearing wiring that a refactor could silently break.
void main() {
  group('desktop floating lyric guards', () {
    test('channel isSupported includes Windows alongside Android', () {
      final File file = File(
        'lib/src/media/audiobook/floating_lyric_channel.dart',
      );
      final String src = file.readAsStringSync();
      // The strip is the Windows counterpart of the Android overlay, so both
      // platforms must pass the gate; macOS/Linux must stay excluded.
      expect(
        src.contains('Platform.isAndroid || Platform.isWindows'),
        isTrue,
        reason: 'isSupported must allow Android and Windows.',
      );
      expect(src.contains('Platform.isMacOS'), isFalse);
      expect(src.contains('Platform.isLinux'), isFalse);
    });

    test('reader wires the lookup handler so taps reach the dictionary', () {
      final File file = File(
        'lib/src/pages/implementations/reader_hibiki_page.dart',
      );
      final String src = file.readAsStringSync();
      // Before this feature onLookupText was never passed; the desktop strip
      // relies on it to route a tapped word into the in-app popup.
      expect(
        src.contains('onLookupText: _lookupFromFloatingLyric'),
        isTrue,
        reason: 'Floating-lyric taps must be wired to the lookup handler.',
      );
      expect(src.contains('_lookupFromFloatingLyric(String text, int index)'),
          isTrue);
      // The lookup must reuse the existing segmenter + popup path.
      expect(src.contains('wordFromIndex('), isTrue);
      expect(src.contains('searchDictionaryResult('), isTrue);
    });

    test('desktop failure shows the generic hint, not a false permission hint',
        () {
      final File file = File(
        'lib/src/pages/implementations/reader_hibiki_page.dart',
      );
      final String src = file.readAsStringSync();
      // Android failure = overlay permission; desktop failure = window
      // creation. Both branches must exist so desktop never shows the
      // misleading overlay-permission message.
      expect(src.contains('Platform.isAndroid'), isTrue);
      expect(src.contains('floating_lyric_permission_hint'), isTrue);
      expect(src.contains('floating_lyric_unavailable_hint'), isTrue);
    });
  });
}

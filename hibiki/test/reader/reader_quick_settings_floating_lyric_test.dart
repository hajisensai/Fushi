import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

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
      final String reader = readReaderPageSource();
      final String session = File(
        'lib/src/media/audiobook/audiobook_session.dart',
      ).readAsStringSync();
      // TODO-291 阶段2: the desktop strip handlers now live on AudiobookSession;
      // the reader installs its popup-lookup handler into the session while
      // attached (session.installReaderSurfaces(onFloatingLyricLookup: ...)).
      expect(
        reader.contains('onFloatingLyricLookup: _lookupFromFloatingLyric'),
        isTrue,
        reason: 'Reader must install its lookup handler into the session.',
      );
      expect(session.contains('onLookupText: _onFloatingLyricLookup'), isTrue,
          reason:
              'Session wires the strip lookup tap to the installed handler.');
      expect(
          reader.contains('_lookupFromFloatingLyric(String text, int index)'),
          isTrue);
      // The lookup must reuse the existing segmenter + popup path.
      expect(reader.contains('wordFromIndex('), isTrue);
      expect(reader.contains('searchDictionaryResult('), isTrue);
    });

    test('desktop failure shows the generic hint, not a false permission hint',
        () {
      final String src = readReaderPageSource();
      // Android failure = overlay permission; desktop failure = window
      // creation. Both branches must exist so desktop never shows the
      // misleading overlay-permission message.
      expect(src.contains('Platform.isAndroid'), isTrue);
      expect(src.contains('floating_lyric_permission_hint'), isTrue);
      expect(src.contains('floating_lyric_unavailable_hint'), isTrue);
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guard locking the two hand-copied sanitize implementations together.
///
/// hibiki_core cannot import the app package (reverse dependency), so it keeps
/// a private copy of `sanitizeTtuFilename` in `lib/src/utils/ttu_sanitize.dart`
/// (the v16 book-key migration's `_sanitizeBookKey` now delegates to it). The
/// app truth source lives in `fushi/lib/src/sync/ttu_filename.dart`. If either
/// body is edited without the other, cross-device book identity silently
/// diverges — the same title would map to different keys on different code
/// paths.
///
/// This guard reads both source files as text and asserts the transformation
/// bodies are character-identical (after stripping per-line indentation), so any
/// drift fails CI instead of corrupting identity at runtime.
void main() {
  test('core sanitizeTtuFilename body matches app copy verbatim', () {
    final String coreBody = _extractSanitizeBody(
      File('lib/src/utils/ttu_sanitize.dart').readAsStringSync(),
    );
    final String appBody = _extractSanitizeBody(
      File('../../fushi/lib/src/sync/ttu_filename.dart').readAsStringSync(),
    );

    expect(coreBody, isNotEmpty,
        reason:
            'failed to locate sanitizeTtuFilename body in ttu_sanitize.dart');
    expect(appBody, isNotEmpty,
        reason:
            'failed to locate sanitizeTtuFilename body in ttu_filename.dart');
    expect(coreBody, appBody,
        reason: 'sanitize bodies diverged — re-sync core ttu_sanitize.dart '
            'sanitizeTtuFilename with app ttu_filename.dart sanitizeTtuFilename');
  });
}

/// Extracts the sanitize transformation body — the lines from `String result =
/// title;` through the first following `return result;` — with each line's
/// leading/trailing whitespace stripped, so the two functions' different
/// indentation (top-level fn vs class method) and signatures don't matter.
String _extractSanitizeBody(String source) {
  final List<String> lines = source.split('\n');
  final int start =
      lines.indexWhere((String l) => l.trim() == 'String result = title;');
  if (start < 0) return '';
  final int end =
      lines.indexWhere((String l) => l.trim() == 'return result;', start);
  if (end < 0) return '';
  return lines.sublist(start, end + 1).map((String l) => l.trim()).join('\n');
}

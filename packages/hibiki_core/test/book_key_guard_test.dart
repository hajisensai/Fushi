import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guard locking the two hand-copied sanitize implementations together.
///
/// `_sanitizeBookKey` in `database.dart` (used by the v16 book-key migration)
/// is a VERBATIM copy of `sanitizeTtuFilename` in the app package's
/// `ttu_filename.dart`. hibiki_core cannot import the app package (reverse
/// dependency), so the migration must inline the logic. If either body is
/// edited without the other, cross-device book identity silently diverges —
/// the same title would map to different keys on different code paths.
///
/// This guard reads both source files as text and asserts the transformation
/// bodies are character-identical (after stripping per-line indentation), so any
/// drift fails CI instead of corrupting identity at runtime.
void main() {
  test('_sanitizeBookKey body matches sanitizeTtuFilename verbatim', () {
    final String coreBody = _extractSanitizeBody(
      File('lib/src/database/database.dart').readAsStringSync(),
    );
    final String appBody = _extractSanitizeBody(
      File('../../hibiki/lib/src/sync/ttu_filename.dart').readAsStringSync(),
    );

    expect(coreBody, isNotEmpty,
        reason: 'failed to locate _sanitizeBookKey body in database.dart');
    expect(appBody, isNotEmpty,
        reason: 'failed to locate sanitizeTtuFilename body in ttu_filename.dart');
    expect(coreBody, appBody,
        reason: 'sanitize bodies diverged — re-sync database.dart '
            '_sanitizeBookKey with ttu_filename.dart sanitizeTtuFilename');
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
  final int end = lines.indexWhere(
      (String l) => l.trim() == 'return result;', start);
  if (end < 0) return '';
  return lines
      .sublist(start, end + 1)
      .map((String l) => l.trim())
      .join('\n');
}

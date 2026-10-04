import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';

/// Executes the real paginated shell against an explicitly modeled DOM.
///
/// A settled 0 -> 24 -> 0 chrome-inset round trip must not repeatedly sample
/// the temporary page's first character and ratchet the reading position back.
/// The Node harness uses ideal vertical glyph geometry, not Android/WebView
/// rendering. It asserts observable characters/pages, including navigation and
/// viewport-height interleaving; it never replaces production reader methods.
void main() {
  test(
    'geometry round trips preserve the reading anchor until navigation',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }
      final File jsTest = File(
        'test/reader/geometry_reanchor_roundtrip_behavior_test.js',
      );
      expect(jsTest.existsSync(), isTrue);
      final Directory temp = Directory.systemTemp.createTempSync(
        'fushi-geometry-roundtrip-',
      );
      final File payload = File('${temp.path}/payload.json')
        ..writeAsStringSync(
          jsonEncode(<String, String>{
            'paged': ReaderPaginationScripts.paginatedShellSource(),
            'studyUnits': kStudyUnitJs,
          }),
        );
      late final ProcessResult result;
      try {
        result = await Process.run(
          nodeExe,
          <String>[jsTest.path, payload.path],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
      expect(
        result.exitCode,
        0,
        reason:
            'geometry round-trip JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'));
    },
  );
}

String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String candidate in candidates) {
    try {
      if (Process.runSync(candidate, <String>['--version']).exitCode == 0) {
        return candidate;
      }
    } on ProcessException {
      // Try the next executable name.
    }
  }
  return null;
}

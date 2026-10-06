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
      late final ProcessResult result;
      try {
        final File fixture = File('${temp.path}/geometry_roundtrip.cjs')
          ..writeAsStringSync(_productionFixtureSource(jsTest));
        result = await Process.run(
          nodeExe,
          <String>[fixture.path],
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
      expect(
        result.stdout.toString(),
        contains('all assertions passed (33 cases)'),
      );
    },
  );
}

/// Generates ordinary JavaScript functions from the trusted production source.
/// The harness receives an installer function, never a path or executable text
/// from command-line arguments. The complete shell remains under test.
String _productionFixtureSource(File jsTest) {
  final String shell = ReaderPaginationScripts.paginatedShellSource().trim();
  const String openingTag = '<script>';
  const String closingTag = '</script>';
  expect(shell, startsWith(openingTag));
  expect(shell, endsWith(closingTag));
  final String paginatedSource = shell.substring(
    openingTag.length,
    shell.length - closingTag.length,
  );
  return '''
const runCases = require(${jsonEncode(jsTest.absolute.path)});
function installStudyUnits(window) {
$kStudyUnitJs
}
function installProductionShell(window, document, getComputedStyle, Node,
    NodeFilter, requestAnimationFrame, setTimeout, CSS, Highlight) {
  installStudyUnits(window);
$paginatedSource
}
runCases(installProductionShell).catch(error => {
  console.error(error);
  process.exitCode = 1;
});
''';
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

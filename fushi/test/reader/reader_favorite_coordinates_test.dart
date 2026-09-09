import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_study_unit_script.dart';

/// Runs production scripts against real DOM Range and CSS Highlight APIs.
/// Set CHROME_EXECUTABLE on machines where Chromium is not in a standard path.
void main() {
  final String? chrome = <String?>[
    Platform.environment['CHROME_EXECUTABLE'],
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  ]
      .whereType<String>()
      .where((String path) => File(path).existsSync())
      .firstOrNull;

  test(
    'favorite anchors and native selections preserve actual DOM text',
    () async {
      final String bridgeSource = File(
        'lib/src/media/audiobook/highlight_bridge.dart',
      ).readAsStringSync();
      final String bridge = bridgeSource
          .split("_js = '''")[1]
          .split("''';")[0]
          .replaceAll(r'\\', r'\');
      final String visualNovelSource = File(
        'lib/src/reader/reader_visual_novel_scripts.dart',
      ).readAsStringSync();
      final String matchableRegex = RegExp(
        r'var readerRegex = (.+);',
      ).firstMatch(visualNovelSource)!.group(1)!.replaceAll(r'\\', r'\');
      final String cases = File(
        'test/reader/reader_favorite_coordinates_test.js',
      ).readAsStringSync();
      final Directory temp = Directory.systemTemp.createTempSync(
        'favorite-dom-',
      );
      try {
        final File html = File('${temp.path}/test.html');
        html.writeAsStringSync('''<!doctype html><meta charset="utf-8"><head>
<script>$kStudyUnitJs</script>
<script>${ReaderSelectionScripts.source()}</script>
<script>$bridge</script>
</head><body><script>
window.fushiReader = {isMatchableChar: ch => $matchableRegex.test(ch)};
$cases
</script></body>''');
        final ProcessResult result = await Process.run(chrome!, <String>[
          '--headless',
          '--no-sandbox',
          '--disable-gpu',
          '--no-first-run',
          '--disable-background-networking',
          '--dump-dom',
          '--user-data-dir=${temp.path}/profile',
          html.uri.toString(),
        ]).timeout(const Duration(seconds: 45));
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final RegExpMatch? payload = RegExp(
          r'<pre id="results">([^<]+)</pre>',
        ).firstMatch(result.stdout as String);
        expect(
          payload,
          isNotNull,
          reason: '${result.stdout}\n${result.stderr}',
        );
        final Map<String, dynamic> report =
            jsonDecode(utf8.decode(base64Decode(payload!.group(1)!)))
                as Map<String, dynamic>;
        expect(report['failures'], isEmpty, reason: '${report['failures']}');
        expect(report['passed'], 21);
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: chrome == null ? 'Chromium required; set CHROME_EXECUTABLE' : false,
  );
}

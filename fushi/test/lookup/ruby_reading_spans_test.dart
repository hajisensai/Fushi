import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart'
    show alignRubySpansToSearchTerm;
import 'package:fushi/src/reader/reader_selection_data.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiRubySpan;

/// 原文振假名随查词 payload 带给宿主（`rubyReadings`）：正文
/// `<ruby>忙<rt>せわ</rt></ruby>しい` 点「忙」，弹窗首条应是 せわしい 而不是高频的
/// いそがしい。根因是取词时 `<rt>` 被 createWalker 拒掉，来源读音在 JS 这一步就丢了。
///
/// 行为级：用 node 真执行阅读器注入脚本 `ReaderSelectionScripts.source()` 的
/// `selectFromPosition` / `rubyReadingSpans` / `buildSelectionPayload`。无 node 时 skip。
void main() {
  test('reader selection payload carries source ruby readings aligned to the '
      'lookup text (executes reader selection script via node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    final File jsTest = File('test/lookup/ruby_reading_spans_test.js');
    expect(
      jsTest.existsSync(),
      isTrue,
      reason: 'behavior harness ${jsTest.path} must exist',
    );

    final Directory tmp = Directory.systemTemp.createTempSync(
      'fushi_ruby_spans_',
    );
    final File readerJs = File('${tmp.path}/reader_selection.js');
    readerJs.writeAsStringSync(ReaderSelectionScripts.source());
    try {
      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[jsTest.path],
        workingDirectory: Directory.current.path,
        environment: <String, String>{
          'FUSHI_READER_SELECTION_JS': readerJs.path,
        },
      );
      expect(
        result.exitCode,
        0,
        reason:
            'ruby reading spans behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        contains('all assertions passed'),
        reason: 'behavior harness must reach its success marker',
      );
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('ReaderSelectionData parses rubyReadings and drops malformed spans', () {
    final ReaderSelectionData data = ReaderSelectionData.fromJson(
      <String, dynamic>{
        'text': '忙しい',
        'sentence': '時間が忙しい。',
        'rubyReadings': <Object?>[
          <String, Object?>{'s': 0, 'e': 1, 'r': ' せわ '},
          <String, Object?>{'s': 1, 'e': 1, 'r': 'x'},
          <String, Object?>{'s': 0, 'e': 1, 'r': ''},
          <String, Object?>{'s': 'a', 'e': 1, 'r': 'x'},
          'junk',
        ],
      },
    );
    expect(data.rubySpans, const <FushiRubySpan>[
      FushiRubySpan(start: 0, end: 1, reading: 'せわ'),
    ]);
    expect(
      ReaderSelectionData.fromJson(<String, dynamic>{'text': 'a'}).rubySpans,
      isEmpty,
      reason: '旧 payload 没有 rubyReadings',
    );
  });

  test(
    'ruby spans follow the leading-punctuation strip of the search term',
    () {
      final RegExp punctuation = RegExp(
        r'^[\p{P}\p{S}]+|[\p{P}\p{S}]+$',
        unicode: true,
      );
      // 「『忙しい』」：句首『被剥掉，忙 的区间左移一位；越界的段丢弃。
      expect(
        alignRubySpansToSearchTerm(
          raw: '『忙しい』',
          normalized: '忙しい',
          spans: const <FushiRubySpan>[
            FushiRubySpan(start: 1, end: 2, reading: 'せわ'),
            FushiRubySpan(start: 4, end: 5, reading: 'x'),
          ],
          punctuationRegex: punctuation,
        ),
        const <FushiRubySpan>[FushiRubySpan(start: 0, end: 1, reading: 'せわ')],
      );
      // 清洗后基字对不上（坐标失真）的段宁可不用。
      expect(
        alignRubySpansToSearchTerm(
          raw: '忙しい',
          normalized: '急しい',
          spans: const <FushiRubySpan>[
            FushiRubySpan(start: 0, end: 1, reading: 'せわ'),
          ],
          punctuationRegex: punctuation,
        ),
        isEmpty,
      );
    },
  );
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) {
        return name;
      }
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}

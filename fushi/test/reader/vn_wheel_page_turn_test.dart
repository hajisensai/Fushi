import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';

import '../helpers/source_guard.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// BUG-2364: VN has a paginator but no `paginationMetrics`. The shared wheel
/// listener must route that mode into `onWheelPaginate` instead of rejecting it
/// at the regular paged-shell capability gate.
void main() {
  late String wheelBody;

  setUpAll(() {
    final String source = readReaderPageSource();
    final int setupStart = source.indexOf(
      'var fushiContinuousMode = C.continuousMode;',
    );
    final int setupEnd = source.indexOf(
      'window.fushiProgressDetails = function()',
      setupStart,
    );
    expect(setupStart, isNonNegative, reason: 'reader setup start missing');
    expect(
      setupEnd,
      greaterThan(setupStart),
      reason: 'reader setup end missing',
    );
    final String wheelMethod = methodBody(
      source.substring(setupStart, setupEnd),
      "'wheel', function",
      lexicon: SourceLexicon.js,
    );
    final int bodyStart = wheelMethod.indexOf('{');
    expect(bodyStart, isNonNegative, reason: 'wheel callback body missing');
    wheelBody = wheelMethod.substring(bodyStart + 1, wheelMethod.length - 1);
  });

  test('VN paginator shape reproduces the former capability mismatch', () {
    final String shell = ReaderVisualNovelScripts.vnShellScript();
    expect(shell, contains('paginate: function(direction)'));
    expect(
      shell,
      isNot(contains('paginationMetrics:')),
      reason: 'VN advances logical screens and does not expose CSS columns',
    );
  });

  test(
    'production wheel listener routes VN through the shared paged handler',
    () {
      final Directory temp = Directory.systemTemp.createTempSync(
        'hibiki-vn-wheel-',
      );
      final File payload = File('${temp.path}/payload.json')
        ..writeAsStringSync(jsonEncode(<String, String>{'body': wheelBody}));
      late final ProcessResult result;
      try {
        result = Process.runSync(
          'node',
          <String>['-e', _wheelRouteRunner, payload.path],
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
            'VN wheel route runner failed:\n'
            'stdout=${result.stdout}\nstderr=${result.stderr}',
      );
      expect(result.stdout.toString().trim(), 'OK');
    },
  );
}

const String _wheelRouteRunner = r'''
const fs = require('fs');
const body = JSON.parse(fs.readFileSync(process.argv[1], 'utf8')).body;
function assert(value, message) {
  if (!value) throw new Error(message);
}

const listener = new Function(
  'window',
  'fushiContinuousMode',
  'fushiVnMode',
  '_handlePagedWheelTick',
  'C',
  'Date',
  'e',
  body,
);

function route({reader, vnMode}) {
  let calls = 0;
  listener(
    {fushiReader: reader},
    false,
    vnMode,
    () => { calls++; },
    {},
    Date,
    {deltaX: 0, deltaY: 120, preventDefault() {}},
  );
  return calls;
}

assert(route({reader: {paginate() {}}, vnMode: true}) === 1,
  'VN paginator without paginationMetrics must reach the shared wheel handler');
assert(route({reader: {paginate() {}, paginationMetrics: {}}, vnMode: false}) === 1,
  'regular paged mode must keep its existing wheel route');
assert(route({reader: {paginate() {}}, vnMode: false}) === 0,
  'an unrelated shell without paginationMetrics must remain rejected');
assert(route({reader: null, vnMode: true}) === 0,
  'missing reader must remain rejected');

process.stdout.write('OK');
''';

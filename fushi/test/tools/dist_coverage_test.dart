// Coverage of a distributed test run: the batches' lcov out of their event
// streams, checked and merged (tool/test_flow/dist_coverage.dart).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/dist_coverage.dart';

String _event(String lcov) =>
    '{"type":"$kDistCoverageEvent","lcov":"${base64.encode(utf8.encode(lcov))}"}';

void main() {
  test('coverage lines leave the event stream, the rest stays in order', () {
    final ({List<String> lines, List<String> lcov}) split =
        splitDistCoverage(<String>[
          '{"type":"start"}',
          _event('SF:lib/a.dart\nDA:1,1\nend_of_record\n'),
          '{"type":"done"}',
          '{"type":"fushiCoverage","lcov":"cut off',
        ]);
    expect(split.lines, <String>['{"type":"start"}', '{"type":"done"}']);
    expect(split.lcov, <String>['SF:lib/a.dart\nDA:1,1\nend_of_record\n']);
  });

  test('hits add up across batches; LF / LH are recomputed', () {
    final DistCoverage merged = <String, Map<int, int>>{};
    mergeLcov(
      merged,
      'SF:lib/b.dart\nDA:2,0\nDA:3,1\nLF:99\nLH:99\nend_of_record\n'
      'SF:lib/a.dart\nDA:1,2\nend_of_record\n',
      package: 'fushi',
    );
    mergeLcov(
      merged,
      'SF:lib\\b.dart\r\nDA:2,4\r\nend_of_record\r\n',
      package: 'fushi',
    );
    expect(
      renderLcov(merged),
      'SF:lib/a.dart\nDA:1,2\nLF:1\nLH:1\nend_of_record\n'
      'SF:lib/b.dart\nDA:2,4\nDA:3,1\nLF:2\nLH:2\nend_of_record\n',
    );
  });

  test('another machine\'s absolute paths map back into the package', () {
    final DistCoverage merged = <String, Map<int, int>>{};
    expect(
      mergeLcov(
        merged,
        'SF:/Users/t/.fushi-worker/work/packages/fushi_dictionary/lib/x.dart\n'
        'DA:1,1\nend_of_record\n'
        'SF:C:\\Users\\t\\work\\packages\\fushi_dictionary\\lib\\src\\y.dart\n'
        'DA:5,0\nend_of_record\n',
        package: 'packages/fushi_dictionary',
      ),
      0,
    );
    expect(
      merged.keys,
      unorderedEquals(<String>['lib/x.dart', 'lib/src/y.dart']),
    );
  });

  test('records outside the package\'s lib/ are dropped, never written', () {
    final DistCoverage merged = <String, Map<int, int>>{};
    final int dropped = mergeLcov(
      merged,
      'SF:../../etc/passwd\nDA:1,1\nend_of_record\n'
      'SF:lib/../../x.dart\nDA:1,1\nend_of_record\n'
      'SF:test/a_test.dart\nDA:1,1\nend_of_record\n'
      'SF:/w/packages/other/lib/z.dart\nDA:1,1\nend_of_record\n'
      'SF:lib/ok.dart\nDA:1,1\nDA:x,y\nend_of_record\n',
      package: 'packages/fushi_core',
    );
    expect(dropped, 4);
    expect(merged.keys, <String>['lib/ok.dart']);
    expect(merged['lib/ok.dart'], <int, int>{1: 1});
  });
}

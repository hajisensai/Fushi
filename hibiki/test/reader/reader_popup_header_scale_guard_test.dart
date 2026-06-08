import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final File reader =
      File('lib/src/pages/implementations/reader_hibiki_page.dart');

  test('dictionary popup header toolbar uses the reader chrome scale', () {
    final String src = reader.readAsStringSync();
    final String toolbar = _functionSource(
      src,
      '  Widget? buildPopupAudioControls()',
    );

    expect(
      src,
      contains('static const double _readerPopupHeaderBaseHeight'),
      reason: 'lookup popup header buttons need a scaled base height',
    );
    expect(
      toolbar,
      contains('ReaderChromeScaler('),
      reason: 'lookup popup header buttons must scale under the neutralizer',
    );
    expect(
      toolbar,
      contains('scale: _readerChromeScale'),
      reason: 'lookup popup header buttons should use the reader chrome scale',
    );
    expect(
      toolbar,
      contains('baseHeight: _readerPopupHeaderBaseHeight'),
      reason: 'lookup popup header height must follow app UI scale',
    );
  });
}

String _functionSource(String source, String start) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int bodyStart = source.indexOf('{', startIndex + start.length);
  expect(bodyStart, isNonNegative, reason: 'Missing function body: $start');

  int depth = 0;
  for (int index = bodyStart; index < source.length; index++) {
    final String char = source[index];
    if (char == '{') {
      depth++;
    } else if (char == '}') {
      depth--;
      if (depth == 0) {
        return source.substring(startIndex, index + 1);
      }
    }
  }

  fail('Missing function end: $start');
}

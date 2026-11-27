// BUG-5571: the capped log file must not rewrite itself on every append once it
// is full (2026-11-27 video freeze: VideoDiagLog re-trimmed its 4 MB file per
// line on the UI isolate).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/capped_log_file.dart';

/// Counts trims so the test can bound how often the file is rewritten.
class _CountingLog extends CappedLogFile {
  _CountingLog(super.file, {required super.maxBytes});

  int trims = 0;

  @override
  Future<void> trim() {
    trims++;
    return super.trim();
  }
}

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('capped-log');
  });
  tearDown(() => dir.delete(recursive: true));

  test('steady-state logging at the cap trims rarely, not once per line', () async {
    final File file = File('${dir.path}/log.txt');
    final _CountingLog log = _CountingLog(file, maxBytes: 1000);
    // 1000 lines of 10 bytes = 10 KB through a 1 KB cap. The old code re-trimmed
    // on (almost) every line once full: ~900 rewrites. With trimming down to 3/4
    // the cap, each trim buys >= 250 bytes of new lines.
    for (int i = 0; i < 1000; i++) {
      await log.append('line-${i.toString().padLeft(4, '0')}\n');
      expect(file.lengthSync(), lessThanOrEqualTo(1000));
    }
    expect(log.trims, lessThanOrEqualTo(10000 ~/ 250 + 1));
    expect(log.trims, greaterThan(0));
    final String text = file.readAsStringSync();
    expect(text, startsWith('line-'), reason: 'cut at a line start');
    expect(text, endsWith('line-0999\n'), reason: 'the newest line is kept');
  });

  test('a trim keeps at most trimToBytes, aligned to a line start', () async {
    final File file = File('${dir.path}/log.txt');
    file.writeAsStringSync(
      List<String>.generate(100, (int i) => 'row $i').join('\n') + '\n',
    );
    final CappedLogFile log = CappedLogFile(file, maxBytes: 200);
    await log.trimIfOver();
    final String text = file.readAsStringSync();
    expect(utf8.encode(text).length, lessThanOrEqualTo(150));
    expect(text, startsWith('row '));
    expect(text, endsWith('row 99\n'));
  });

  test('cutting never splits a multi-byte UTF-8 character', () async {
    final File file = File('${dir.path}/log.txt');
    file.writeAsStringSync('辞書を引く時間\n' * 40);
    final CappedLogFile log = CappedLogFile(file, maxBytes: 300);
    await log.trimIfOver();
    final List<int> bytes = file.readAsBytesSync();
    // Strict decode throws on a broken sequence.
    expect(() => utf8.decode(bytes), returnsNormally);
    expect(utf8.decode(bytes), startsWith('辞書を引く時間\n'));
  });

  test('under the cap nothing is rewritten', () async {
    final File file = File('${dir.path}/log.txt');
    final _CountingLog log = _CountingLog(file, maxBytes: 1000);
    await log.trimIfOver();
    await log.append('a\n');
    await log.append('b\n');
    expect(log.trims, 0);
    expect(file.readAsStringSync(), 'a\nb\n');
  });

  test('forgetSize re-measures after the file is cleared externally', () async {
    final File file = File('${dir.path}/log.txt');
    final _CountingLog log = _CountingLog(file, maxBytes: 100);
    await log.append('${'z' * 90}\n');
    file.writeAsStringSync('');
    log.forgetSize();
    await log.append('${'y' * 50}\n');
    expect(log.trims, 0, reason: 'a stale size would have trimmed here');
  });

  group('alignToLineStart', () {
    test('drops the partial first line', () {
      expect(
        CappedLogFile.alignToLineStart(
          Uint8List.fromList(utf8.encode('tial\nfull\n')),
        ),
        utf8.encode('full\n'),
      );
    });

    test('keeps a tail with no usable newline as-is', () {
      final Uint8List noNl = Uint8List.fromList(utf8.encode('abc'));
      expect(CappedLogFile.alignToLineStart(noNl), noNl);
      final Uint8List lastNl = Uint8List.fromList(utf8.encode('abc\n'));
      expect(CappedLogFile.alignToLineStart(lastNl), lastNl);
    });
  });
}

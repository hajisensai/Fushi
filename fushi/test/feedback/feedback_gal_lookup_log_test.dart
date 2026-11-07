import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi/src/feedback/feedback_gal_lookup_log.dart';

/// 反馈 Ny1bK1hFeJ：游戏内查词 / attached 表面的状态行只写进 hibiki_glookup.log，
/// 反馈附带的日志里一行都没有，表面隐藏几十秒的报告因此无从定位。反馈日志现在
/// 摘带白名单前缀的结构化诊断行；带台词 / 查询词的行不得进来。
void main() {
  group('galLookupDiagnosticLines', () {
    test('keeps whitelisted Dart and native state lines, drops the rest', () {
      const String raw =
          '2026-11-06T12:39:46.063  [native] gal-attached: state '
          'suspended/mouseHookBusy/low_level visible=0 tick=1 held_ms=2 from '
          'visible/visible/ visible=1\n'
          '2026-11-06T12:39:46.100  lookupText term=秘密 sentence=これは秘密\n'
          '2026-11-06T12:39:50  [native] gal-shield: handshake pending ended '
          'after 40ms\n'
          '2026-11-06T12:39:51.000  gal-click: dropped reason=line_changed '
          '(host)\n'
          '2026-11-06T12:39:52  [native] lookup hide tick=5 notify=1\n'
          '2026-11-06T12:39:53  [native] WebView2 create failed\n'
          'garbage-without-separator\n';
      final List<String> lines = galLookupDiagnosticLines(raw);
      expect(lines, hasLength(4));
      expect(lines[0], contains('gal-attached: state suspended/mouseHookBusy'));
      expect(lines[1], contains('gal-shield:'));
      expect(lines[2], contains('gal-click: dropped'));
      expect(lines[3], contains('lookup hide'));
      expect(lines.join('\n'), isNot(contains('秘密')));
    });

    test('keeps only the most recent lines', () {
      final String raw = <String>[
        for (int i = 0; i < 10; i++) '2026-11-06T00:00:0$i  gal-click: n=$i',
      ].join('\n');
      final List<String> lines = galLookupDiagnosticLines(raw, maxLines: 3);
      expect(lines, hasLength(3));
      expect(lines.first, endsWith('n=7'));
      expect(lines.last, endsWith('n=9'));
    });
  });

  group('readGalLookupDiagnosticLines', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('gal_log_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('missing file yields nothing', () {
      expect(
        readGalLookupDiagnosticLines(file: File('${dir.path}/absent.log')),
        isEmpty,
      );
    });

    test('reads only the tail and drops the cut first line', () {
      final File file = File('${dir.path}/hibiki_glookup.log');
      const String early = '2026-11-06T00:00:00  gal-click: early\n';
      final String filler = '${'x' * 200}\n';
      const String late = '2026-11-06T00:00:09  gal-shield: late\n';
      file.writeAsBytesSync(utf8.encode('$early$filler$late'));
      final List<String> lines = readGalLookupDiagnosticLines(
        file: file,
        tailBytes: late.length + 20,
      );
      expect(lines, <String>['2026-11-06T00:00:09  gal-shield: late']);
    });
  });
}

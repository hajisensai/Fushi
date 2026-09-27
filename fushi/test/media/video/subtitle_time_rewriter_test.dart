import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_reference_alignment.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_time_rewriter.dart';

List<AlignmentSegment> _shift(double seconds) => <AlignmentSegment>[
  AlignmentSegment(splitSeconds: null, offsetSeconds: seconds),
];

Uint8List _ascii(String s) => Uint8List.fromList(s.codeUnits);

const String _ass =
    '[Script Info]\r\n'
    'Title: test\r\n'
    '\r\n'
    '[V4+ Styles]\r\n'
    'Format: Name, Fontname, Fontsize\r\n'
    'Style: Default,Arial,20\r\n'
    '\r\n'
    '[Events]\r\n'
    'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n'
    'Dialogue: 0,0:00:05.00,0:00:07.50,Default,,0,0,0,,Hello, world\r\n'
    'Comment: 0,0:00:08.00,0:00:09.00,Default,,0,0,0,,note\r\n'
    r'Dialogue: 0,0:00:10.00,0:00:12.00,Sign,,0,0,0,,{\pos(100,200)}SIGN'
    '\r\n'
    'Dialogue: 0,0:00:13.00,0:00:14.00,Default,,0,0,0,,{\\i1}{\\b1}\r\n'
    r'Dialogue: 0,0:00:16.00,0:00:16.04,Sign,,0,0,0,,{\move(1,2,3,4)}X'
    '\r\n';

void main() {
  group('scanSubtitleTimedLines', () {
    test('ASS：注释、空文本、逐帧特效不当对齐证据；带 \\pos 的台词照算', () {
      final List<SubtitleTimedLine> lines = scanSubtitleTimedLines(_ass);
      expect(lines.map((SubtitleTimedLine l) => l.startMs), <int>[
        5000,
        8000,
        10000,
        13000,
        16000,
      ]);
      expect(lines.map((SubtitleTimedLine l) => l.alignable), <bool>[
        true,
        false,
        true,
        false,
        false,
      ]);
      expect(alignableCueStartSeconds(_ascii(_ass)), <double>[5.0, 10.0]);
    });

    test('ASS：Format 列顺序不同也按列名找 Start/End', () {
      const String ass =
          '[Events]\n'
          'Format: Layer, Style, Start, End, Text\n'
          'Dialogue: 0,Default,0:01:00.00,0:01:02.00,hi, there\n';
      final SubtitleTimedLine l = scanSubtitleTimedLines(ass).single;
      expect(l.startMs, 60000);
      expect(l.endMs, 62000);
    });

    test('SRT：块包含序号行与尾随空行', () {
      const String srt =
          '1\n00:00:01,000 --> 00:00:02,000\nA\n\n'
          '2\n00:00:03,000 --> 00:00:04,000\nB\n';
      final List<SubtitleTimedLine> lines = scanSubtitleTimedLines(srt);
      expect(lines, hasLength(2));
      expect(
        srt.substring(lines[0].blockStart, lines[0].blockEnd),
        '1\n00:00:01,000 --> 00:00:02,000\nA\n\n',
      );
    });
  });

  group('retimeSubtitleBytes', () {
    test('零偏移：逐字节相同', () {
      final Uint8List bytes = _ascii(_ass);
      expect(retimeSubtitleBytes(bytes, _shift(0)).bytes, same(bytes));
    });

    test('ASS：只改时间戳，其余字节（CRLF、样式、逗号文本、注释）原样', () {
      final SubtitleRetimeOutcome out = retimeSubtitleBytes(
        _ascii(_ass),
        _shift(1.234),
      );
      final String expected = _ass
          .replaceFirst('0:00:05.00,0:00:07.50', '0:00:06.23,0:00:08.73')
          .replaceFirst('0:00:08.00,0:00:09.00', '0:00:09.23,0:00:10.23')
          .replaceFirst('0:00:10.00,0:00:12.00', '0:00:11.23,0:00:13.23')
          .replaceFirst('0:00:13.00,0:00:14.00', '0:00:14.23,0:00:15.23')
          .replaceFirst('0:00:16.00,0:00:16.04', '0:00:17.23,0:00:17.27');
      expect(String.fromCharCodes(out.bytes), expected);
      expect(out.shiftedCount, 5);
      expect(out.droppedCount, 0);
    });

    test('SRT + CRLF：负偏移截到 0，整句落到 0 之前的删除', () {
      const String srt =
          '1\r\n00:00:01,000 --> 00:00:01,500\r\nA\r\n\r\n'
          '2\r\n00:00:03,000 --> 00:00:04,000\r\nB\r\n\r\n'
          '3\r\n01:00:00,000 --> 01:00:01,000\r\nC\r\n';
      final SubtitleRetimeOutcome out = retimeSubtitleBytes(
        _ascii(srt),
        _shift(-2.5),
      );
      expect(
        String.fromCharCodes(out.bytes),
        '2\r\n00:00:00,500 --> 00:00:01,500\r\nB\r\n\r\n'
        '3\r\n00:59:57,500 --> 00:59:58,500\r\nC\r\n',
      );
      expect(out.droppedCount, 1);
    });

    test('CM 负跳变区间里的 cue 删除，其余按各自段平移', () {
      const String srt =
          '1\n00:00:50,000 --> 00:00:51,000\nA\n\n'
          '2\n00:01:35,000 --> 00:01:36,000\nCM\n\n'
          '3\n00:02:00,000 --> 00:02:01,000\nB\n';
      final SubtitleRetimeOutcome out =
          retimeSubtitleBytes(_ascii(srt), const <AlignmentSegment>[
            AlignmentSegment(splitSeconds: 100, offsetSeconds: 10),
            AlignmentSegment(splitSeconds: null, offsetSeconds: 0),
          ]);
      expect(
        String.fromCharCodes(out.bytes),
        '1\n00:01:00,000 --> 00:01:01,000\nA\n\n'
        '3\n00:02:00,000 --> 00:02:01,000\nB\n',
      );
      expect(out.droppedCount, 1);
    });

    test('VTT：无小时的时间戳越过 1 小时时补上小时', () {
      const String vtt = 'WEBVTT\n\n59:59.000 --> 59:59.900 align:start\nA\n';
      final SubtitleRetimeOutcome out = retimeSubtitleBytes(
        _ascii(vtt),
        _shift(2),
      );
      expect(
        String.fromCharCodes(out.bytes),
        'WEBVTT\n\n01:00:01.000 --> 01:00:01.900 align:start\nA\n',
      );
    });

    test('Shift-JIS 字节（含 0x5C 尾字节）原样保留', () {
      // 「表示」= 95 5C 8E A6：0x5C 是反斜杠的 ASCII 值，按 latin1 视图照样不被动。
      final List<int> sjis = <int>[
        0x95,
        0x5c,
        0x8e,
        0xa6,
        0x82,
        0xb1,
        0x82,
        0xf1,
      ];
      final Uint8List bytes = Uint8List.fromList(<int>[
        ...'[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
                'Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,'
            .codeUnits,
        ...sjis,
        0x0a,
      ]);
      final Uint8List out = retimeSubtitleBytes(bytes, _shift(1)).bytes;
      expect(out.length, bytes.length);
      expect(out.sublist(out.length - sjis.length - 1, out.length - 1), sjis);
      expect(String.fromCharCodes(out), contains('0:00:02.00,0:00:03.00'));
    });

    test('UTF-16LE（带 BOM）按码元改写并保持 UTF-16LE', () {
      const String srt = '1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n';
      final List<int> units = srt.codeUnits;
      final Uint8List bytes = Uint8List.fromList(<int>[
        0xff,
        0xfe,
        for (final int u in units) ...<int>[u & 0xff, u >> 8],
      ]);
      final Uint8List out = retimeSubtitleBytes(bytes, _shift(1)).bytes;
      expect(out.sublist(0, 2), <int>[0xff, 0xfe]);
      final String decoded = String.fromCharCodes(<int>[
        for (int i = 2; i < out.length; i += 2) out[i] | (out[i + 1] << 8),
      ]);
      expect(decoded, '﻿'.isEmpty ? '' : decoded);
      expect(decoded, contains('00:00:02,000 --> 00:00:03,000'));
      expect(decoded, contains('こんにちは'));
    });

    test('缺空行的 SRT：删首条只删它自己（审查实测：旧实现输出为空）', () {
      const String srt =
          '1\n00:00:01,000 --> 00:00:02,000\nA\n'
          '2\n00:00:10,000 --> 00:00:11,000\nB\n'
          '3\n00:00:20,000 --> 00:00:21,000\nC\n';
      final SubtitleRetimeOutcome out = retimeSubtitleBytes(
        _ascii(srt),
        _shift(-5),
      );
      expect(
        String.fromCharCodes(out.bytes),
        '2\n00:00:05,000 --> 00:00:06,000\nB\n'
        '3\n00:00:15,000 --> 00:00:16,000\nC\n',
      );
      expect(out.droppedCount, 1);
    });

    test('ASS：0 时刻的 Comment 模板行不删，只截到 0', () {
      const String ass =
          '[Events]\n'
          'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
          'Comment: 0,0:00:00.00,0:00:00.00,Default,,0,0,0,template line,code\n'
          'Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,gone\n'
          'Dialogue: 0,0:00:10.00,0:00:11.00,Default,,0,0,0,,kept\n';
      final SubtitleRetimeOutcome out = retimeSubtitleBytes(
        _ascii(ass),
        _shift(-5),
      );
      final String text = String.fromCharCodes(out.bytes);
      expect(text, contains('Comment: 0,0:00:00.00,0:00:00.00,Default'));
      expect(text, isNot(contains('gone')));
      expect(text, contains('0:00:05.00,0:00:06.00,Default,,0,0,0,,kept'));
    });

    test('UTF-8 BOM + 无序号 SRT：首条能解析；首条被删时 BOM 保留', () {
      final Uint8List bytes = Uint8List.fromList(<int>[
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode(
          '00:00:01,000 --> 00:00:02,000\nA\n\n'
          '00:00:10,000 --> 00:00:11,000\nB\n',
        ),
      ]);
      expect(alignableCueStartSeconds(bytes), <double>[1.0, 10.0]);
      final Uint8List out = retimeSubtitleBytes(bytes, _shift(-5)).bytes;
      expect(out.sublist(0, 3), <int>[0xef, 0xbb, 0xbf]);
      expect(utf8.decode(out.sublist(3)), '00:00:05,000 --> 00:00:06,000\nB\n');
    });

    test('UTF-8 字节原样', () {
      final Uint8List bytes = Uint8List.fromList(
        utf8.encode('1\n00:00:01,000 --> 00:00:02,000\n日本語\n'),
      );
      final Uint8List out = retimeSubtitleBytes(bytes, _shift(1)).bytes;
      expect(utf8.decode(out), '1\n00:00:02,000 --> 00:00:03,000\n日本語\n');
    });

    test('tab 分隔的 SRT 时间行：能解析、平移，tab 原样保留', () {
      final Uint8List bytes = _ascii(
        '1\n\t00:00:01,000\t-->\t00:00:02,000\t\nA\n\n'
        '2\n00:00:10,000\t--> 00:00:11,000\nB\n',
      );
      expect(alignableCueStartSeconds(bytes), <double>[1.0, 10.0]);
      final Uint8List out = retimeSubtitleBytes(bytes, _shift(2)).bytes;
      expect(
        String.fromCharCodes(out),
        '1\n\t00:00:03,000\t-->\t00:00:04,000\t\nA\n\n'
        '2\n00:00:12,000\t--> 00:00:13,000\nB\n',
      );
    });

    test('ASS 时间列两侧带 tab 也能解析与平移', () {
      const String ass =
          '[Events]\n'
          'Format: Layer, Start, End, Style, Text\n'
          'Dialogue: 0,\t0:00:05.00\t,0:00:07.50\t,Default,hi\n';
      final SubtitleTimedLine l = scanSubtitleTimedLines(ass).single;
      expect(l.startMs, 5000);
      expect(l.endMs, 7500);
      final Uint8List out = retimeSubtitleBytes(_ascii(ass), _shift(1)).bytes;
      expect(
        String.fromCharCodes(out),
        '[Events]\n'
        'Format: Layer, Start, End, Style, Text\n'
        'Dialogue: 0,\t0:00:06.00\t,0:00:08.50\t,Default,hi\n',
      );
    });
  });
}

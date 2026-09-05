import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_cue_builder.dart';
import 'package:fushi/src/asr/asr_types.dart';

AsrTranscribedSegment _seg({
  int file = 0,
  required int startMs,
  required int endMs,
  required String text,
  required List<int> times,
}) {
  final List<String> tokens = text.split('');
  expect(tokens.length, times.length, reason: 'fixture token/time 数量不一致');
  return AsrTranscribedSegment(
    audioFileIndex: file,
    startMs: startMs,
    endMs: endMs,
    tokens: tokens,
    tokenTimesMs: times,
  );
}

void main() {
  const AsrCueBuilder builder = AsrCueBuilder();

  group('AsrCueBuilder 切句', () {
    test('单句：起止取 VAD 段边界而不是 token 时间', () {
      final AsrTranscribedSegment seg = _seg(
        startMs: 1000,
        endMs: 3000,
        text: '今日は。',
        times: <int>[1400, 1600, 1800, 2200],
      );
      final List<AsrCue> cues = builder.build(<AsrTranscribedSegment>[seg]);
      expect(cues, hasLength(1));
      expect(cues.single.startMs, 1000);
      expect(cues.single.endMs, 3000);
      expect(cues.single.text, '今日は。');
    });

    test('句末标点切句，闭合引号并入前句，中间边界用下一句首 token 减 leadIn', () {
      final AsrTranscribedSegment seg = _seg(
        startMs: 0,
        endMs: 6000,
        text: '「はい。」行く。',
        times: <int>[300, 500, 700, 1000, 1100, 3000, 3200, 3400],
      );
      final List<AsrCue> cues = builder.build(<AsrTranscribedSegment>[seg]);
      expect(cues.map((AsrCue c) => c.text), <String>['「はい。」', '行く。']);
      expect(cues[0].startMs, 0);
      // 下一句首 token 3000 - leadIn 150 = 2850。
      expect(cues[0].endMs, 2850);
      expect(cues[1].startMs, 2850);
      expect(cues[1].endMs, 6000);
    });

    test('token 间静默超过 gapSplitMs 也切句', () {
      final AsrTranscribedSegment seg = _seg(
        startMs: 0,
        endMs: 5000,
        text: 'ああいい',
        times: <int>[100, 200, 2000, 2100],
      );
      final List<AsrCue> cues = builder.build(<AsrTranscribedSegment>[seg]);
      expect(cues.map((AsrCue c) => c.text), <String>['ああ', 'いい']);
      expect(cues[0].endMs, 2000 - 150);
    });

    test('纯标点句丢弃', () {
      final AsrTranscribedSegment seg = _seg(
        startMs: 0,
        endMs: 2000,
        text: '。、',
        times: <int>[100, 200],
      );
      expect(builder.build(<AsrTranscribedSegment>[seg]), isEmpty);
    });

    test('超长无标点句在中段最大间隙处切开', () {
      final List<int> times = List<int>.generate(20, (int i) => i * 1000);
      // 第 9→10 个 token 之间留 3 秒大间隙（仍小于 gapSplit 不会被间隙切）。
      for (int i = 10; i < 20; i++) {
        times[i] += 0; // 间隙 1000ms，均匀
      }
      final AsrTranscribedSegment seg = _seg(
        startMs: 0,
        endMs: 20000,
        text: 'あ' * 20,
        times: times,
      );
      const AsrCueBuilder tight = AsrCueBuilder(
        gapSplitMs: 5000,
        maxCueMs: 8000,
      );
      final List<AsrCue> cues = tight.build(<AsrTranscribedSegment>[seg]);
      expect(cues.length, greaterThan(1));
      for (final AsrCue c in cues) {
        expect(c.endMs, greaterThan(c.startMs));
      }
      // 覆盖整段。
      expect(cues.first.startMs, 0);
      expect(cues.last.endMs, 20000);
    });

    test('最短时长兜底且不越过段终点', () {
      final AsrTranscribedSegment seg = _seg(
        startMs: 0,
        endMs: 1000,
        text: 'あ。い。',
        times: <int>[100, 150, 900, 950],
      );
      final List<AsrCue> cues = builder.build(<AsrTranscribedSegment>[seg]);
      expect(cues, hasLength(2));
      expect(cues[0].durationMs, greaterThanOrEqualTo(300));
      expect(cues[1].endMs, 1000);
      expect(cues[1].startMs, greaterThanOrEqualTo(cues[0].endMs));
    });
  });

  group('英语 BPE token 切句', () {
    AsrTranscribedSegment bpe({
      required int startMs,
      required int endMs,
      required List<String> tokens,
      int stepMs = 200,
      int firstMs = 300,
    }) {
      return AsrTranscribedSegment(
        audioFileIndex: 0,
        startMs: startMs,
        endMs: endMs,
        tokens: tokens,
        tokenTimesMs: List<int>.generate(
          tokens.length,
          (int i) => firstMs + i * stepMs,
        ),
      );
    }

    test('Mr. / Mrs. 的缩写点不切，只在句末的点切', () {
      final AsrTranscribedSegment seg = bpe(
        startMs: 0,
        endMs: 4000,
        tokens: <String>[
          ' Mr',
          '.',
          ' and',
          ' Mrs',
          '.',
          ' Dursley',
          ',',
          ' were',
          ' proud',
          '.',
        ],
      );
      final List<AsrCue> cues = builder.build(<AsrTranscribedSegment>[seg]);
      expect(cues.map((AsrCue c) => c.text), <String>[
        'Mr. and Mrs. Dursley, were proud.',
      ]);
      expect(cues.single.startMs, 0);
      expect(cues.single.endMs, 4000);
    });

    test('单个大写字母缩写（J. K. Rowling.）只切一次', () {
      final AsrTranscribedSegment seg = bpe(
        startMs: 0,
        endMs: 3000,
        tokens: <String>['J', '.', ' K', '.', ' Rowling', '.'],
      );
      final List<AsrCue> cues = builder.build(<AsrTranscribedSegment>[seg]);
      expect(cues.map((AsrCue c) => c.text), <String>['J. K. Rowling.']);
    });

    test('标点粘在 token 尾（world.）也能切', () {
      final AsrTranscribedSegment seg = bpe(
        startMs: 0,
        endMs: 5000,
        tokens: <String>[' Hello', ' world.', ' Good', ' night', '.'],
      );
      final List<AsrCue> cues = builder.build(<AsrTranscribedSegment>[seg]);
      expect(cues.map((AsrCue c) => c.text), <String>[
        'Hello world.',
        'Good night.',
      ]);
      // 下一句首 token（第 3 个，300 + 2×200 = 700）减 leadIn 150。
      expect(cues[0].endMs, 700 - 150);
      expect(cues[1].startMs, 700 - 150);
      expect(cues[1].endMs, 5000);
    });

    test('句末标点后带前导空格的闭合引号并入前句', () {
      final AsrTranscribedSegment seg = bpe(
        startMs: 0,
        endMs: 5000,
        tokens: <String>[' "', 'Yes', '.', ' "', ' She', ' left', '.'],
      );
      final List<AsrCue> cues = builder.build(<AsrTranscribedSegment>[seg]);
      expect(cues.map((AsrCue c) => c.text), <String>['"Yes. "', 'She left.']);
    });

    test('cue 文本 trim 后没有前导空格；两句起点均由 BPE 词首空格 token 开头', () {
      final AsrTranscribedSegment seg = bpe(
        startMs: 0,
        endMs: 5000,
        tokens: <String>[' It', ' was', ' cold', '.', ' Very', ' cold', '.'],
      );
      final List<AsrCue> cues = builder.build(<AsrTranscribedSegment>[seg]);
      expect(cues, hasLength(2));
      for (final AsrCue c in cues) {
        expect(c.text, isNot(startsWith(' ')));
        expect(c.text, isNot(endsWith(' ')));
        expect(c.text, c.text.trim());
      }
      expect(cues[0].text, 'It was cold.');
      expect(cues[1].text, 'Very cold.');
    });

    test('endsWithTerminator / isClosingMark 静态判定', () {
      expect(AsrCueBuilder.endsWithTerminator(' world.'), isTrue);
      expect(AsrCueBuilder.endsWithTerminator('.'), isTrue);
      expect(AsrCueBuilder.endsWithTerminator('。'), isTrue);
      expect(AsrCueBuilder.endsWithTerminator('? '), isTrue);
      expect(AsrCueBuilder.endsWithTerminator(' Mr'), isFalse);
      expect(AsrCueBuilder.endsWithTerminator(','), isFalse);
      expect(AsrCueBuilder.endsWithTerminator(''), isFalse);
      expect(AsrCueBuilder.endsWithTerminator('   '), isFalse);
      expect(AsrCueBuilder.isClosingMark(' "'), isTrue);
      expect(AsrCueBuilder.isClosingMark('”'), isTrue);
      expect(AsrCueBuilder.isClosingMark('」'), isTrue);
      expect(AsrCueBuilder.isClosingMark(' She'), isFalse);
      expect(AsrCueBuilder.dotAbbreviations, contains('mr'));
      expect(AsrCueBuilder.dotAbbreviations, contains('mrs'));
    });
  });

  group('多文件单时间轴', () {
    test('按文件偏移折算，且跨段不重叠', () {
      final AsrTranscribedSegment a = _seg(
        file: 0,
        startMs: 500,
        endMs: 2000,
        text: 'あ。',
        times: <int>[800, 900],
      );
      final AsrTranscribedSegment b = _seg(
        file: 1,
        startMs: 100,
        endMs: 1500,
        text: 'い。',
        times: <int>[400, 500],
      );
      final List<int> offsets = asrFileOffsetsFromDurations(<int>[
        60000,
        30000,
      ]);
      expect(offsets, <int>[0, 60000]);
      // 乱序输入也按 (file, start) 排序。
      final List<AsrCue> cues = builder.build(<AsrTranscribedSegment>[
        b,
        a,
      ], fileOffsetsMs: offsets);
      expect(cues, hasLength(2));
      expect(cues[0].startMs, 500);
      expect(cues[1].startMs, 60100);
      expect(cues[1].endMs, 61500);
      expect(cues[1].audioFileIndex, 1);
    });
  });

  group('SRT 序列化', () {
    test('格式与 SrtParser 契约一致', () {
      final String srt = serializeAsrCuesToSrt(<AsrCue>[
        const AsrCue(
          startMs: 0,
          endMs: 1234,
          text: 'こんにちは。',
          audioFileIndex: 0,
        ),
        const AsrCue(
          startMs: 3661000,
          endMs: 3662500,
          text: '二行\nテキスト',
          audioFileIndex: 0,
        ),
      ]);
      expect(
        srt,
        '1\n00:00:00,000 --> 00:00:01,234\nこんにちは。\n\n'
        '2\n01:01:01,000 --> 01:01:02,500\n二行 テキスト\n\n',
      );
    });

    test('空文本 cue 被跳过且序号连续', () {
      final String srt = serializeAsrCuesToSrt(<AsrCue>[
        const AsrCue(startMs: 0, endMs: 500, text: '', audioFileIndex: 0),
        const AsrCue(startMs: 600, endMs: 900, text: 'あ', audioFileIndex: 0),
      ]);
      expect(srt.startsWith('1\n00:00:00,600'), isTrue);
    });
  });
}

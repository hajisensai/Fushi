import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import '../../integration_test/helpers/media_fixtures.dart';

/// 纯 Dart roundtrip 测试：用 [buildSampleCues] 造样例 cue，用各字幕生成器
/// 序列化成文本，再用项目真实 parser 反解，断言能完整还原（数量 / 文本 /
/// 起止时间）。这保证我们生成的字幕格式与 parser 严格对齐，不会假绿。
void main() {
  const String bookKey = 'fixture-book';

  group('buildSampleCues', () {
    test('生成指定数量、单调递增、非零时长的 cue', () {
      final List<AudioCue> cues = buildSampleCues(bookKey: bookKey, count: 5);
      expect(cues, hasLength(5));
      for (int i = 0; i < cues.length; i++) {
        final AudioCue c = cues[i];
        expect(c.bookKey, bookKey);
        expect(c.sentenceIndex, i);
        expect(c.text, isNotEmpty);
        expect(c.endMs, greaterThan(c.startMs), reason: 'cue $i 必须有正时长');
        if (i > 0) {
          expect(c.startMs, greaterThanOrEqualTo(cues[i - 1].endMs),
              reason: 'cue $i 起点不得早于上一条终点');
        }
      }
    });
  });

  group('SRT roundtrip', () {
    test('cuesToSrt → SrtParser.parseString 完整还原', () {
      final List<AudioCue> cues = buildSampleCues(bookKey: bookKey, count: 5);
      final String srt = cuesToSrt(cues);
      final List<AudioCue> parsed =
          SrtParser.parseString(content: srt, bookKey: bookKey);

      expect(parsed, hasLength(cues.length));
      for (int i = 0; i < cues.length; i++) {
        expect(parsed[i].text, cues[i].text, reason: 'srt cue $i 文本');
        expect(parsed[i].startMs, cues[i].startMs, reason: 'srt cue $i start');
        expect(parsed[i].endMs, cues[i].endMs, reason: 'srt cue $i end');
      }
    });
  });

  group('VTT roundtrip', () {
    test('cuesToVtt → VttParser.parseString 完整还原', () {
      final List<AudioCue> cues = buildSampleCues(bookKey: bookKey, count: 5);
      final String vtt = cuesToVtt(cues);
      final List<AudioCue> parsed =
          VttParser.parseString(content: vtt, bookKey: bookKey);

      expect(parsed, hasLength(cues.length));
      for (int i = 0; i < cues.length; i++) {
        expect(parsed[i].text, cues[i].text, reason: 'vtt cue $i 文本');
        expect(parsed[i].startMs, cues[i].startMs, reason: 'vtt cue $i start');
        expect(parsed[i].endMs, cues[i].endMs, reason: 'vtt cue $i end');
      }
    });
  });

  group('ASS roundtrip', () {
    test('cuesToAss → AssParser.parseString 完整还原', () {
      final List<AudioCue> cues = buildSampleCues(bookKey: bookKey, count: 5);
      final String ass = cuesToAss(cues);
      final List<AudioCue> parsed =
          AssParser.parseString(content: ass, bookKey: bookKey);

      expect(parsed, hasLength(cues.length));
      for (int i = 0; i < cues.length; i++) {
        expect(parsed[i].text, cues[i].text, reason: 'ass cue $i 文本');
        expect(parsed[i].startMs, cues[i].startMs, reason: 'ass cue $i start');
        expect(parsed[i].endMs, cues[i].endMs, reason: 'ass cue $i end');
      }
    });
  });

  group('LRC roundtrip', () {
    // LRC 不存 endMs（由下一条 startMs 推导），所以只断言 startMs + text。
    test('cuesToLrc → LrcParser.parseString 还原 start + text', () {
      final List<AudioCue> cues = buildSampleCues(bookKey: bookKey, count: 5);
      final String lrc = cuesToLrc(cues);
      final List<AudioCue> parsed =
          LrcParser.parseString(content: lrc, bookKey: bookKey);

      expect(parsed, hasLength(cues.length));
      for (int i = 0; i < cues.length; i++) {
        expect(parsed[i].text, cues[i].text, reason: 'lrc cue $i 文本');
        expect(parsed[i].startMs, cues[i].startMs, reason: 'lrc cue $i start');
      }
    });
  });
}

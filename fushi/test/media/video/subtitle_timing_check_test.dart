import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/subtitle/subtitle_timing_check.dart';
import 'package:fushi/src/media/video/video_duration_probe.dart';

/// 造一条 srt：`count` 句，每句 2 秒，最后一句结束在 `lastEndSeconds`。
String _srt({required int count, required int lastEndSeconds}) {
  final StringBuffer buffer = StringBuffer();
  final int step = count <= 1 ? 0 : (lastEndSeconds - 2) ~/ (count - 1);
  for (int i = 0; i < count; i++) {
    final int start = i == count - 1 ? lastEndSeconds - 2 : i * step;
    final int end = start + 2;
    buffer
      ..writeln('${i + 1}')
      ..writeln('${_clock(start)},000 --> ${_clock(end)},000')
      ..writeln('line ${i + 1}')
      ..writeln();
  }
  return buffer.toString();
}

String _clock(int seconds) {
  final Duration d = Duration(seconds: seconds);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:'
      '${two(d.inSeconds.remainder(60))}';
}

void main() {
  group('summarizeSubtitleTiming', () {
    test('srt：条数 + 首尾时刻', () {
      final SubtitleTimingSummary s = summarizeSubtitleTiming(
        _srt(count: 3, lastEndSeconds: 1400),
      );
      expect(s.cueCount, 3);
      expect(s.firstStartMs, 0);
      expect(s.lastEndMs, 1400 * 1000);
    });

    test('vtt：小数点分隔 + 可省小时段', () {
      const String vtt = '''
WEBVTT

00:01.000 --> 00:03.500
hello

01:02:03.250 --> 01:02:05.750
world
''';
      final SubtitleTimingSummary s = summarizeSubtitleTiming(vtt);
      expect(s.cueCount, 2);
      expect(s.firstStartMs, 1000);
      expect(s.lastEndMs, ((1 * 60 + 2) * 60 + 5) * 1000 + 750);
    });

    test('ass：Dialogue 行的 2/3 字段是时间，首字段是层号（不能当时间读）', () {
      const String ass = '''
[Script Info]
Title: x

[Events]
Format: Layer, Start, End, Style, Name, Text
Dialogue: 0,0:00:01.10,0:00:03.45,Default,,0,0,0,,ようこそ
Dialogue: 0,0:23:11.00,0:23:14.20,Default,,0,0,0,,おわり
''';
      final SubtitleTimingSummary s = summarizeSubtitleTiming(ass);
      expect(s.cueCount, 2);
      expect(s.firstStartMs, 1100);
      // ass 的两位小数是**厘秒**：`.20` = 200ms，不是 20ms。
      expect(s.lastEndMs, (23 * 60 + 14) * 1000 + 200);
    });

    test('空 / 非字幕字节（比如被 HTML 错误页顶替）→ empty', () {
      expect(summarizeSubtitleTiming('').isEmpty, isTrue);
      expect(summarizeSubtitleTiming('   \n  ').isEmpty, isTrue);
      expect(
        summarizeSubtitleTiming('<html><body>403 Forbidden</body></html>')
            .isEmpty,
        isTrue,
      );
    });
  });

  group('checkSubtitleTiming', () {
    // 一集 24 分钟，字幕最后一句 23:20 —— 正常形状。
    const int episodeMs = 24 * 60 * 1000;
    final SubtitleTimingSummary healthy =
        summarizeSubtitleTiming(_srt(count: 300, lastEndSeconds: 23 * 60 + 20));

    test('正常一集 → ok', () {
      expect(
        checkSubtitleTiming(
          healthy,
          video: const KnownVideoDuration.probed(episodeMs),
        ).verdict,
        SubtitleTimingVerdict.ok,
      );
    });

    test('整季合并成一个文件（5 小时）装到 24 分钟的一集上 → 拒收', () {
      final SubtitleTimingSummary seasonPack = summarizeSubtitleTiming(
        _srt(count: 3000, lastEndSeconds: 5 * 3600),
      );
      final SubtitleTimingCheck check = checkSubtitleTiming(
        seasonPack,
        video: const KnownVideoDuration.probed(episodeMs),
      );
      expect(check.verdict, SubtitleTimingVerdict.overrunsVideo);
      expect(check.rejected, isTrue);
      expect(check.detail, contains('5:00:00'));
      expect(check.detail, contains('24:00'));
    });

    test('只覆盖到一半以下 → 可疑但**不拒收**（signs/歌词轨是合法的）', () {
      final SubtitleTimingSummary partial =
          summarizeSubtitleTiming(_srt(count: 12, lastEndSeconds: 90));
      final SubtitleTimingCheck check = checkSubtitleTiming(
        partial,
        video: const KnownVideoDuration.probed(episodeMs),
      );
      expect(check.verdict, SubtitleTimingVerdict.suspiciouslyShort);
      expect(check.rejected, isFalse);
    });

    test('视频时长未知 → 只做内容自检，绝不因为探测失败就拒收', () {
      expect(checkSubtitleTiming(healthy).verdict, SubtitleTimingVerdict.ok);
      expect(
        checkSubtitleTiming(healthy, video: const KnownVideoDuration.probed(0))
            .verdict,
        SubtitleTimingVerdict.ok,
      );
      // 时长未知时，即便字幕长达 5 小时也只能放行——没有可比对的事实。
      final SubtitleTimingSummary huge =
          summarizeSubtitleTiming(_srt(count: 10, lastEndSeconds: 5 * 3600));
      expect(checkSubtitleTiming(huge).verdict, SubtitleTimingVerdict.ok);
    });

    test('解析不出时间轴 → 拒收', () {
      final SubtitleTimingCheck check = checkSubtitleTiming(
        summarizeSubtitleTiming('not a subtitle at all'),
        video: const KnownVideoDuration.probed(episodeMs),
      );
      expect(check.verdict, SubtitleTimingVerdict.unparsable);
      expect(check.rejected, isTrue);
    });

    test('刮削 runtime 的容差必须比 ffprobe 宽（播出时长含广告位、只精确到分钟）', () {
      // 字幕跑到 30 分钟，视频「24 分钟」。
      final SubtitleTimingSummary long =
          summarizeSubtitleTiming(_srt(count: 50, lastEndSeconds: 30 * 60));
      expect(
        checkSubtitleTiming(
          long,
          video: const KnownVideoDuration.probed(episodeMs),
        ).verdict,
        SubtitleTimingVerdict.overrunsVideo,
        reason: 'ffprobe 的时长是精确事实，超出 15%+60s 就不可能是同一个视频',
      );
      expect(
        checkSubtitleTiming(
          long,
          video: const KnownVideoDuration.scrapedRuntime(episodeMs),
        ).verdict,
        SubtitleTimingVerdict.ok,
        reason: '刮削 runtime 只配当粗筛，拿它当精确事实会误伤',
      );
    });

    test('rejected 与 contradictsVideo 是两档强度，不能混用', () {
      // 有备选（下载流水线）：读不出就换下一个。
      // 无备选（番剧下载按集号锁定的唯一一条）：读不出不足以否决，只有
      // 「字幕比视频长得多」这种正面矛盾才配扔掉用户唯一的字幕。
      final SubtitleTimingCheck unreadable = checkSubtitleTiming(
        summarizeSubtitleTiming('garbage'),
        video: const KnownVideoDuration.probed(episodeMs),
      );
      expect(unreadable.rejected, isTrue);
      expect(unreadable.contradictsVideo, isFalse);

      final SubtitleTimingCheck overrun = checkSubtitleTiming(
        summarizeSubtitleTiming(_srt(count: 100, lastEndSeconds: 5 * 3600)),
        video: const KnownVideoDuration.probed(episodeMs),
      );
      expect(overrun.rejected, isTrue);
      expect(overrun.contradictsVideo, isTrue);

      final SubtitleTimingCheck short = checkSubtitleTiming(
        summarizeSubtitleTiming(_srt(count: 5, lastEndSeconds: 60)),
        video: const KnownVideoDuration.probed(episodeMs),
      );
      expect(short.rejected, isFalse);
      expect(short.contradictsVideo, isFalse);
    });

    test('短片不被比例项误伤（5 分钟 PV 的 15% 只有 45 秒）', () {
      const int pvMs = 5 * 60 * 1000;
      final SubtitleTimingSummary s =
          summarizeSubtitleTiming(_srt(count: 20, lastEndSeconds: 5 * 60 + 30));
      expect(
        checkSubtitleTiming(s, video: const KnownVideoDuration.probed(pvMs))
            .verdict,
        SubtitleTimingVerdict.ok,
      );
    });
  });

  group('parseFfprobeDurationMs', () {
    test('标准 json 输出', () {
      expect(
        parseFfprobeDurationMs('{"format":{"duration":"1421.234000"}}'),
        1421234,
      );
      expect(parseFfprobeDurationMs('{"format":{"duration":1421.5}}'), 1421500);
    });

    test('N/A / 缺字段 / 空 / 非 json / 非正数 → null（探不到就是探不到）', () {
      expect(parseFfprobeDurationMs('{"format":{"duration":"N/A"}}'), isNull);
      expect(parseFfprobeDurationMs('{"format":{}}'), isNull);
      expect(parseFfprobeDurationMs('{}'), isNull);
      expect(parseFfprobeDurationMs(''), isNull);
      expect(parseFfprobeDurationMs('not json'), isNull);
      expect(parseFfprobeDurationMs('{"format":{"duration":"0"}}'), isNull);
      expect(parseFfprobeDurationMs('{"format":{"duration":"-3"}}'), isNull);
    });
  });
}

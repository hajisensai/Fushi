/// #3722 video-36g：导入 / 扫描路径的字幕解析不得占住调用方 isolate。
///
/// 导入对话框、来源扫描、互联 host 收字幕、远端视频下载都在 UI isolate 上调
/// [parseSubtitleCues]；修前它是同步函数，一份 30000 行的特效 ASS 解析要上百毫秒，
/// 期间事件循环一拍都转不动（UI 冻住）。这里在解析大字幕的同时跑一个 1 ms 周期
/// 的定时器，断言它在解析期间照常走拍——同步解析时这个计数是 0。
library;

import 'dart:async';

import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_engine/media/video/video_library_import.dart';
import 'package:test/test.dart';

String _assTs(int ms) {
  final int h = ms ~/ 3600000;
  final int m = (ms ~/ 60000) % 60;
  final int s = (ms ~/ 1000) % 60;
  final int cs = (ms % 1000) ~/ 10;
  String two(int v) => v.toString().padLeft(2, '0');
  return '$h:${two(m)}:${two(s)}.${two(cs)}';
}

/// [lines] 行 Dialogue 的 ASS，倒序写入（验证结果仍按开始时间升序）。
String _bigAss(int lines) {
  final StringBuffer b = StringBuffer()
    ..writeln('[Script Info]')
    ..writeln('ScriptType: v4.00+')
    ..writeln('[Events]')
    ..writeln(
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, '
      'Effect, Text',
    );
  for (int i = lines - 1; i >= 0; i--) {
    final int start = i * 1000;
    b.writeln(
      'Dialogue: 0,${_assTs(start)},${_assTs(start + 900)},Default,,0,0,0,,'
      '{\\an8\\pos(320,50)\\fad(100,100)}字幕の行です\\N番号$i',
    );
  }
  return b.toString();
}

void main() {
  test('small srt parses inline into sorted cues', () async {
    const String srt =
        '2\n00:00:02,000 --> 00:00:03,000\nworld\n\n'
        '1\n00:00:00,000 --> 00:00:01,000\nhello\n';
    final List<AudioCue> cues = await parseSubtitleCues(
      content: srt,
      format: 'SRT',
      bookUid: 'video/1',
    );
    expect(cues.map((AudioCue c) => c.text), <String>['hello', 'world']);
    expect(cues.first.endMs, 1000);
  });

  test('unsupported format fails with ArgumentError', () async {
    await expectLater(
      parseSubtitleCues(content: 'x', format: 'mp3', bookUid: 'video/1'),
      throwsArgumentError,
    );
  });

  test('a large ASS is parsed off the calling isolate', () async {
    final String content = _bigAss(30000);
    expect(content.length, greaterThan(kSubtitleParseInlineMaxChars));

    int ticks = 0;
    final Timer ticker = Timer.periodic(
      const Duration(milliseconds: 1),
      (Timer _) => ticks++,
    );
    final List<AudioCue> cues;
    try {
      cues = await parseSubtitleCues(
        content: content,
        format: 'ass',
        bookUid: 'video/big',
      );
    } finally {
      ticker.cancel();
    }

    expect(cues, hasLength(30000));
    expect(cues.first.startMs, 0);
    expect(cues.last.startMs, 29999 * 1000);
    expect(cues.first.text, contains('番号0'));
    // 同步解析时事件循环被占满，ticks == 0；在别的 isolate 里解析，调用方
    // 这边只剩等结果，定时器照常走拍。
    expect(ticks, greaterThanOrEqualTo(3));
  });
}

import 'dart:typed_data';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:test/test.dart';

/// 20 ms 一帧：默认静音（−70 dB），[voiced] 里的毫秒区间是语音（−20）。
Int8List _energy(int totalMs, List<(int, int)> voiced) {
  final Int8List e = Int8List(totalMs ~/ 20)..fillRange(0, totalMs ~/ 20, -70);
  for (final (int a, int b) in voiced) {
    e.fillRange(a ~/ 20, b ~/ 20, -20);
  }
  return e;
}

AudioCue _cue(String text, int start, int end, {List<int>? offsets}) =>
    AudioCue()
      ..bookKey = 'b'
      ..chapterHref = ''
      ..sentenceIndex = 0
      ..textFragmentId = ''
      ..text = text
      ..startMs = start
      ..endMs = end
      ..audioFileIndex = 0
      ..tokenTiming = offsets == null
          ? null
          : CueTokenTiming(
              tokens: <String>[for (final int _ in offsets) 'x'],
              offsetsMs: offsets,
            );

void main() {
  const CueDisplayMargins margins = CueDisplayMargins();
  final Int8List energy = _energy(9000, <(int, int)>[
    (1000, 3000),
    (5000, 7000),
  ]);

  test('慢语速前后各留一段，token 绝对时刻不变', () {
    // 「ゆっくり話す。」6 个发音字 / 2 s = 3 cps → 慢档：头 120、尾封顶 250。
    final List<AudioCue> cues = <AudioCue>[
      _cue('ゆっくり話す。', 1000, 3080, offsets: <int>[0, 500]),
      _cue('次の文。', 5000, 7080),
    ];
    expect(margins.apply(cues, energy), 4);
    expect((cues[0].startMs, cues[0].endMs), (880, 3250));
    expect(cues[0].tokenTiming!.offsetsMs, <int>[120, 620]);
    expect((cues[1].startMs, cues[1].endMs), (4880, 7250));
  });

  test('快语速几乎不加：终点保持吸附结果', () {
    // 24 个发音字 / 2 s = 12 cps → 快档：头 40，尾 20（原终点更晚，不内收）。
    final List<AudioCue> cues = <AudioCue>[
      _cue('あいうえおかきくけこさしすせそたちつてとなにぬね', 1000, 3080),
    ];
    margins.apply(cues, energy);
    expect((cues[0].startMs, cues[0].endMs), (960, 3080));
  });

  test('发音字数只数字母 / 数字 / 假名 / 汉字', () {
    expect(CueDisplayMargins.countSpokenChars('「──何か、おかしい。」'), 6);
    expect(CueDisplayMargins.countSpokenChars('Ｍｓ．ヒビヤ'), 5);
    expect(CueDisplayMargins.countSpokenChars('……'), 0);
  });

  test('没有包络不动', () {
    final List<AudioCue> cues = <AudioCue>[_cue('はい。', 1000, 2000)];
    expect(margins.apply(cues, Int8List(0)), 0);
    expect((cues[0].startMs, cues[0].endMs), (1000, 2000));
  });
}

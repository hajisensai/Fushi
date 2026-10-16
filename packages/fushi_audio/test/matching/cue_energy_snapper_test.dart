import 'dart:typed_data';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:test/test.dart';

/// 20 ms 一帧的包络：默认全是语音（−20 dB），[silences] 里的毫秒区间是静音（−70）。
Int8List _energy(int totalMs, List<(int, int)> silences) {
  final Int8List e = Int8List(totalMs ~/ 20)..fillRange(0, totalMs ~/ 20, -20);
  for (final (int a, int b) in silences) {
    e.fillRange(a ~/ 20, b ~/ 20, -70);
  }
  return e;
}

AudioCue _cue(int start, int end, {int? firstTokenAt}) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = ''
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = 'x'
  ..startMs = start
  ..endMs = end
  ..audioFileIndex = 0
  ..tokenTiming = firstTokenAt == null
      ? null
      : CueTokenTiming(
          tokens: <String>['x'],
          offsetsMs: <int>[firstTokenAt - start],
        );

void main() {
  const CueEnergySnapper snapper = CueEnergySnapper();

  test('紧挨着的切点吸到停顿：前句收在谷起点 + 80，后句从谷终点 − 40 起', () {
    // 真实停顿在 [2300, 2700)，token 推算的切点在 2000。
    final List<AudioCue> cues = <AudioCue>[_cue(0, 2000), _cue(2000, 5000)];
    final int moved = snapper.snap(
      cues,
      _energy(6000, <(int, int)>[(2300, 2700)]),
    );
    expect(moved, 1);
    expect(cues[0].endMs, 2380);
    expect(cues[1].startMs, 2660);
  });

  test('附近没有足够长的停顿（只有 60 ms 的塞音闭塞）：不动', () {
    final List<AudioCue> cues = <AudioCue>[_cue(0, 2000), _cue(2000, 5000)];
    expect(snapper.snap(cues, _energy(6000, <(int, int)>[(2000, 2060)])), 0);
    expect(cues[0].endMs, 2000);
    expect(cues[1].startMs, 2000);
  });

  test('两条 cue 之间已有 VAD 切开的大空隙：不动', () {
    final List<AudioCue> cues = <AudioCue>[_cue(0, 2000), _cue(2600, 5000)];
    expect(snapper.snap(cues, _energy(6000, <(int, int)>[(2100, 2500)])), 0);
  });

  test('谷远在后句首 token 之后：吸过去会吃掉字头，不动', () {
    final List<AudioCue> cues = <AudioCue>[
      _cue(0, 2000),
      _cue(2000, 5000, firstTokenAt: 2050),
    ];
    expect(snapper.snap(cues, _energy(6000, <(int, int)>[(2400, 2600)])), 0);
    expect(cues[1].startMs, 2000);
  });

  test('吸附后一侧短于 500 ms：不动', () {
    final List<AudioCue> cues = <AudioCue>[_cue(0, 2000), _cue(2000, 2800)];
    expect(snapper.snap(cues, _energy(3000, <(int, int)>[(2300, 2500)])), 0);
  });

  test('包络未知（0）的帧按有声处理，不会凭空造谷', () {
    final List<AudioCue> cues = <AudioCue>[_cue(0, 2000), _cue(2000, 5000)];
    expect(snapper.snap(cues, Int8List(300)), 0);
  });

  group('refineEdges', () {
    test('起点落在静音里：挪到开口 − 150 ms', () {
      final List<AudioCue> cues = <AudioCue>[_cue(1000, 4000)];
      expect(
        snapper.refineEdges(cues, _energy(6000, <(int, int)>[(0, 1500)])),
        1,
      );
      expect(cues.single.startMs, 1350);
      expect(cues.single.endMs, 4000);
    });

    test('终点落在静音里：收到收声 + 80 ms', () {
      final List<AudioCue> cues = <AudioCue>[_cue(1000, 4000)];
      expect(
        snapper.refineEdges(cues, _energy(6000, <(int, int)>[(3500, 6000)])),
        1,
      );
      expect(cues.single.endMs, 3580);
    });

    test('开口在 600 ms 之外：不动', () {
      final List<AudioCue> cues = <AudioCue>[_cue(1000, 4000)];
      expect(
        snapper.refineEdges(cues, _energy(6000, <(int, int)>[(0, 2000)])),
        0,
      );
      expect(cues.single.startMs, 1000);
    });

    test('静音里 40 ms 的噪声尖峰不算开口', () {
      final Int8List e = _energy(6000, <(int, int)>[(0, 1500)])
        ..fillRange(1100 ~/ 20, 1140 ~/ 20, -20);
      final List<AudioCue> cues = <AudioCue>[_cue(1000, 4000)];
      snapper.refineEdges(cues, e);
      expect(cues.single.startMs, 1350);
    });

    test('收终点会早于末 token − 200 ms：不动', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(1000, 4000)
          ..tokenTiming = CueTokenTiming(
            tokens: <String>['a', 'b'],
            offsetsMs: <int>[0, 2900],
          ),
      ];
      // 收声 3500 → 本该收到 3580，但末 token 在 3900（守卫线 3700）。
      expect(
        snapper.refineEdges(cues, _energy(6000, <(int, int)>[(3500, 6000)])),
        0,
      );
      expect(cues.single.endMs, 4000);
    });

    test('收完短于 500 ms：不动', () {
      final List<AudioCue> cues = <AudioCue>[_cue(1000, 1800)];
      expect(
        snapper.refineEdges(cues, _energy(3000, <(int, int)>[(0, 1500)])),
        0,
      );
    });
  });
}

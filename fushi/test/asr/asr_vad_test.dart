import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_types.dart';
import 'package:fushi/src/asr/asr_vad.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';

const int kWin = kAsrVadWindowSamples;
const int kRate = kAsrSampleRate;

int ms(int milliseconds) => milliseconds * kRate ~/ 1000;

/// fake silero 会话：按窗口能量（默认）或按窗口序号脚本给概率。
///
/// 状态链校验：`new_h = h + 1`（逐元素），`new_c = c`，测试据此断言 h 在窗口间
/// 被回传、`reset()` 后归零。
class FakeVadSession implements OnnxSession {
  FakeVadSession({this.probByWindow});

  /// 按窗口序号（自会话创建/上次 reset 起）给概率；null 时按能量。
  final double Function(int windowIndex)? probByWindow;

  int calls = 0;
  final List<double> firstHValues = <double>[];

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    final OnnxTensor x = inputs[AsrModelIo.vadInputX]!;
    final OnnxTensor h = inputs[AsrModelIo.vadInputH]!;
    final OnnxTensor c = inputs[AsrModelIo.vadInputC]!;
    expect(x.shape, <int>[1, kWin]);
    expect(h.shape, <int>[2, 1, 64]);
    expect(c.shape, <int>[2, 1, 64]);
    firstHValues.add(h.floatData![0]);
    final int index = calls++;
    double prob;
    if (probByWindow != null) {
      prob = probByWindow!(index);
    } else {
      double peak = 0;
      for (final double v in x.floatData!) {
        if (v.abs() > peak) peak = v.abs();
      }
      prob = peak > 0.1 ? 0.9 : 0.05;
    }
    final Float32List newH = Float32List(128);
    for (int i = 0; i < 128; i++) {
      newH[i] = h.floatData![i] + 1;
    }
    return <String, OnnxTensor>{
      AsrModelIo.vadOutputProb: OnnxTensor.float32(
        Float32List.fromList(<double>[prob]),
        <int>[1, 1],
      ),
      AsrModelIo.vadOutputH: OnnxTensor.float32(newH, <int>[2, 1, 64]),
      AsrModelIo.vadOutputC: OnnxTensor.float32(
        Float32List.fromList(c.floatData!),
        <int>[2, 1, 64],
      ),
    };
  }

  @override
  Future<void> close() async {}
}

/// 拼一段音频：`(时长 ms, 是否语音)` 列表；语音用 0.5 幅度的锯齿（可辨识样本值），静音为 0。
Float32List synth(List<(int, bool)> parts) {
  int total = 0;
  for (final (int d, bool _) in parts) {
    total += ms(d);
  }
  final Float32List out = Float32List(total);
  int pos = 0;
  for (final (int d, bool speech) in parts) {
    final int n = ms(d);
    if (speech) {
      for (int i = 0; i < n; i++) {
        out[pos + i] = 0.2 + 0.3 * ((pos + i) % 97) / 97;
      }
    }
    pos += n;
  }
  return out;
}

/// 按 [chunkSize] 顺序喂完 + flush，返回全部段。
Future<List<AsrSpeechSegment>> runAll(
  AsrVadSegmenter seg,
  Float32List audio, {
  int chunkSize = 1000,
  int startSample = 0,
}) async {
  final List<AsrSpeechSegment> out = <AsrSpeechSegment>[];
  for (int off = 0; off < audio.length; off += chunkSize) {
    final int end =
        off + chunkSize > audio.length ? audio.length : off + chunkSize;
    out.addAll(
      await seg.feed(
        AsrPcmChunk(
          startSample: startSample + off,
          samples: Float32List.sublistView(audio, off, end),
        ),
      ),
    );
  }
  out.addAll(await seg.flush());
  return out;
}

void expectSamplesMatch(AsrSpeechSegment s, Float32List audio, int base) {
  expect(s.samples.length, s.endSample - s.startSample);
  for (int i = 0; i < s.samples.length; i++) {
    expect(
      s.samples[i],
      audio[s.startSample - base + i],
      reason: '样本 ${s.startSample + i} 不匹配',
    );
  }
}

void main() {
  group('AsrVadSegmenter', () {
    test('基本切段：静音-语音-静音 → 一段，边界按 512 窗口对齐并加 pad', () async {
      // 500 ms 静音 | 1000 ms 语音 | 1000 ms 静音。
      final Float32List audio = synth(<(int, bool)>[
        (500, false),
        (1000, true),
        (1000, false),
      ]);
      final FakeVadSession fake = FakeVadSession();
      final AsrVadSegmenter seg = AsrVadSegmenter(session: fake);
      final List<AsrSpeechSegment> segs = await runAll(
        seg,
        audio,
        chunkSize: 1000,
      );

      expect(segs, hasLength(1));
      // 语音从 8000 起，窗口 15 = [7680, 8192) 含语音 → speechStart 7680；
      // 语音到 24000 止，窗口 47 = [24064, …) 全静音 → silenceStart 24064。
      final AsrSpeechSegment s = segs.single;
      expect(s.startSample, 7680 - ms(200));
      expect(s.endSample, 24064 + ms(200));
      expectSamplesMatch(s, audio, 0);
      // 40000 样本 = 78 个整窗，剩 64 个样本不过 VAD。
      expect(fake.calls, 78);
    });

    test('短于 minSilence 的停顿合并进同一段', () async {
      final Float32List audio = synth(<(int, bool)>[
        (100, false),
        (500, true),
        (300, false), // < 500 ms
        (500, true),
        (800, false),
      ]);
      final AsrVadSegmenter seg = AsrVadSegmenter(session: FakeVadSession());
      final List<AsrSpeechSegment> segs = await runAll(seg, audio);
      expect(segs, hasLength(1));
      expect(segs.single.startMs, lessThan(100));
      expect(segs.single.endMs, greaterThan(1400));
    });

    test('长于 minSilence 的停顿切成两段，且两段 pad 后不重叠', () async {
      final Float32List audio = synth(<(int, bool)>[
        (0, false),
        (600, true),
        (550, false), // > 500 ms，但 < 2 × pad + minSilence/2 的组合上限
        (600, true),
        (800, false),
      ]);
      final AsrVadSegmenter seg = AsrVadSegmenter(session: FakeVadSession());
      final List<AsrSpeechSegment> segs = await runAll(seg, audio);
      expect(segs, hasLength(2));
      // 语音从文件头开始：首 pad 不越过 0。
      expect(segs[0].startSample, 0);
      // 第一段尾 pad = min(200 ms, minSilence/2=250 ms) = 200 ms。
      expect(segs[0].endSample, 9728 + ms(200));
      // 第二段首 pad 不越过第一段 pad 尾。
      expect(segs[1].startSample, greaterThanOrEqualTo(segs[0].endSample));
      expect(segs[1].startSample, lessThanOrEqualTo(ms(1150)));
      for (final AsrSpeechSegment s in segs) {
        expectSamplesMatch(s, audio, 0);
      }
    });

    test('短于 minSpeech 的语音丢弃', () async {
      final Float32List audio = synth(<(int, bool)>[
        (300, false),
        (100, true), // 100 ms < 250 ms
        (800, false),
        (400, true), // 保留
        (800, false),
      ]);
      final AsrVadSegmenter seg = AsrVadSegmenter(session: FakeVadSession());
      final List<AsrSpeechSegment> segs = await runAll(seg, audio);
      expect(segs, hasLength(1));
      expect(segs.single.startMs, greaterThan(900));
    });

    test('尾 pad 不越过文件末尾；flush 冲出尾段（含不足一窗的尾样本）', () async {
      final Float32List audio = synth(<(int, bool)>[(300, false), (700, true)]);
      // 16000 样本 = 31 窗 + 128 尾样本。
      expect(audio.length % kWin, 128);
      final AsrVadSegmenter seg = AsrVadSegmenter(session: FakeVadSession());
      final List<AsrSpeechSegment> segs = await runAll(
        seg,
        audio,
        chunkSize: 700,
      );
      expect(segs, hasLength(1));
      expect(segs.single.endSample, audio.length);
      expect(segs.single.startSample, 4608 - ms(200));
      expectSamplesMatch(segs.single, audio, 0);
    });

    test('超长语音在回看窗口内概率最低处强制切分，两半无缝衔接', () async {
      // 8 s 连续语音（250 窗），窗口 140（4.48 s）概率最低但仍在阈值之上。
      const int speechWindows = 250;
      final FakeVadSession fake = FakeVadSession(
        probByWindow: (int w) {
          if (w >= speechWindows) return 0.02;
          if (w == 140) return 0.55;
          if (w == 20) return 0.51; // 更低，但在回看窗口之外，不该被选中
          return 0.9;
        },
      );
      final AsrVadSegmenter seg = AsrVadSegmenter(
        session: fake,
        maxSegmentMs: 6000,
      );
      final Float32List audio = Float32List(kWin * 300);
      for (int i = 0; i < audio.length; i++) {
        audio[i] = (i % 1000) / 1000;
      }
      final List<AsrSpeechSegment> segs = await runAll(
        seg,
        audio,
        chunkSize: 4096,
      );

      expect(segs, hasLength(2));
      expect(segs[0].startSample, 0);
      expect(segs[0].endSample, 140 * kWin);
      expect(segs[1].startSample, 140 * kWin);
      expect(segs[1].endSample, speechWindows * kWin + ms(200));
      expectSamplesMatch(segs[0], audio, 0);
      expectSamplesMatch(segs[1], audio, 0);
    });

    test('强制切分后静音起点按切点之后的窗口重建', () async {
      // 语音 190 窗后进入静音；maxSegment 6 s（187.5 窗）在窗口 188 触发切分。
      // 回看窗口 [32, 187] 内最低是窗口 100；切点后仍全是语音，之后静音累计到 500 ms 落段。
      final FakeVadSession fake = FakeVadSession(
        probByWindow: (int w) {
          if (w >= 190) return 0.01;
          if (w == 100) return 0.6;
          return 0.95;
        },
      );
      final AsrVadSegmenter seg = AsrVadSegmenter(
        session: fake,
        maxSegmentMs: 6000,
      );
      final Float32List audio = Float32List(kWin * 230);
      final List<AsrSpeechSegment> segs = await runAll(
        seg,
        audio,
        chunkSize: kWin,
      );
      expect(segs, hasLength(2));
      expect(segs[0].endSample, 100 * kWin);
      expect(segs[1].startSample, 100 * kWin);
      expect(segs[1].endSample, 190 * kWin + ms(200));
    });

    test('reset 清空 LSTM 状态与计数，再喂同一文件得到相同段', () async {
      final Float32List audio = synth(<(int, bool)>[
        (200, false),
        (600, true),
        (800, false),
      ]);
      final FakeVadSession fake = FakeVadSession();
      final AsrVadSegmenter seg = AsrVadSegmenter(session: fake);
      final List<AsrSpeechSegment> first = await runAll(seg, audio);
      final int callsAfterFirst = fake.calls;
      // 状态链：第 k 次调用看到的 h[0] == k。
      expect(fake.firstHValues.last, callsAfterFirst - 1);

      seg.reset();
      final List<AsrSpeechSegment> second = await runAll(seg, audio);
      expect(fake.firstHValues[callsAfterFirst], 0, reason: 'reset 后 h 归零');
      expect(second, hasLength(first.length));
      for (int i = 0; i < first.length; i++) {
        expect(second[i].startSample, first[i].startSample);
        expect(second[i].endSample, first[i].endSample);
      }
    });

    test('不连续的块抛 ArgumentError', () async {
      final AsrVadSegmenter seg = AsrVadSegmenter(session: FakeVadSession());
      await seg.feed(AsrPcmChunk(startSample: 0, samples: Float32List(1000)));
      expect(
        () =>
            seg.feed(AsrPcmChunk(startSample: 1500, samples: Float32List(10))),
        throwsArgumentError,
      );
    });

    test(
        'inProgressSpeechStartSample：静默为 null，语音中为含 pad 的段起点，'
        '从该点 reset 续跑得到相同段', () async {
      final Float32List audio = synth(<(int, bool)>[
        (400, false),
        (1500, true),
        (1000, false),
      ]);
      final AsrVadSegmenter seg = AsrVadSegmenter(session: FakeVadSession());
      expect(seg.inProgressSpeechStartSample, isNull);

      const int chunk = 4000;
      final List<AsrSpeechSegment> full = <AsrSpeechSegment>[];
      final List<int?> checkpoints = <int?>[];
      for (int off = 0; off < audio.length; off += chunk) {
        final int end = off + chunk > audio.length ? audio.length : off + chunk;
        full.addAll(
          await seg.feed(
            AsrPcmChunk(
              startSample: off,
              samples: Float32List.sublistView(audio, off, end),
            ),
          ),
        );
        checkpoints.add(seg.inProgressSpeechStartSample);
      }
      full.addAll(await seg.flush());
      expect(full, hasLength(1));

      // 第 1 块 [0, 4000) 全静音；第 2 块 [4000, 8000) 在窗口 12 = [6144, 6656) 越过阈值。
      expect(checkpoints[0], isNull);
      expect(checkpoints[1], 6144 - ms(200));
      expect(checkpoints[1], full.single.startSample);
      // 段落封口后回到 null。
      expect(checkpoints.last, isNull);

      // 从检查点续跑：resumeSample = checkpoint ?? chunk.endSample。
      final int resume = checkpoints[1]!;
      seg.reset();
      final List<AsrSpeechSegment> resumed = await runAll(
        seg,
        Float32List.sublistView(audio, resume),
        chunkSize: chunk,
        startSample: resume,
      );
      expect(resumed, hasLength(1));
      expect(resumed.single.startSample, full.single.startSample);
      expect(resumed.single.endSample, full.single.endSample);
      expectSamplesMatch(resumed.single, audio, 0);
    });

    test('参数校验', () {
      expect(
        () => AsrVadSegmenter(session: FakeVadSession(), threshold: 1.5),
        throwsArgumentError,
      );
      expect(
        () => AsrVadSegmenter(session: FakeVadSession(), maxSegmentMs: 4000),
        throwsArgumentError,
      );
    });
  });
}

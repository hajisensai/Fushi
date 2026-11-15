import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/audio_energy_probe.dart';
import 'package:fushi/src/media/video/subtitle_waveform_segments.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 反馈 EUvw-RjUE4：波形对轴视图时间窗 = 片长全程、包络按段懒抽。这里锁住段划分 /
/// 相位一致 / 拼接 / 调度的纯逻辑。
AudioCue _cue(int startMs, int endMs) {
  return AudioCue()
    ..bookKey = ''
    ..chapterHref = ''
    ..sentenceIndex = 0
    ..textFragmentId = ''
    ..text = ''
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = 0;
}

const int _min = 60 * 1000;

void main() {
  group('segment constants', () {
    test(
      'segment length is a whole number of waveform frames and align bins',
      () {
        expect(kSubtitleWaveformSegmentMs % kSubtitleWaveformWindowMs, 0);
        expect(kSubtitleWaveformSegmentMs % kAudioEnergyWindowMs, 0);
      },
    );
  });

  group('subtitleWaveformWindowEndMs', () {
    test(
      'uses full duration, NOT the auto-align probe limit (24 min episode)',
      () {
        expect(
          subtitleWaveformWindowEndMs(
            durationMs: 24 * _min,
            cues: <AudioCue>[],
          ),
          24 * _min,
        );
        expect(24 * _min, greaterThan(kSubtitleAutoAlignProbeLimitMs));
      },
    );

    test('unknown duration falls back to latest cue end', () {
      expect(
        subtitleWaveformWindowEndMs(
          durationMs: 0,
          cues: <AudioCue>[_cue(1000, 9000), _cue(2000, 5000)],
        ),
        9000,
      );
      expect(subtitleWaveformWindowEndMs(durationMs: 0, cues: <AudioCue>[]), 0);
    });
  });

  group('segment boundaries', () {
    test(
      '24 min splits into 12 two-minute segments, last ends at duration',
      () {
        expect(waveformSegmentCount(24 * _min), 12);
        expect(
          waveformSegmentRange(11, durationMs: 24 * _min),
          const WaveformSegmentRange(22 * _min, 24 * _min),
        );
      },
    );

    test('partial last segment is clamped to duration', () {
      const int duration = 24 * _min + 17000;
      expect(waveformSegmentCount(duration), 13);
      expect(
        waveformSegmentRange(12, durationMs: duration),
        const WaveformSegmentRange(24 * _min, duration),
      );
    });

    test('zero / negative duration has no segments', () {
      expect(waveformSegmentCount(0), 0);
      expect(waveformSegmentCount(-5), 0);
      expect(waveformSegmentIndexAt(1000, durationMs: 0), -1);
    });

    test('index lookup clamps to valid range', () {
      expect(waveformSegmentIndexAt(-1, durationMs: 24 * _min), 0);
      expect(waveformSegmentIndexAt(0, durationMs: 24 * _min), 0);
      expect(waveformSegmentIndexAt(2 * _min - 1, durationMs: 24 * _min), 0);
      expect(waveformSegmentIndexAt(2 * _min, durationMs: 24 * _min), 1);
      expect(waveformSegmentIndexAt(23 * _min, durationMs: 24 * _min), 11);
      expect(waveformSegmentIndexAt(99 * _min, durationMs: 24 * _min), 11);
    });

    test('overlapping segments are ordered center-first', () {
      // 视口 [3:00, 7:00)：中点 5:00 在第 2 段 [4,6)，再按距离取第 1 / 3 段。
      expect(
        waveformSegmentsOverlapping(
          startMs: 3 * _min,
          endMs: 7 * _min,
          durationMs: 24 * _min,
        ),
        <int>[2, 1, 3],
      );
    });

    test('overlapping range is clamped to the window', () {
      expect(
        waveformSegmentsOverlapping(
          startMs: 23 * _min,
          endMs: 30 * _min,
          durationMs: 24 * _min,
        ),
        <int>[11],
      );
      expect(
        waveformSegmentsOverlapping(
          startMs: 30 * _min,
          endMs: 40 * _min,
          durationMs: 24 * _min,
        ),
        isEmpty,
      );
    });
  });

  group('stitching keeps per-segment phase', () {
    test('frame j of the stitched envelope starts at j * frameMs', () {
      // 段 400ms、帧 100ms => 每段 4 帧；片长 1000ms => 3 段（4+4+2 帧）。
      final List<double> out = stitchWaveformSegments(
        durationMs: 1000,
        segmentMs: 400,
        frameMs: 100,
        segments: <int, List<double>>{
          0: <double>[-10, -11, -12, -13],
          2: <double>[-30, -31],
        },
      );
      expect(out.length, 10);
      expect(out.sublist(0, 4), <double>[-10, -11, -12, -13]);
      // 未抽的第 1 段整段填静音，不挪动第 2 段的相位。
      expect(out.sublist(4, 8), everyElement(kSubtitleWaveformUnloadedDb));
      expect(out.sublist(8, 10), <double>[-30, -31]);
    });

    test('segment frames off by one are fitted within the segment only', () {
      final List<double> out = stitchWaveformSegments(
        durationMs: 800,
        segmentMs: 400,
        frameMs: 100,
        segments: <int, List<double>>{
          0: <double>[-1, -2, -3, -4, -5], // 多一帧（解码尾巴）
          1: <double>[-6, -7, -8], // 少一帧
        },
      );
      expect(out.length, 8);
      // 第 1 段永远从第 4 帧起，误差不跨段累积。
      expect(out[4], -6);
      expect(out.sublist(0, 4).every((double v) => v >= -5 && v <= -1), isTrue);
    });

    test(
      'fitWaveformSegmentFrames: exact length is identity, empty stays empty',
      () {
        final List<double> frames = <double>[-1, -2, -3];
        expect(identical(fitWaveformSegmentFrames(frames, 3), frames), isTrue);
        expect(fitWaveformSegmentFrames(const <double>[], 3), isEmpty);
        expect(fitWaveformSegmentFrames(<double>[-1, -2], 4), <double>[
          -1,
          -1,
          -2,
          -2,
        ]);
      },
    );

    test('frame count rounds the partial last frame up', () {
      expect(waveformFrameCount(1000, 20), 50);
      expect(waveformFrameCount(1010, 20), 51);
      expect(waveformFrameCount(0, 20), 0);
    });
  });

  group('waveformCeilingPercentile', () {
    test(
      'full load keeps the base percentile; partial load rescales top 1%',
      () {
        expect(waveformCeilingPercentile(1), closeTo(0.99, 1e-12));
        // 只抽到 1/12：顶部 1% 换算回全体桶 = 1/1200，上限仍是已抽段内的第 99 分位。
        expect(
          waveformCeilingPercentile(1 / 12),
          closeTo(1 - 0.01 / 12, 1e-12),
        );
        expect(waveformCeilingPercentile(0), 1);
        expect(waveformCeilingPercentile(double.nan), 1);
        expect(waveformCeilingPercentile(3), closeTo(0.99, 1e-12));
      },
    );

    test('loadedFraction tracks loaded segment time', () async {
      final SubtitleWaveformSegments segs = SubtitleWaveformSegments(
        durationMs: 5 * _min,
        loadSegment: (int s, int e) async => <double>[-20],
      );
      addTearDown(segs.dispose);
      expect(segs.loadedFraction, 0);
      await segs.ensureSegment(2); // 末段 [4:00, 5:00)
      expect(segs.loadedFraction, closeTo(1 / 5, 1e-12));
      await segs.ensureSegment(0);
      expect(segs.loadedFraction, closeTo(3 / 5, 1e-12));
    });
  });

  group('SubtitleWaveformSegments scheduling', () {
    test('ensureSegmentAt loads only the segment under the anchor', () async {
      final List<(int, int)> calls = <(int, int)>[];
      final SubtitleWaveformSegments segs = SubtitleWaveformSegments(
        durationMs: 24 * _min,
        loadSegment: (int s, int e) async {
          calls.add((s, e));
          return <double>[-20, -10];
        },
      );
      addTearDown(segs.dispose);
      expect(await segs.ensureSegmentAt(21 * _min), isTrue);
      expect(calls, <(int, int)>[(20 * _min, 22 * _min)]);
      expect(segs.stateOf(10), WaveformSegmentState.ready);
      expect(segs.stateOf(0), WaveformSegmentState.idle);
      // 拼好的包络覆盖片长全程（24 分钟 @20ms）。
      expect(segs.stitchedDb.length, 24 * _min ~/ kSubtitleWaveformWindowMs);
    });

    test(
      'loads run serially and off-view queued requests are cancelled',
      () async {
        final Map<int, Completer<List<double>>> gates =
            <int, Completer<List<double>>>{};
        final List<int> started = <int>[];
        final SubtitleWaveformSegments segs = SubtitleWaveformSegments(
          durationMs: 24 * _min,
          loadSegment: (int s, int e) {
            final int idx = s ~/ kSubtitleWaveformSegmentMs;
            started.add(idx);
            return (gates[idx] = Completer<List<double>>()).future;
          },
        );
        addTearDown(segs.dispose);
        segs.ensureRange(0, 6 * _min); // 段 0,1,2 进队；只开始一段
        await Future<void>.delayed(Duration.zero);
        expect(started.length, 1);
        // 视口跳到片尾：排队中的 0..2（除正在抽的那段）被撤销，末段进队。
        segs.ensureRange(22 * _min, 24 * _min);
        final int first = started.single;
        gates[first]!.complete(<double>[-10]);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(started, <int>[first, 11]);
        gates[11]!.complete(<double>[-12]);
        await Future<void>.delayed(Duration.zero);
        expect(segs.stateOf(11), WaveformSegmentState.ready);
        for (int i = 0; i <= 2; i++) {
          if (i == first) continue;
          expect(segs.stateOf(i), WaveformSegmentState.idle);
        }
      },
    );

    test(
      'empty segment is not auto-retried by ensureRange but is by ensureSegment',
      () async {
        int calls = 0;
        final SubtitleWaveformSegments segs = SubtitleWaveformSegments(
          durationMs: 2 * _min,
          loadSegment: (int s, int e) async {
            calls++;
            return const <double>[];
          },
        );
        addTearDown(segs.dispose);
        expect(await segs.ensureSegment(0), isFalse);
        expect(segs.stateOf(0), WaveformSegmentState.empty);
        segs.ensureRange(0, 2 * _min);
        await Future<void>.delayed(Duration.zero);
        expect(calls, 1);
        expect(await segs.ensureSegment(0), isFalse);
        expect(calls, 2);
      },
    );

    test('loader exceptions degrade the segment to empty', () async {
      final SubtitleWaveformSegments segs = SubtitleWaveformSegments(
        durationMs: 2 * _min,
        loadSegment: (int s, int e) async => throw StateError('ffmpeg gone'),
      );
      addTearDown(segs.dispose);
      expect(await segs.ensureSegment(0), isFalse);
      expect(segs.stateOf(0), WaveformSegmentState.empty);
    });
  });
}

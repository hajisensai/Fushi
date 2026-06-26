import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/audio_energy_probe.dart';
import 'package:hibiki/src/media/video/subtitle_auto_align.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-701 stage1: pure-algorithm + ffmpeg args/parse unit tests.

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

void main() {
  group('buildCueActivityEnvelope', () {
    test('empty cues / non-positive duration returns empty', () {
      expect(buildCueActivityEnvelope(<AudioCue>[], 10000), isEmpty);
      expect(buildCueActivityEnvelope(<AudioCue>[_cue(0, 100)], 0), isEmpty);
    });

    test('cue window sets covered bins to 1', () {
      final List<double> env = buildCueActivityEnvelope(
        <AudioCue>[_cue(200, 500)],
        1000,
        binMs: 100,
      );
      expect(env.length, 10);
      expect(env, <double>[0, 0, 1, 1, 1, 0, 0, 0, 0, 0]);
    });

    test('degenerate cue skipped; out-of-range clamped', () {
      final List<double> env = buildCueActivityEnvelope(
        <AudioCue>[_cue(500, 500), _cue(800, 5000)],
        1000,
        binMs: 100,
      );
      expect(env.length, 10);
      expect(env, <double>[0, 0, 0, 0, 0, 0, 0, 0, 1, 1]);
    });

    // TODO-413：前 N 分钟截断后，整段越上界的 cue 必须被跳过（不能 clamp 到末格
    // 堆出边界假活动），横跨上界的 cue 只保留窗内部分。
    test('cue entirely beyond truncated duration is dropped (not clamped)', () {
      // duration=1000ms (10 bins)；cue [1200,1500) 全在上界外 → 不应点亮任何格。
      final List<double> env = buildCueActivityEnvelope(
        <AudioCue>[_cue(1200, 1500)],
        1000,
        binMs: 100,
      );
      expect(env.length, 10);
      expect(env, List<double>.filled(10, 0.0), reason: '越上界 cue 不得在末格堆假活动');
    });

    test('cue straddling truncated duration keeps only in-window part', () {
      // cue [850,1300) 横跨上界 1000ms → 只点亮 bin 8、9（850..999），不延伸到末格之外。
      final List<double> env = buildCueActivityEnvelope(
        <AudioCue>[_cue(850, 1300)],
        1000,
        binMs: 100,
      );
      expect(env.length, 10);
      expect(env, <double>[0, 0, 0, 0, 0, 0, 0, 0, 1, 1]);
    });
  });

  group('normalizeAudioEnergyEnvelope', () {
    test('empty input returns empty', () {
      expect(normalizeAudioEnergyEnvelope(<double>[]), isEmpty);
    });

    test('flat input (degenerate range) returns all zero', () {
      expect(
        normalizeAudioEnergyEnvelope(<double>[-30, -30, -30]),
        <double>[0, 0, 0],
      );
    });

    test('energy threshold yields 0/1 VAD', () {
      final List<double> out = normalizeAudioEnergyEnvelope(
        <double>[-60, -50, -40, -20],
        voiceThreshold: 0.5,
      );
      expect(out, <double>[0, 0, 1, 1]);
    });

    test('NaN bins treated as 0 and do not pollute min/max', () {
      final List<double> out = normalizeAudioEnergyEnvelope(
        <double>[double.nan, -60, -20],
        voiceThreshold: 0.5,
      );
      expect(out[0], 0.0);
      expect(out[1], 0.0);
      expect(out[2], 1.0);
    });
  });

  group('bestOffsetMsByCrossCorrelation', () {
    test('empty / all-silent returns noData', () {
      expect(
        bestOffsetMsByCrossCorrelation(<double>[], <double>[1, 1]),
        SubtitleAutoAlignResult.noData,
      );
      expect(
        bestOffsetMsByCrossCorrelation(<double>[0, 0, 0], <double>[1, 1, 1]),
        SubtitleAutoAlignResult.noData,
      );
    });

    test('known positive offset: subtitle early -> positive offset', () {
      const int binMs = 100;
      final List<double> audio = List<double>.filled(12, 0.0);
      final List<double> cue = List<double>.filled(12, 0.0);
      for (int i = 5; i <= 7; i++) {
        audio[i] = 1.0;
      }
      for (int i = 2; i <= 4; i++) {
        cue[i] = 1.0;
      }
      final SubtitleAutoAlignResult r = bestOffsetMsByCrossCorrelation(
        audio,
        cue,
        binMs: binMs,
      );
      expect(r.status, SubtitleAutoAlignStatus.aligned);
      expect(r.offsetMs, 3 * binMs);
      expect(r.confidence, 1.0);
    });

    test('known negative offset: subtitle late -> negative offset', () {
      const int binMs = 100;
      final List<double> audio = List<double>.filled(12, 0.0);
      final List<double> cue = List<double>.filled(12, 0.0);
      for (int i = 2; i <= 4; i++) {
        audio[i] = 1.0;
      }
      for (int i = 6; i <= 8; i++) {
        cue[i] = 1.0;
      }
      final SubtitleAutoAlignResult r = bestOffsetMsByCrossCorrelation(
        audio,
        cue,
        binMs: binMs,
      );
      expect(r.status, SubtitleAutoAlignStatus.aligned);
      expect(r.offsetMs, -4 * binMs);
      expect(r.confidence, 1.0);
    });

    test('no clear match -> confidence below 1.0', () {
      const int binMs = 100;
      final List<double> audio = List<double>.filled(40, 0.0);
      final List<double> cue = List<double>.filled(40, 0.0);
      for (final int i in <int>[0, 10, 20, 30]) {
        audio[i] = 1.0;
      }
      for (int i = 3; i <= 18; i++) {
        cue[i] = 1.0;
      }
      final SubtitleAutoAlignResult r = bestOffsetMsByCrossCorrelation(
        audio,
        cue,
        binMs: binMs,
        maxShiftMs: 500,
      );
      expect(r.confidence, lessThan(1.0));
    });

    test('tie prefers smaller |shift|', () {
      const int binMs = 100;
      final List<double> audio = List<double>.filled(11, 0.0);
      final List<double> cue = List<double>.filled(11, 0.0);
      audio[5] = 1.0;
      cue[5] = 1.0;
      final SubtitleAutoAlignResult r = bestOffsetMsByCrossCorrelation(
        audio,
        cue,
        binMs: binMs,
      );
      expect(r.offsetMs, 0);
      expect(r.status, SubtitleAutoAlignStatus.aligned);
    });
  });

  group('buildFfmpegPcmEnvelopeArgs', () {
    test('astats paired with ametadata=print; ends with -f null -', () {
      final List<String> args = buildFfmpegPcmEnvelopeArgs(
        inputPath: '/tmp/v.mkv',
        windowMs: 100,
        sampleRate: 8000,
      );
      final String af = args[args.indexOf('-af') + 1];
      expect(af, contains('astats=metadata=1:reset=1'));
      expect(
        af,
        contains('ametadata=print:key=lavfi.astats.Overall.RMS_level'),
      );
      expect(af, contains('asetnsamples=n=800:p=0'));
      expect(af, contains('aresample=8000'));
      expect(args.sublist(args.length - 3), <String>['-f', 'null', '-']);
      expect(args, contains('-i'));
      expect(args, contains('/tmp/v.mkv'));
      expect(args.contains('-map'), isFalse);
    });

    test('audio stream index adds -map 0:a:<idx>', () {
      final List<String> args = buildFfmpegPcmEnvelopeArgs(
        inputPath: '/tmp/v.mkv',
        audioStreamIndex: 2,
        audioStreamCount: 3,
      );
      final int mapIdx = args.indexOf('-map');
      expect(mapIdx, greaterThanOrEqualTo(0));
      expect(args[mapIdx + 1], '0:a:2');
    });

    // TODO-413 档C：limitSeconds 加 ffmpeg `-t`（输出选项，须在 -i 之后）。
    test('limitSeconds adds -t after input', () {
      final List<String> args = buildFfmpegPcmEnvelopeArgs(
        inputPath: '/tmp/v.mkv',
        limitSeconds: 1200,
      );
      final int tIdx = args.indexOf('-t');
      expect(tIdx, greaterThanOrEqualTo(0));
      expect(args[tIdx + 1], '1200');
      expect(tIdx, greaterThan(args.indexOf('/tmp/v.mkv')),
          reason: '-t 须在输入之后（裁解码后的音频时长）');
    });

    test('limitSeconds null/non-positive omits -t', () {
      expect(
        buildFfmpegPcmEnvelopeArgs(inputPath: '/tmp/v.mkv').contains('-t'),
        isFalse,
      );
      expect(
        buildFfmpegPcmEnvelopeArgs(inputPath: '/tmp/v.mkv', limitSeconds: 0)
            .contains('-t'),
        isFalse,
      );
    });

    // TODO-413 §3：音轨越界（index >= count）时不加 -map（BUG-345 同范式回退默认轨），
    // 避免 ffmpeg `Stream map matches no streams` 硬失败。
    test('out-of-bounds audioStreamIndex drops -map (stream-bound guard)', () {
      final List<String> args = buildFfmpegPcmEnvelopeArgs(
        inputPath: '/tmp/v.mkv',
        audioStreamIndex: 3,
        audioStreamCount: 2,
      );
      expect(args.contains('-map'), isFalse,
          reason: 'index>=count 应回退默认轨，不加 -map');
    });

    test('in-bounds audioStreamIndex with count keeps -map', () {
      final List<String> args = buildFfmpegPcmEnvelopeArgs(
        inputPath: '/tmp/v.mkv',
        audioStreamIndex: 1,
        audioStreamCount: 2,
      );
      final int mapIdx = args.indexOf('-map');
      expect(mapIdx, greaterThanOrEqualTo(0));
      expect(args[mapIdx + 1], '0:a:1');
    });
  });

  // TODO-413 档C：截断到前 N 分钟后，喂合成「已知 offset」序列仍算出该 offset，
  // 且超界 cue 被过滤、不污染互相关。
  group('truncated pipeline still recovers known offset', () {
    test('cues clamped to limit + cross-correlation finds offset', () {
      const int binMs = 100;
      // 截断上界 1000ms（10 bins）。音频活动在 bins 5..7。
      const int limitMs = 1000;
      final List<double> audio = List<double>.filled(10, 0.0);
      for (int i = 5; i <= 7; i++) {
        audio[i] = 1.0;
      }
      // 字幕：窗内一条 [200,500)（bins 2..4，比音频早 3 格）+ 一条整段越界
      // [1200,1500)（必须被过滤，否则在末格堆假活动改变互相关结果）。
      final List<AudioCue> cues = <AudioCue>[_cue(200, 500), _cue(1200, 1500)];
      final List<double> cueActivity =
          buildCueActivityEnvelope(cues, limitMs, binMs: binMs);
      // 越界 cue 被丢弃：只剩 bins 2..4。
      expect(cueActivity, <double>[0, 0, 1, 1, 1, 0, 0, 0, 0, 0]);

      final SubtitleAutoAlignResult r = bestOffsetMsByCrossCorrelation(
        audio,
        cueActivity,
        binMs: binMs,
      );
      expect(r.status, SubtitleAutoAlignStatus.aligned);
      expect(r.offsetMs, 3 * binMs,
          reason: '字幕早 3 格 → 正 offset 300ms（截断不改变窗内相位）');
      expect(r.confidence, 1.0);
    });
  });

  group('parseAudioRmsEnvelopeFromFfmpegLog', () {
    test('parses per-frame RMS_level (-inf -> silenceDb)', () {
      const String stderr = 'frame:0    pts:0       pts_time:0\n'
          'lavfi.astats.Overall.RMS_level=-30.123456\n'
          'frame:1    pts:800     pts_time:0.1\n'
          'lavfi.astats.Overall.RMS_level=-inf\n'
          'frame:2    pts:1600    pts_time:0.2\n'
          'lavfi.astats.Overall.RMS_level=-22.5\n';
      final List<double> env = parseAudioRmsEnvelopeFromFfmpegLog(
        stderr,
        silenceDb: -120.0,
      );
      expect(env.length, 3);
      expect(env[0], closeTo(-30.123456, 1e-6));
      expect(env[1], -120.0);
      expect(env[2], closeTo(-22.5, 1e-6));
    });

    test('no per-frame lines returns empty', () {
      expect(parseAudioRmsEnvelopeFromFfmpegLog(''), isEmpty);
      expect(
        parseAudioRmsEnvelopeFromFfmpegLog('Stream #0:0: Audio: aac'),
        isEmpty,
      );
    });
  });
}

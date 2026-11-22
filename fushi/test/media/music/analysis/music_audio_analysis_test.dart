import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/analysis/music_audio_analysis.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_audio.dart';

/// 夹具由 native/fushi_compute 的 `format::tests::golden()` 编码写出（Rust 测试
/// `golden_fixture_matches_dart_side` 逐字节比对同一个文件），这里按同一份已知值断言：两侧布局一致。
Uint8List _golden() =>
    File('test/media/music/analysis/fixtures/golden.fma').readAsBytesSync();

void main() {
  group('MusicAudioAnalysis.tryParse', () {
    test('reads the Rust-written golden file', () {
      final MusicAudioAnalysis a = MusicAudioAnalysis.tryParse(_golden())!;
      expect(
        a.flags,
        MusicAudioAnalysisFlags.beatsModel | MusicAudioAnalysisFlags.drumsModel,
      );
      expect(a.beatsFromModel, isTrue);
      expect(a.drumsFromModel, isTrue);
      expect(a.vocalFromModel, isFalse);
      expect(a.drumless, isFalse);
      expect(a.frameRate, closeTo(22050 / 256, 1e-3));
      expect(a.frameCount, 5);
      expect(a.bpm, 120);
      expect(a.beatsPerBar, 3);
      expect(a.durationMs, 58);
      expect(a.pipelineVersion, 1);
      expect(a.beatTimesMs, <int>[0, 500, 1000, 1500]);
      expect(a.downbeatTimesMs, <int>[0, 1500]);
      expect(a.hitTimesMs, <int>[10, 510, 1010]);
      expect(a.hitStrength(0), 1.0);
      expect(a.hitStrength(1), closeTo(0.5, 0.01));
      expect(a.hitKind(0), MusicDrumHitKind.kick);
      expect(a.hitKind(1), MusicDrumHitKind.snare);
      expect(a.hitKind(2), MusicDrumHitKind.hat);
      expect(a.vocalOnsetsMs, <int>[20, 40]);
      expect(a.envelopeReady, isTrue);
      expect(a.beatsReady, isTrue);
      expect(a.drumsReady, isTrue);
    });

    test('rejects garbage, truncation and other versions', () {
      expect(MusicAudioAnalysis.tryParse(Uint8List(10)), isNull);
      final Uint8List g = _golden();
      expect(
        MusicAudioAnalysis.tryParse(Uint8List.sublistView(g, 0, g.length - 4)),
        isNull,
      );
      final Uint8List wrongFormat = Uint8List.fromList(g)..[4] = 9;
      expect(MusicAudioAnalysis.tryParse(wrongFormat), isNull);
      expect(
        MusicAudioAnalysis.tryParse(g, expectedPipelineVersion: 2),
        isNull,
      );
      expect(
        MusicAudioAnalysis.tryParse(g, expectedPipelineVersion: 1),
        isNotNull,
      );
    });
  });

  group('frameAt', () {
    final MusicAudioAnalysis a = MusicAudioAnalysis.tryParse(_golden())!;
    final double frameMs = 1000 / a.frameRate;

    test('samples envelope frames and interpolates between them', () {
      final LyricVisualizerAudioFrame f1 = a.frameAt((frameMs * 1).round());
      // 整毫秒取不到帧中心：帧 1 之后约 0.03 帧。
      expect(f1.power, closeTo(0.5, 0.04));
      expect(f1.onset, closeTo(1.0, 0.04));
      expect(f1.low, closeTo(0.0, 0.02));
      final LyricVisualizerAudioFrame mid = a.frameAt((frameMs * 1.5).round());
      expect(mid.power, closeTo(0.75, 0.04));
      expect(mid.envelopeReady, isTrue);
      expect(mid.fallback, isFalse);
      expect(mid.bpm, 120);
    });

    test('outside the analysed range the envelope is silent', () {
      expect(a.frameAt(-100).power, 0);
      expect(a.frameAt(100000).power, 0);
    });

    test('beat, downbeat and drum impacts decay from the last hit', () {
      final LyricVisualizerAudioFrame onBeat = a.frameAt(500);
      expect(onBeat.beatImpact, closeTo(1, 1e-9));
      expect(onBeat.downbeatImpact, lessThan(0.3));
      final LyricVisualizerAudioFrame later = a.frameAt(
        500 + kMusicBeatImpactDecayMs,
      );
      expect(later.beatImpact, closeTo(0.3679, 1e-3));
      final LyricVisualizerAudioFrame bar = a.frameAt(1500);
      expect(bar.downbeatImpact, closeTo(1, 1e-9));
      // 鼓点 510 ms 强度 0.5。
      expect(a.frameAt(510).drumImpact, closeTo(0.5, 0.01));
      // 10 ms 处强度 1 的底鼓衰减到 520 ms 时已小于新的那一下。
      expect(a.frameAt(520).drumImpact, closeTo(0.5 * 0.936, 0.02));
      expect(a.frameAt(5).drumImpact, 0);
      expect(
        onBeat.beatsReady && onBeat.drumsReady && onBeat.vocalReady,
        isTrue,
      );
    });
  });
}

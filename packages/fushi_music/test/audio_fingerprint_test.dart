import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

/// 经真原生库跑声纹 + 对齐（合成样本，与 Rust 单测同一套生成规则）。
/// 原生库是硬依赖：找不到库这里判红（FushiMusicUnavailableError），不 skip。

const int _sr = kAudioFingerprintSampleRate;

/// LCG 选音高的三音和弦序列 + 低电平噪声（同 fingerprint.rs `synth::music`）。
Int16List _music(int seed, double seconds, int noteMs, double amplitude) {
  final int total = (seconds * _sr).floor();
  final int perNote = noteMs * _sr ~/ 1000;
  BigInt state = BigInt.from(seed);
  final BigInt mask = (BigInt.one << 64) - BigInt.one;
  final BigInt mul = BigInt.parse('6364136223846793005');
  final BigInt inc = BigInt.parse('1442695040888963407');
  int next() {
    state = (state * mul + inc) & mask;
    return (state >> 33).toInt();
  }

  final Int16List out = Int16List(total);
  final List<double> freqs = <double>[0, 0, 0];
  final List<double> phase = <double>[0, 0, 0];
  for (int i = 0; i < total; i++) {
    if (i % perNote == 0) {
      for (int f = 0; f < 3; f++) {
        freqs[f] = 110.0 * math.pow(2, (next() % 37) / 12.0);
      }
    }
    double v = 0;
    for (int f = 0; f < 3; f++) {
      phase[f] += 2 * math.pi * freqs[f] / _sr;
      v += math.sin(phase[f]);
    }
    final double noise = ((next() % 2001) - 1000.0) / 1000.0 * 0.02;
    out[i] = ((v / 3.0 + noise) * amplitude * 32767.0).truncate();
  }
  return out;
}

void main() {
  late AudioFingerprinter fp;
  setUpAll(() => fp = AudioFingerprinter.instance);

  test('版本与项时长与 Rust 常量一致', () {
    expect(fp.version, 1);
    expect(fp.itemMs, closeTo(1365 * 1000 / 11025, 1e-9));
  });

  test('歌曲嵌在整集 47.3 s 处：起止误差在半项以内', () {
    final Int16List song = _music(0xA11CE, 30.0, 350, 0.5);
    final Int16List episode = _music(0xB0B, 120.0, 500, 0.5);
    episode.setRange(
      (47.3 * _sr).floor(),
      (47.3 * _sr).floor() + song.length,
      song,
    );
    final AudioFingerprintMatch? m = fp.align(
      fp.compute(song),
      fp.compute(episode),
    );
    expect(m, isNotNull);
    final double tol = fp.itemMs / 2 + 1;
    expect(
      m!.haystackStart.inMilliseconds - 47300,
      inInclusiveRange(-tol, tol),
    );
    expect(m.haystackEnd.inMilliseconds - 77300, inInclusiveRange(-tol, tol));
    expect(m.startAtNeedleEdge && m.endAtNeedleEdge, isTrue);
    expect(m.confidence, greaterThan(0.6));
  });

  test('歌不在里面：返回 null', () {
    expect(
      fp.align(
        fp.compute(_music(0xA11CE, 30.0, 350, 0.5)),
        fp.compute(_music(0xB0B, 120.0, 500, 0.5)),
      ),
      isNull,
    );
  });

  test('MV：8 s 前奏 + 整首歌 → 偏移 +8 s', () {
    final Int16List song = _music(0x4D56, 25.0, 300, 0.5);
    final Int16List intro = _music(0x1A7, 8.0, 600, 0.4);
    final Int16List mv = Int16List(intro.length + song.length)
      ..setAll(0, intro)
      ..setAll(intro.length, song);
    final AudioFingerprintMatch? m = fp.align(fp.compute(song), fp.compute(mv));
    expect(m, isNotNull);
    expect(
      (m!.offset.inMilliseconds - 8000).abs(),
      lessThanOrEqualTo(fp.itemMs / 2 + 1),
    );
  });

  test('raw PCM 文件与内存 PCM 声纹一致', () {
    final Int16List song = _music(7, 12.0, 400, 0.6);
    final Directory dir = Directory.systemTemp.createTempSync('ffm_fp_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File raw = File('${dir.path}/song.s16le')
      ..writeAsBytesSync(song.buffer.asUint8List());
    expect(fp.computeRawPcmFile(raw.path), fp.compute(song));
  });

  test('非法格式抛 AudioFingerprintFormatError', () {
    expect(
      () => fp.compute(Int16List(3), channels: 2),
      throwsA(isA<AudioFingerprintFormatError>()),
    );
    expect(
      () => fp.compute(Int16List(4), sampleRate: 0),
      throwsA(isA<AudioFingerprintFormatError>()),
    );
  });
}

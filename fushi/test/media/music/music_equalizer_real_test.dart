import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart';
import 'package:fushi/src/media/music/music_equalizer.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:media_kit/media_kit.dart';

/// 均衡器对**真 libmpv** 的验收（P5「不达质量就不上线开关」）：
///  * 关：`af` 为空，送出的 PCM 与 FFmpeg 直接解码逐样本相同（bit-perfect 链不受影响）；
///  * 开、1 kHz +6 dB：1 kHz 正弦的电平不变（+6 dB 段 − 6 dB 余量），125 Hz 正弦降 6 dB
///    （只有余量），误差 ≤ 0.3 dB；满幅信号不削波；
///  * 与交叉淡入同时开：逐文件 `af` 里两段都在。
///
/// 需要 `FUSHI_TEST_LIBMPV` 指向 libmpv-2.dll（其 FFmpeg DLL 所在目录在 PATH 里）。
String? _libmpv() {
  final String? v = Platform.environment['FUSHI_TEST_LIBMPV'];
  return v == null || !File(v).existsSync() ? null : v;
}

Future<String> _tone(Directory dir, String name, int freq, double dbfs) async {
  final String out = '${dir.path}${Platform.pathSeparator}$name';
  final double amp = math.pow(10, dbfs / 20).toDouble();
  final FfmpegRunResult r = await resolveFfmpegBackend().run(<String>[
    '-y',
    '-v',
    'error',
    '-f',
    'lavfi',
    '-i',
    "aevalsrc='${amp.toStringAsFixed(6)}*sin(2*PI*$freq*t)':s=44100:d=3",
    '-ac',
    '2',
    '-c:a',
    'flac',
    '-sample_fmt',
    's16',
    out,
  ], const Duration(seconds: 60));
  if (!r.isSuccess) throw StateError('ffmpeg failed: ${r.failureSummary}');
  return out;
}

/// FFmpeg 直接解码成 s16le 立体声（对照组）。
Future<Uint8List> _decode(String path, String out) async {
  final FfmpegRunResult r = await resolveFfmpegBackend().run(<String>[
    '-y',
    '-v',
    'error',
    '-i',
    path,
    '-f',
    's16le',
    '-ac',
    '2',
    '-ar',
    '44100',
    out,
  ], const Duration(seconds: 60));
  if (!r.isSuccess) throw StateError('ffmpeg failed: ${r.failureSummary}');
  return File(out).readAsBytesSync();
}

double _rmsDb(Uint8List pcm, {int skipSamples = 4410}) {
  final Int16List s = pcm.buffer.asInt16List(
    pcm.offsetInBytes,
    pcm.lengthInBytes ~/ 2,
  );
  double sum = 0;
  int n = 0;
  for (int i = skipSamples * 2; i < s.length - skipSamples * 2; i++) {
    final double v = s[i] / 32768;
    sum += v * v;
    n++;
  }
  return 10 * math.log(sum / n) / math.ln10;
}

int _peak(Uint8List pcm) {
  final Int16List s = pcm.buffer.asInt16List(
    pcm.offsetInBytes,
    pcm.lengthInBytes ~/ 2,
  );
  int p = 0;
  for (final int v in s) {
    if (v.abs() > p) p = v.abs();
  }
  return p;
}

Future<Uint8List> _play(
  String file,
  String out,
  MusicEqualizerSettings eq, {
  bool crossfadeFilters = false,
  void Function(String af)? onAf,
}) async {
  final MpvMusicOutputBackend backend = MpvMusicOutputBackend(
    configuration: const PlayerConfiguration(vo: 'null', title: 'eq test'),
    initialProperties: <String, String>{
      'ao': 'pcm',
      'ao-pcm-file': out,
      'ao-pcm-waveheader': 'no',
      'audio-format': 's16',
      'audio-samplerate': '44100',
      'audio-channels': 'stereo',
    },
  );
  final Completer<void> done = Completer<void>();
  final StreamSubscription<MusicBackendEvent> sub = backend.events.listen((
    MusicBackendEvent e,
  ) {
    if (e is MusicBackendCompleted && !done.isCompleted) done.complete();
  });
  try {
    backend.crossfadeFiltersEnabled = crossfadeFilters;
    await backend.applySettings(
      MusicOutputSettings(
        gapless: true,
        replayGain: MusicReplayGainMode.off,
        equalizer: eq,
      ),
    );
    await backend.openPair(
      MusicPlayItem(trackUid: file, path: file, title: 'tone'),
      null,
      play: true,
    );
    if (onAf != null) {
      await backend.debugPlayer.stream.position.firstWhere(
        (Duration p) => p > const Duration(milliseconds: 200),
      );
      onAf(
        await (backend.debugPlayer.platform! as NativePlayer).getPropertyAsync(
          'af',
        ),
      );
    }
    await done.future.timeout(const Duration(seconds: 30));
  } finally {
    await sub.cancel();
    await backend.dispose();
  }
  return File(out).readAsBytesSync();
}

void main() {
  final String? libmpv = _libmpv();
  final String? skip = libmpv == null
      ? 'set FUSHI_TEST_LIBMPV to a libmpv-2.dll'
      : null;
  late Directory dir;
  setUpAll(() {
    if (libmpv != null) MediaKit.ensureInitialized(libmpv: libmpv);
    dir = Directory.systemTemp.createTempSync('music_eq_real_');
  });
  tearDownAll(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // 留给系统清。
    }
  });

  List<double> at(int hz, double g) => <double>[
    for (final int b in kMusicEqualizerBandsHz) b == hz ? g : 0,
  ];

  test(
    '关：逐样本与 FFmpeg 直接解码相同',
    () async {
      final String tone = await _tone(dir, 'k1.flac', 1000, -20);
      final Uint8List ref = await _decode(tone, '${dir.path}/ref.raw');
      final Uint8List out = await _play(
        tone,
        '${dir.path}/off.raw',
        MusicEqualizerSettings(enabled: false, gainsDb: at(1000, 6)),
      );
      expect(out.length, ref.length);
      expect(out, ref);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '开：中心频率按设定、其余只剩余量；满幅不削波',
    () async {
      final MusicEqualizerSettings eq = MusicEqualizerSettings(
        enabled: true,
        gainsDb: at(1000, 6),
      );
      final String k1 = await _tone(dir, 'k1b.flac', 1000, -20);
      final String low = await _tone(dir, 'low.flac', 125, -20);
      final double ref1 = _rmsDb(await _decode(k1, '${dir.path}/k1ref.raw'));
      final double refLow = _rmsDb(
        await _decode(low, '${dir.path}/lowref.raw'),
      );
      final double out1 = _rmsDb(await _play(k1, '${dir.path}/k1eq.raw', eq));
      final double outLow = _rmsDb(
        await _play(low, '${dir.path}/loweq.raw', eq),
      );
      // ignore: avoid_print
      print(
        'EQ 1k +6: 1 kHz ${(out1 - ref1).toStringAsFixed(3)} dB, '
        '125 Hz ${(outLow - refLow).toStringAsFixed(3)} dB',
      );
      expect(out1 - ref1, closeTo(0, 0.3));
      expect(outLow - refLow, closeTo(-6, 0.3));

      final String loud = await _tone(dir, 'loud.flac', 1000, -0.1);
      final Uint8List loudOut = await _play(loud, '${dir.path}/loud.raw', eq);
      expect(_peak(loudOut), lessThan(32767));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    '与交叉淡入同开：逐文件 af 里均衡器与淡入淡出都在',
    () async {
      final String k1 = await _tone(dir, 'k1c.flac', 1000, -20);
      String? af;
      await _play(
        k1,
        '${dir.path}/xf.raw',
        MusicEqualizerSettings(enabled: true, gainsDb: at(1000, 3)),
        crossfadeFilters: true,
        onAf: (String v) => af = v,
      );
      expect(af, contains('@$kMusicEqualizerLabel:'));
      expect(af, contains('afade'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

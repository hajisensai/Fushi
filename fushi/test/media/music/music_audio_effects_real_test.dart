import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart';
import 'package:fushi/src/media/music/music_audio_effects.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:media_kit/media_kit.dart';

/// 音效对**真 libmpv** 的验收（P5「不达质量就不上线开关」）：
///  * 关、或开着但全部中性（含单开限幅器）：`af` 为空，送出的 PCM 与 FFmpeg 直接解码逐样本
///    相同（bit-perfect 链不受影响）；
///  * 开、1 kHz +6 dB：1 kHz 正弦的电平不变（+6 dB 段 − 6 dB 余量），125 Hz 正弦降 6 dB
///    （只有余量），误差 ≤ 0.3 dB；满幅信号不削波；
///  * 全部效果同开（pan / volume / bass / treble / equalizer / alimiter）：这台 libmpv 的
///    FFmpeg 认得整条链、正常出声且不削波；平衡推满一侧时另一侧全零；
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
  MusicAudioEffects eq, {
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
        effects: eq,
      ),
    );
    // 读逐文件 `af` 要在文件还加载着的时候：先暂停着打开（on_load 钩子照样跑），等时长报上来
    // （文件已加载）再读，然后才开播。`ao=pcm` 不按实时送数据，边播边等位置会和「已经
    // 播完卸载」赛跑。
    await backend.openPair(
      MusicPlayItem(trackUid: file, path: file, title: 'tone'),
      null,
      play: onAf == null,
    );
    if (onAf != null) {
      await backend.debugPlayer.stream.duration
          .firstWhere((Duration d) => d > Duration.zero)
          .timeout(const Duration(seconds: 15));
      onAf(
        await (backend.debugPlayer.platform! as NativePlayer).getPropertyAsync(
          'af',
        ),
      );
      await backend.play();
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
    dir = Directory.systemTemp.createTempSync('music_fx_real_');
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
        MusicAudioEffects(enabled: false, gainsDb: at(1000, 6)),
      );
      expect(out.length, ref.length);
      expect(out, ref);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '开着但全部中性（含单开限幅器）：逐样本与 FFmpeg 直接解码相同',
    () async {
      final String tone = await _tone(dir, 'k1n.flac', 1000, -20);
      final Uint8List ref = await _decode(tone, '${dir.path}/refn.raw');
      final Uint8List out = await _play(
        tone,
        '${dir.path}/neutral.raw',
        const MusicAudioEffects(
          enabled: true,
          limiter: true,
          bassHz: 60,
          trebleHz: 12000,
        ),
      );
      expect(out.length, ref.length);
      expect(out, ref);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '全部效果同开：整条链被这台 libmpv 接受、出声、不削波；平衡推满一侧另一侧静音',
    () async {
      final String loud = await _tone(dir, 'allfx.flac', 1000, -0.1);
      final MusicAudioEffects fx = MusicAudioEffects(
        enabled: true,
        gainsDb: at(1000, 6),
        preampDb: 3,
        bassDb: 4,
        trebleDb: 2,
        balance: 0.1,
        width: 1.5,
        limiter: true,
      );
      final String af = musicAudioEffectsAf(fx)!;
      for (final String f in <String>[
        'pan=',
        'volume=',
        'bass=',
        'treble=',
        'equalizer=',
        'alimiter=',
      ]) {
        expect(af, contains(f));
      }
      String? applied;
      final Uint8List out = await _play(
        loud,
        '${dir.path}/allfx.raw',
        fx,
        onAf: (String v) => applied = v,
      );
      expect(applied, contains('@$kMusicEffectsLabel:'));
      final double ref = _rmsDb(await _decode(loud, '${dir.path}/allref.raw'));
      // 出声（滤镜图没被拒成静音）且被限幅器压在满幅以下。
      expect(_rmsDb(out), greaterThan(ref - 12));
      expect(_peak(out), lessThan(32767));

      // 平衡推到最右：pan 矩阵真的作用到声道上——左声道全零、右声道照常。
      final String tone = await _tone(dir, 'bal.flac', 440, -12);
      final Uint8List bal = await _play(
        tone,
        '${dir.path}/bal.raw',
        const MusicAudioEffects(enabled: true, balance: 1),
      );
      final Int16List s = bal.buffer.asInt16List(
        bal.offsetInBytes,
        bal.lengthInBytes ~/ 2,
      );
      int leftPeak = 0;
      int rightPeak = 0;
      for (int i = 0; i + 1 < s.length; i += 2) {
        leftPeak = math.max(leftPeak, s[i].abs());
        rightPeak = math.max(rightPeak, s[i + 1].abs());
      }
      expect(leftPeak, 0);
      expect(rightPeak, greaterThan(1000));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    '开：中心频率按设定、其余只剩余量；满幅不削波',
    () async {
      final MusicAudioEffects eq = MusicAudioEffects(
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
        MusicAudioEffects(enabled: true, gainsDb: at(1000, 3)),
        crossfadeFilters: true,
        onAf: (String v) => af = v,
      );
      expect(af, contains('@$kMusicEffectsLabel:'));
      expect(af, contains('afade'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

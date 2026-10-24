import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart';
import 'package:fushi/src/media/music/music_crossfade.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:media_kit/media_kit.dart';

/// 交叉淡入对**真 libmpv** 的验证（设计 §7.2；质量门槛见 PR 说明）：
///
/// * 样本级：`ao=pcm` 把两个实例各自的输出写成 WAV，逐样本比对等功率曲线
///   `cos/sin(πt/2)`、平方和恒 1、叠加后无阶跃；音乐内容上逐样本等于「增益 × 源」。
/// * 实时：`ao=null`（计时的空输出，与真设备一样按墙钟消耗缓冲、发 `audio-pts`）跑完整
///   调度——预加载、按出声时刻启动、Advanced 时刻、两路对齐误差、重叠期各操作、实例释放。
/// * 回归：交叉淡入关闭、以及开着但衔接是 CUE 拆轨（不淡入）时，输出与整轨逐样本一致。
/// * 真声卡（`FUSHI_TEST_MUSIC_XF_WASAPI=1`，Windows，数字静音不出可闻声）：WASAPI 共享
///   模式下的对齐误差与 CPU / 内存增量。
///
/// 需要真实 libmpv：`FUSHI_TEST_LIBMPV` 指向 libmpv-2.dll（其 FFmpeg DLL 所在目录在 PATH 里）。
String? _libmpvPath() {
  final String? override = Platform.environment['FUSHI_TEST_LIBMPV'];
  final String path = override ?? 'build/windows/x64/runner/Debug/libmpv-2.dll';
  return File(path).existsSync() ? File(path).absolute.path : null;
}

Future<String> _gen(Directory dir, String name, List<String> args) async {
  final String out = '${dir.path}${Platform.pathSeparator}$name';
  final FfmpegRunResult r = await resolveFfmpegBackend().run(<String>[
    '-y',
    ...args,
    out,
  ], const Duration(seconds: 60));
  if (!r.isSuccess) throw StateError('ffmpeg failed: ${r.failureSummary}');
  return out;
}

/// 立体声常数（DC）源：输出样本 / 振幅 = 当时的增益，逐样本读出曲线。
Future<String> _dc(Directory dir, String name, double seconds) =>
    _gen(dir, name, <String>[
      '-f',
      'lavfi',
      '-i',
      'aevalsrc=0.5|0.5:s=44100:d=$seconds',
      '-c:a',
      'flac',
      '-sample_fmt',
      's32',
      '-bits_per_raw_sample',
      '24',
    ]);

Future<String> _tone(
  Directory dir,
  String name,
  double seconds,
  int freq,
) => _gen(dir, name, <String>[
  '-f',
  'lavfi',
  '-i',
  'sine=frequency=$freq:sample_rate=44100:duration=$seconds',
  '-ac',
  '2',
  '-c:a',
  'flac',
  '-sample_fmt',
  's32',
  '-bits_per_raw_sample',
  '24',
]);

/// WAV（float / s16 / s32，含 EXTENSIBLE）→ 第一声道样本。
Float64List _readWavCh0(String path) {
  final Uint8List bytes = File(path).readAsBytesSync();
  final ByteData bd = bytes.buffer.asByteData();
  int off = 12;
  int fmt = 0, channels = 0, bits = 0;
  while (off + 8 <= bytes.length) {
    final String id = String.fromCharCodes(bytes.sublist(off, off + 4));
    int len = bd.getUint32(off + 4, Endian.little);
    final int body = off + 8;
    if (id == 'fmt ') {
      fmt = bd.getUint16(body, Endian.little);
      channels = bd.getUint16(body + 2, Endian.little);
      bits = bd.getUint16(body + 14, Endian.little);
      if (fmt == 0xFFFE) fmt = bd.getUint16(body + 24, Endian.little);
    } else if (id == 'data') {
      if (len == 0 || body + len > bytes.length) len = bytes.length - body;
      final int frame = channels * bits ~/ 8;
      final int n = len ~/ frame;
      final Float64List out = Float64List(n);
      for (int i = 0; i < n; i++) {
        final int p = body + i * frame;
        if (fmt == 3 && bits == 32) {
          out[i] = bd.getFloat32(p, Endian.little);
        } else if (fmt == 1 && bits == 16) {
          out[i] = bd.getInt16(p, Endian.little) / 32768;
        } else if (fmt == 1 && bits == 32) {
          out[i] = bd.getInt32(p, Endian.little) / 2147483648;
        } else {
          throw StateError('unsupported wav fmt=$fmt bits=$bits');
        }
      }
      return out;
    }
    off = body + len + (len.isOdd ? 1 : 0);
  }
  throw StateError('no data chunk in $path');
}

MusicPlayItem _item(
  String uid,
  String path, {
  required int durationMs,
  String? album,
  int? trackNo,
  int? startMs,
  int? endMs,
  double? rgTrackGain,
}) => MusicPlayItem(
  trackUid: uid,
  path: path,
  title: uid,
  albumUid: album,
  trackNo: trackNo,
  startMs: startMs,
  endMs: endMs,
  durationMs: durationMs,
  rgTrackGain: rgTrackGain,
);

/// 收集后端事件（带墙钟）。
class _Recorder {
  _Recorder(Stream<MusicBackendEvent> events) {
    _sub = events.listen((MusicBackendEvent e) {
      events_.add((at: clock.elapsedMicroseconds, event: e));
    });
  }

  final Stopwatch clock = Stopwatch()..start();
  final List<({int at, MusicBackendEvent event})> events_ =
      <({int at, MusicBackendEvent event})>[];
  late final StreamSubscription<MusicBackendEvent> _sub;

  int count<T extends MusicBackendEvent>() =>
      events_.where((e) => e.event is T).length;

  Future<void> waitFor(
    bool Function() done, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final Stopwatch sw = Stopwatch()..start();
    while (!done()) {
      if (sw.elapsed > timeout) {
        throw TimeoutException(
          'condition not met; events: '
          '${events_.where((e) => e.event is! MusicBackendPosition).map((e) => '${e.at ~/ 1000}:${e.event.runtimeType}').toList()}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> cancel() => _sub.cancel();
}

/// 测试工厂：记住造出来的每个实例。
class _Instances {
  _Instances(this.make);

  final MpvMusicOutputBackend Function(int index) make;
  final List<MpvMusicOutputBackend> created = <MpvMusicOutputBackend>[];

  MpvMusicOutputBackend call() {
    final MpvMusicOutputBackend b = make(created.length);
    created.add(b);
    return b;
  }
}

MpvMusicOutputBackend _nullAo(int _) => MpvMusicOutputBackend(
  configuration: const PlayerConfiguration(
    vo: 'null',
    title: 'Fushi Music xf test',
  ),
  initialProperties: const <String, String>{'ao': 'null'},
  platform: MusicOutputPlatform.windows,
);

const MusicOutputSettings _xf = MusicOutputSettings(
  gapless: true,
  replayGain: MusicReplayGainMode.off,
  crossfade: Duration(seconds: 2),
);

double _cosFade(int n, int start, int len) {
  if (n < start) return 1;
  if (n >= start + len) return 0;
  return math.cos(math.pi / 2 * (n - start) / len);
}

double _sinFade(int n, int len) {
  if (n < 0) return 0;
  if (n >= len) return 1;
  return math.sin(math.pi / 2 * n / len);
}

void main() {
  final String? libmpv = _libmpvPath();
  final String? skip = libmpv == null
      ? 'Build Windows Debug or set FUSHI_TEST_LIBMPV to libmpv-2.dll'
      : null;
  final String? wasapiSkip =
      skip ??
      (!Platform.isWindows ||
              Platform.environment['FUSHI_TEST_MUSIC_XF_WASAPI'] != '1'
          ? 'set FUSHI_TEST_MUSIC_XF_WASAPI=1 (Windows) to run on the real '
                'default device (digital silence)'
          : null);
  late Directory dir;
  late String dcA;
  late String dcB;
  late String toneA;
  late String toneB;
  late String full;
  late String longA;
  late String longB;
  late String silenceA;
  late String silenceB;

  setUpAll(() async {
    if (libmpv == null) return;
    MediaKit.ensureInitialized(libmpv: libmpv);
    dir = Directory.systemTemp.createTempSync('fushi_music_xf_');
    dcA = await _dc(dir, 'dcA.flac', 6);
    dcB = await _dc(dir, 'dcB.flac', 6);
    toneA = await _tone(dir, 'toneA.flac', 6, 440);
    toneB = await _tone(dir, 'toneB.flac', 6, 661);
    full = await _tone(dir, 'full.flac', 6, 330);
    longA = await _tone(dir, 'longA.flac', 9, 440);
    longB = await _tone(dir, 'longB.flac', 9, 661);
    silenceA = await _gen(dir, 'silA.flac', <String>[
      '-f',
      'lavfi',
      '-i',
      'anullsrc=r=44100:cl=stereo',
      '-t',
      '9',
      '-c:a',
      'flac',
    ]);
    silenceB = await _gen(dir, 'silB.flac', <String>[
      '-f',
      'lavfi',
      '-i',
      'anullsrc=r=44100:cl=stereo',
      '-t',
      '9',
      '-c:a',
      'flac',
    ]);
  });
  tearDownAll(() {
    if (libmpv != null) dir.deleteSync(recursive: true);
  });

  /// 用 ao=pcm 把交叉淡入两路各自写成 WAV：主实例 0 = 前一首，实例 1 = 后一首。
  /// `ao=pcm` 不实时、不发 `audio-pts`，所以用 [MusicCrossfadeBackend.debugArmAt] 在开播前
  /// 排淡出；前一首放完后由「放完仍未启动 → 立刻接上」路径启动后一首。样本内容只取决于
  /// 滤镜配置，与两路的墙钟对齐无关（对齐由实时用例单独量）。
  Future<(Float64List, Float64List, MusicCrossfadeTiming)> renderPair(
    String name,
    MusicPlayItem from,
    MusicPlayItem to, {
    MusicOutputSettings settings = _xf,
  }) async {
    final List<String> wavs = <String>[];
    final _Instances instances = _Instances((int i) {
      final String wav = '${dir.path}${Platform.pathSeparator}${name}_$i.wav';
      wavs.add(wav);
      return MpvMusicOutputBackend(
        configuration: const PlayerConfiguration(
          vo: 'null',
          title: 'Fushi Music xf pcm',
        ),
        initialProperties: <String, String>{
          'ao': 'pcm',
          'ao-pcm-file': wav,
          'ao-pcm-waveheader': 'yes',
          'audio-format': 'float',
        },
        platform: MusicOutputPlatform.windows,
      );
    });
    final MusicCrossfadeBackend xf = MusicCrossfadeBackend(
      instanceFactory: instances.call,
      platform: MusicOutputPlatform.windows,
    );
    final _Recorder rec = _Recorder(xf.events);
    late final MusicCrossfadeTiming timing;
    try {
      await xf.applySettings(settings);
      await xf.openPair(from, to, play: false, crossfadeNext: true);
      final MpvMusicOutputBackend a = instances.created.first;
      final Stopwatch sw = Stopwatch()..start();
      while (a.audibleMediaDuration == null ||
          a.debugPlayer.state.duration <= Duration.zero) {
        if (sw.elapsed > const Duration(seconds: 10)) {
          throw TimeoutException('duration never known');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await xf.debugArmAt(0);
      timing = xf.debugPlannedTiming!;
      await xf.play();
      await rec.waitFor(() => rec.count<MusicBackendAdvanced>() >= 1);
      await rec.waitFor(() => rec.count<MusicBackendCompleted>() >= 1);
    } finally {
      await rec.cancel();
      await xf.dispose();
    }
    expect(wavs.length, 2, reason: '两路各一个实例');
    return (_readWavCh0(wavs[0]), _readWavCh0(wavs[1]), timing);
  }

  test(
    '样本级：等功率曲线（cos/sin，平方和恒 1），两路叠加无阶跃',
    () async {
      final (Float64List a, Float64List b, MusicCrossfadeTiming timing) =
          await renderPair(
            'dc',
            _item('a', dcA, durationMs: 6000, album: 'x'),
            _item('b', dcB, durationMs: 6000, album: 'y'),
          );
      const int sr = 44100;
      final int start = (timing.fadeStart.inMicroseconds * sr / 1e6).round();
      final int len = (timing.fadeLength.inMicroseconds * sr / 1e6).round();
      expect(timing.fadeLength, const Duration(seconds: 2));
      expect(a.length, 6 * sr, reason: '前一首完整放完（淡出后是静音，不截断）');
      expect(b.length, 6 * sr);
      double errA = 0, errB = 0, stepA = 0, stepB = 0;
      for (int n = 0; n < a.length; n++) {
        errA = math.max(errA, (a[n] / 0.5 - _cosFade(n, start, len)).abs());
        if (n > 0) stepA = math.max(stepA, (a[n] - a[n - 1]).abs());
      }
      for (int n = 0; n < b.length; n++) {
        errB = math.max(errB, (b[n] / 0.5 - _sinFade(n, len)).abs());
        if (n > 0) stepB = math.max(stepB, (b[n] - b[n - 1]).abs());
      }
      // 理想对齐（后一首第 0 个样本 = 前一首淡出起点）下的叠加。
      double powerDev = 0, sumStep = 0;
      double prev = a[0];
      for (int n = 1; n < start + len + sr; n++) {
        final double ga = a[n] / 0.5;
        final double gb = n - start >= 0 && n - start < b.length
            ? b[n - start] / 0.5
            : 0;
        powerDev = math.max(powerDev, (ga * ga + gb * gb - 1).abs());
        final double s = a[n] + (n - start >= 0 ? b[n - start] : 0);
        sumStep = math.max(sumStep, (s - prev).abs());
        prev = s;
      }
      // 实测设备对齐误差（见 WASAPI 用例：中位 ~20 ms，最差 ~40 ms）下的功率起伏。
      final Map<int, double> devByOffsetMs = <int, double>{};
      for (final int ms in <int>[10, 20, 40, 80]) {
        final int d = sr * ms ~/ 1000;
        double lo = double.infinity, hi = 0;
        for (int n = start; n < start + len + d; n++) {
          final double ga = a[n] / 0.5;
          final int m = n - start - d;
          final double gb = m >= 0 && m < b.length ? b[m] / 0.5 : 0;
          final double p = ga * ga + gb * gb;
          lo = math.min(lo, p);
          hi = math.max(hi, p);
        }
        devByOffsetMs[ms] = 10 * math.log(lo) / math.ln10;
      }
      // ignore: avoid_print
      print(
        '[xf-dc] fadeStart=${timing.fadeStart.inMicroseconds / 1e6}s '
        'len=${timing.fadeLength.inMicroseconds / 1e6}s '
        'curveErr out=${errA.toStringAsExponential(2)} in=${errB.toStringAsExponential(2)} '
        'maxStep out=${stepA.toStringAsExponential(3)} in=${stepB.toStringAsExponential(3)} '
        'sum: powerDev=${powerDev.toStringAsExponential(2)} '
        'maxStep=${sumStep.toStringAsExponential(3)} '
        '(smooth-curve bound=${(0.5 * math.pi / 2 / len * math.sqrt2).toStringAsExponential(3)}) '
        'misaligned worst dip dB=${devByOffsetMs.map((int k, double v) => MapEntry<int, String>(k, v.toStringAsFixed(3)))}',
      );
      expect(errA, lessThan(1e-6));
      expect(errB, lessThan(1e-6));
      expect(powerDev, lessThan(1e-6), reason: '等功率：cos² + sin² = 1');
      // 曲线最陡处每样本增益变化 = (π/2)/len；叠加后的阶跃不超过它（乘振幅、两路合计）。
      expect(sumStep, lessThanOrEqualTo(0.5 * math.pi / 2 / len * math.sqrt2));
      expect(devByOffsetMs[40]!, greaterThan(-0.3), reason: '40 ms 错位功率凹陷 < 0.3 dB');
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    '样本级：音乐内容上两路输出逐样本 = 增益曲线 × 源（滤镜之外不改样本）',
    () async {
      final (Float64List a, Float64List b, MusicCrossfadeTiming timing) =
          await renderPair(
            'tone',
            _item('a', toneA, durationMs: 6000, album: 'x'),
            _item('b', toneB, durationMs: 6000, album: 'y'),
          );
      // 源的直接解码（无交叉淡入，单实例 ao=pcm）。
      Future<Float64List> plain(String path, String name) async {
        final String wav = '${dir.path}${Platform.pathSeparator}$name.wav';
        final MpvMusicOutputBackend p = MpvMusicOutputBackend(
          configuration: const PlayerConfiguration(
            vo: 'null',
            title: 'Fushi Music xf ref',
          ),
          initialProperties: <String, String>{
            'ao': 'pcm',
            'ao-pcm-file': wav,
            'ao-pcm-waveheader': 'yes',
            'audio-format': 'float',
          },
        );
        final _Recorder rec = _Recorder(p.events);
        try {
          await p.applySettings(_xf.copyWith(crossfade: Duration.zero));
          await p.openPair(_item('r', path, durationMs: 6000), null, play: true);
          await rec.waitFor(() => rec.count<MusicBackendCompleted>() >= 1);
        } finally {
          await rec.cancel();
          await p.dispose();
        }
        return _readWavCh0(wav);
      }

      final Float64List srcA = await plain(toneA, 'refA');
      final Float64List srcB = await plain(toneB, 'refB');
      const int sr = 44100;
      final int start = (timing.fadeStart.inMicroseconds * sr / 1e6).round();
      final int len = (timing.fadeLength.inMicroseconds * sr / 1e6).round();
      double errA = 0, errB = 0;
      for (int n = 0; n < a.length; n++) {
        errA = math.max(
          errA,
          (a[n] - srcA[n] * _cosFade(n, start, len)).abs(),
        );
      }
      for (int n = 0; n < b.length; n++) {
        errB = math.max(errB, (b[n] - srcB[n] * _sinFade(n, len)).abs());
      }
      // ignore: avoid_print
      print(
        '[xf-tone] samples a=${a.length} b=${b.length} '
        'max|out - gain·src| a=${errA.toStringAsExponential(2)} '
        'b=${errB.toStringAsExponential(2)}',
      );
      expect(a.length, srcA.length);
      expect(b.length, srcB.length);
      expect(errA, lessThan(1e-6));
      expect(errB, lessThan(1e-6));
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 90)),
  );

  Future<String> md5Of(String path) async {
    final String out = '$path.md5';
    final FfmpegRunResult r = await resolveFfmpegBackend().run(<String>[
      '-y',
      '-hide_banner',
      '-i',
      path,
      '-map',
      '0:a',
      '-c:a',
      'pcm_s16le',
      '-f',
      'md5',
      out,
    ], const Duration(seconds: 60));
    if (!r.isSuccess) throw StateError('md5 failed: ${r.failureSummary}');
    return File(out).readAsStringSync().trim();
  }

  for (final Duration crossfade in <Duration>[
    Duration.zero,
    const Duration(seconds: 2),
  ]) {
    test(
      '回归：CUE 拆轨经交叉淡入后端（crossfade=${crossfade.inSeconds}s），'
      '两段输出与整轨逐样本一致',
      () async {
        final String wav =
            '${dir.path}${Platform.pathSeparator}cue_${crossfade.inSeconds}.wav';
        final _Instances instances = _Instances(
          (int i) => MpvMusicOutputBackend(
            configuration: const PlayerConfiguration(
              vo: 'null',
              title: 'Fushi Music xf cue',
            ),
            initialProperties: <String, String>{
              'ao': 'pcm',
              'ao-pcm-file': wav,
              'ao-pcm-waveheader': 'yes',
            },
            platform: MusicOutputPlatform.windows,
          ),
        );
        final MusicCrossfadeBackend xf = MusicCrossfadeBackend(
          instanceFactory: instances.call,
          platform: MusicOutputPlatform.windows,
        );
        // 引擎判衔接：同一整轨、段首尾相接 → 不是边界 → crossfadeNext=false。
        final MusicPlayItem t1 = _item(
          't1',
          full,
          durationMs: 3000,
          album: 'cue',
          startMs: 0,
          endMs: 3000,
        );
        final MusicPlayItem t2 = _item(
          't2',
          full,
          durationMs: 3000,
          album: 'cue',
          startMs: 3000,
        );
        expect(
          musicTransitionCrossfades(
            t1,
            t2,
            albumOrder: true,
            includeContinuous: false,
          ),
          isFalse,
        );
        final _Recorder rec = _Recorder(xf.events);
        try {
          await xf.applySettings(_xf.copyWith(crossfade: crossfade));
          await xf.openPair(t1, t2, play: true);
          await rec.waitFor(() => rec.count<MusicBackendAdvanced>() >= 1);
          await xf.replaceNext(null);
          await rec.waitFor(() => rec.count<MusicBackendCompleted>() >= 1);
          final String af = await (instances.created.first.debugPlayer.platform!
                  as NativePlayer)
              .getPropertyAsync('af');
          // ignore: avoid_print
          print('[xf-cue ${crossfade.inSeconds}s] af="$af"');
        } finally {
          await rec.cancel();
          await xf.dispose();
        }
        expect(instances.created.length, 1, reason: '不淡入的衔接不建第二个实例');
        expect(await md5Of(wav), await md5Of(full));
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }

  test(
    '回归：交叉淡入关闭时两首 gapless，输出 = 两首源逐样本拼接，`af` 从不设置',
    () async {
      final String wav = '${dir.path}${Platform.pathSeparator}off_pair.wav';
      final _Instances instances = _Instances(
        (int i) => MpvMusicOutputBackend(
          configuration: const PlayerConfiguration(
            vo: 'null',
            title: 'Fushi Music xf off',
          ),
          initialProperties: <String, String>{
            'ao': 'pcm',
            'ao-pcm-file': wav,
            'ao-pcm-waveheader': 'yes',
          },
          platform: MusicOutputPlatform.windows,
        ),
      );
      final MusicCrossfadeBackend xf = MusicCrossfadeBackend(
        instanceFactory: instances.call,
        platform: MusicOutputPlatform.windows,
      );
      final _Recorder rec = _Recorder(xf.events);
      try {
        await xf.applySettings(_xf.copyWith(crossfade: Duration.zero));
        // 引擎在关闭时恒给 false；这里故意给 true，后端也必须忽略。
        await xf.openPair(
          _item('a', toneA, durationMs: 6000, album: 'x'),
          _item('b', toneB, durationMs: 6000, album: 'y'),
          play: true,
          crossfadeNext: true,
        );
        await rec.waitFor(() => rec.count<MusicBackendAdvanced>() >= 1);
        await xf.replaceNext(null, crossfadeNext: true);
        await rec.waitFor(() => rec.count<MusicBackendCompleted>() >= 1);
        expect(
          await (instances.created.first.debugPlayer.platform! as NativePlayer)
              .getPropertyAsync('af'),
          isEmpty,
        );
      } finally {
        await rec.cancel();
        await xf.dispose();
      }
      expect(instances.created.length, 1);
      final String concat = await _gen(dir, 'concat.flac', <String>[
        '-i',
        toneA,
        '-i',
        toneB,
        '-filter_complex',
        '[0:a][1:a]concat=n=2:v=0:a=1',
        '-c:a',
        'flac',
        '-sample_fmt',
        's32',
      ]);
      expect(await md5Of(wav), await md5Of(concat));
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  /// 实时调度：A（9 s）→ B（9 s），交叉淡入 3 s。
  Future<
    ({
      MusicCrossfadeBackend xf,
      _Instances instances,
      _Recorder rec,
      int advanceAtUs,
      int idealAtUs,
    })
  >
  runToOverlap({
    required MpvMusicOutputBackend Function(int) make,
    required String a,
    required String b,
    MusicOutputSettings settings = const MusicOutputSettings(
      gapless: true,
      replayGain: MusicReplayGainMode.off,
      crossfade: Duration(seconds: 3),
    ),
    MusicPlayItem? itemA,
    MusicPlayItem? itemB,
  }) async {
    final _Instances instances = _Instances(make);
    final MusicCrossfadeBackend xf = MusicCrossfadeBackend(
      instanceFactory: instances.call,
      platform: MusicOutputPlatform.windows,
    );
    final _Recorder rec = _Recorder(xf.events);
    await xf.applySettings(settings);
    await xf.openPair(
      itemA ?? _item('a', a, durationMs: 9000, album: 'x'),
      itemB ?? _item('b', b, durationMs: 9000, album: 'y'),
      play: true,
      crossfadeNext: true,
    );
    // 真值：前一首出声位置到达淡出起点的墙钟时刻（用 A 的位置事件外推）。
    await rec.waitFor(
      () => rec.count<MusicBackendAdvanced>() >= 1,
      timeout: const Duration(seconds: 20),
    );
    final int advIdx = rec.events_.indexWhere(
      (e) => e.event is MusicBackendAdvanced,
    );
    final MusicCrossfadeTiming? timing = xf.debugLastStartedTiming;
    final ({int at, MusicBackendEvent event}) lastPos = rec.events_
        .sublist(0, advIdx)
        .lastWhere((e) => e.event is MusicBackendPosition);
    final Duration p = (lastPos.event as MusicBackendPosition).position;
    final int ideal =
        lastPos.at +
        ((timing!.fadeStart - p).inMicroseconds / settings.speed).round();
    return (
      xf: xf,
      instances: instances,
      rec: rec,
      advanceAtUs: rec.events_[advIdx].at,
      idealAtUs: ideal,
    );
  }

  test(
    '实时（ao=null）：预加载 → 按出声时刻启动 → Advanced → 前一首淡完释放第二实例',
    () async {
      final ({
        MusicCrossfadeBackend xf,
        _Instances instances,
        _Recorder rec,
        int advanceAtUs,
        int idealAtUs,
      })
      r = await runToOverlap(make: _nullAo, a: longA, b: longB);
      try {
        expect(r.instances.created.length, 2);
        expect(r.xf.debugOverlapping, isTrue);
        final MusicBackendAdvanced adv =
            r.rec.events_
                    .firstWhere((e) => e.event is MusicBackendAdvanced)
                    .event
                as MusicBackendAdvanced;
        expect(adv.trackUid, 'b');
        // 重叠结束：前一首放完，第二个实例释放。
        await r.rec.waitFor(
          () => !r.xf.debugOverlapping,
          timeout: const Duration(seconds: 10),
        );
        expect(r.xf.debugInstanceCount, 1);
        final List<double> offsets = r.xf.debugLastOverlapOffsetsMs;
        final List<double> sorted = List<double>.of(offsets)..sort();
        // ignore: avoid_print
        print(
          '[xf-rt null] advanced-vs-ideal='
          '${((r.advanceAtUs - r.idealAtUs) / 1000).toStringAsFixed(1)}ms '
          'overlap offsets n=${offsets.length} '
          'median=${sorted.isEmpty ? '-' : sorted[sorted.length ~/ 2].toStringAsFixed(1)}ms '
          'max|.|=${offsets.isEmpty ? '-' : offsets.map((double x) => x.abs()).reduce(math.max).toStringAsFixed(1)}ms',
        );
        expect(offsets, isNotEmpty);
        expect(sorted[sorted.length ~/ 2].abs(), lessThan(40));
        // 位置事件：前一首到淡出起点附近，之后是后一首、从 0 起单调。
        final int advIdx = r.rec.events_.indexWhere(
          (e) => e.event is MusicBackendAdvanced,
        );
        final List<Duration> after = <Duration>[
          for (final e in r.rec.events_.skip(advIdx + 1))
            if (e.event is MusicBackendPosition)
              (e.event as MusicBackendPosition).position,
        ];
        expect(after.first, lessThan(const Duration(milliseconds: 500)));
        for (int i = 1; i < after.length; i++) {
          expect(after[i] >= after[i - 1], isTrue, reason: '$after');
        }
        await r.xf.replaceNext(null);
        await r.rec.waitFor(
          () => r.rec.count<MusicBackendCompleted>() >= 1,
          timeout: const Duration(seconds: 15),
        );
        expect(r.rec.count<MusicBackendAdvanced>(), 1);
      } finally {
        await r.rec.cancel();
        await r.xf.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    '实时：重叠期内 ReplayGain 两路各用各的曲目增益；暂停 = 前一首立即停、当前曲暂停',
    () async {
      final ({
        MusicCrossfadeBackend xf,
        _Instances instances,
        _Recorder rec,
        int advanceAtUs,
        int idealAtUs,
      })
      r = await runToOverlap(
        make: _nullAo,
        a: longA,
        b: longB,
        settings: const MusicOutputSettings(
          gapless: true,
          replayGain: MusicReplayGainMode.track,
          crossfade: Duration(seconds: 3),
        ),
        itemA: _item('a', longA, durationMs: 9000, album: 'x', rgTrackGain: -4),
        itemB: _item('b', longB, durationMs: 9000, album: 'y', rgTrackGain: -1),
      );
      try {
        expect(r.xf.debugOverlapping, isTrue);
        final NativePlayer na =
            r.instances.created[0].debugPlayer.platform! as NativePlayer;
        final NativePlayer nb =
            r.instances.created[1].debugPlayer.platform! as NativePlayer;
        expect(double.parse(await na.getPropertyAsync('volume-gain')), -4);
        expect(double.parse(await nb.getPropertyAsync('volume-gain')), -1);
        await r.xf.pause();
        expect(r.xf.debugOverlapping, isFalse);
        expect(r.xf.debugInstanceCount, 1);
        expect(await nb.getPropertyAsync('pause'), 'yes');
        await r.xf.play();
        expect(await nb.getPropertyAsync('pause'), 'no');
      } finally {
        await r.rec.cancel();
        await r.xf.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    '实时：重叠期内 seek / 变速 → 前一首立即停，操作作用于当前曲（后一首）',
    () async {
      for (final String op in <String>['seek', 'speed']) {
        final ({
          MusicCrossfadeBackend xf,
          _Instances instances,
          _Recorder rec,
          int advanceAtUs,
          int idealAtUs,
        })
        r = await runToOverlap(make: _nullAo, a: longA, b: longB);
        try {
          expect(r.xf.debugOverlapping, isTrue);
          final MpvMusicOutputBackend b = r.instances.created[1];
          if (op == 'seek') {
            await r.xf.seek(const Duration(seconds: 5));
            expect(r.xf.debugOverlapping, isFalse);
            await Future<void>.delayed(const Duration(milliseconds: 200));
            expect(
              b.debugPlayer.state.position,
              greaterThan(const Duration(milliseconds: 4900)),
            );
          } else {
            await r.xf.applySettings(
              const MusicOutputSettings(
                gapless: true,
                replayGain: MusicReplayGainMode.off,
                crossfade: Duration(seconds: 3),
                speed: 1.25,
              ),
            );
            expect(r.xf.debugOverlapping, isFalse);
            expect(
              double.parse(
                await (b.debugPlayer.platform! as NativePlayer)
                    .getPropertyAsync('speed'),
              ),
              closeTo(1.25, 1e-6),
            );
          }
          expect(r.xf.debugInstanceCount, 1, reason: op);
        } finally {
          await r.rec.cancel();
          await r.xf.dispose();
        }
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '实时 + 引擎：跳曲 / 上一首 / 睡眠定时在重叠期内的行为',
    () async {
      for (final String op in <String>['skipNext', 'previous', 'sleep']) {
        final _Instances instances = _Instances(_nullAo);
        final MusicPlayerEngine engine = MusicPlayerEngine(
          backendFactory: () => MusicCrossfadeBackend(
            instanceFactory: instances.call,
            platform: MusicOutputPlatform.windows,
          ),
          replayGainEnabled: () => false,
          baseSettings: () => const MusicOutputSettings(
            gapless: true,
            replayGain: MusicReplayGainMode.off,
            crossfade: Duration(seconds: 3),
          ),
        );
        final List<String> started = <String>[];
        engine.onTrackStarted = (MusicPlayItem i) => started.add(i.trackUid);
        try {
          await engine.playQueue(<MusicPlayItem>[
            _item('a', longA, durationMs: 9000, album: 'x'),
            _item('b', longB, durationMs: 9000, album: 'y'),
            _item('c', longA, durationMs: 9000, album: 'z'),
          ]);
          final Stopwatch sw = Stopwatch()..start();
          while (started.length < 2 && sw.elapsed < const Duration(seconds: 15)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(started, <String>['a', 'b']);
          expect(engine.current?.trackUid, 'b', reason: '淡入开始即算换曲');
          expect(instances.created.length, 2);
          switch (op) {
            case 'skipNext':
              await engine.skipNext();
              expect(engine.current?.trackUid, 'c');
              expect(started.last, 'c');
            case 'previous':
              // 刚开始淡入（< 3 s）：退到上一首。
              await engine.skipPrevious();
              expect(engine.current?.trackUid, 'a');
            case 'sleep':
              await engine.setStopAfterCurrent(true);
              // 前一首继续淡完；当前曲（b）播完即停，不再预排 c。
              final Stopwatch end = Stopwatch()..start();
              while (engine.isPlaying &&
                  end.elapsed < const Duration(seconds: 15)) {
                await Future<void>.delayed(const Duration(milliseconds: 50));
              }
              expect(engine.isPlaying, isFalse);
              expect(started, <String>['a', 'b']);
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
          // 用户操作后不再有第二个活实例（重叠收尾、没有残留预加载）。
          final int alive = instances.created
              .where((MpvMusicOutputBackend b) => !b.debugDisposed)
              .length;
          expect(alive, 1, reason: op);
        } finally {
          await engine.stop();
          engine.dispose();
        }
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '独占：交叉淡入自动停用——不装滤镜、不建第二实例、信号路径标「独占停用」',
    () async {
      final _Instances instances = _Instances(_nullAo);
      final MusicCrossfadeBackend xf = MusicCrossfadeBackend(
        instanceFactory: instances.call,
        platform: MusicOutputPlatform.windows,
      );
      final _Recorder rec = _Recorder(xf.events);
      try {
        await xf.applySettings(
          const MusicOutputSettings(
            gapless: true,
            replayGain: MusicReplayGainMode.off,
            crossfade: Duration(seconds: 2),
            exclusive: true,
          ),
        );
        await xf.openPair(
          _item('a', toneA, durationMs: 6000, album: 'x'),
          _item('b', toneB, durationMs: 6000, album: 'y'),
          play: true,
          crossfadeNext: true,
        );
        await rec.waitFor(() => rec.count<MusicBackendAdvanced>() >= 1);
        final MusicSignalPathSnapshot snap = (await xf.readSignalPath())!;
        expect(snap.crossfade, isFalse);
        expect(
          snap.crossfadeAvailability,
          MusicCrossfadeAvailability.disabledByExclusive,
        );
        expect(snap.userFilters, isEmpty);
        expect(
          await (instances.created.first.debugPlayer.platform! as NativePlayer)
              .getPropertyAsync('af'),
          isEmpty,
        );
        expect(instances.created.length, 1);
      } finally {
        await rec.cancel();
        await xf.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    '开着交叉淡入：信号路径标「交叉淡入」、判非 bit-perfect，滤镜不算用户滤镜',
    () async {
      final _Instances instances = _Instances(_nullAo);
      final MusicCrossfadeBackend xf = MusicCrossfadeBackend(
        instanceFactory: instances.call,
        platform: MusicOutputPlatform.windows,
      );
      final _Recorder rec = _Recorder(xf.events);
      try {
        await xf.applySettings(_xf);
        await xf.openPair(
          _item('a', longA, durationMs: 9000, album: 'x'),
          _item('b', longB, durationMs: 9000, album: 'y'),
          play: true,
          crossfadeNext: true,
        );
        await rec.waitFor(
          () => rec.events_.any(
            (e) =>
                e.event is MusicBackendPosition &&
                (e.event as MusicBackendPosition).position >
                    const Duration(milliseconds: 300),
          ),
        );
        final MusicSignalPathSnapshot snap = (await xf.readSignalPath())!;
        expect(snap.crossfade, isTrue);
        expect(snap.crossfadeAvailability, MusicCrossfadeAvailability.available);
        expect(snap.userFilters, isEmpty);
        final MusicSignalPathVerdict v = judgeMusicSignalPath(snap);
        expect(v.isBitPerfect, isFalse);
        expect(v.stages, contains(MusicSignalStage.crossfade));
        expect(v.stages, isNot(contains(MusicSignalStage.filters)));
      } finally {
        await rec.cancel();
        await xf.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // ── 真声卡（WASAPI 共享，数字静音）────────────────────────────────────────

  Future<double> cpuMs() async {
    final ProcessResult r = await Process.run('powershell', <String>[
      '-NoProfile',
      '-Command',
      '(Get-Process -Id $pid).TotalProcessorTime.TotalMilliseconds',
    ]);
    return double.parse((r.stdout as String).trim());
  }

  MpvMusicOutputBackend wasapi(int _) => MpvMusicOutputBackend(
    configuration: const PlayerConfiguration(
      vo: 'null',
      title: 'Fushi Music xf wasapi',
    ),
    platform: MusicOutputPlatform.windows,
  );

  test(
    'WASAPI 真设备：Advanced 时刻、两路对齐误差（6 次）',
    () async {
      final List<String> rows = <String>[];
      final List<double> medians = <double>[];
      for (int run = 0; run < 6; run++) {
        final ({
          MusicCrossfadeBackend xf,
          _Instances instances,
          _Recorder rec,
          int advanceAtUs,
          int idealAtUs,
        })
        r = await runToOverlap(make: wasapi, a: silenceA, b: silenceB);
        try {
          await r.rec.waitFor(
            () => !r.xf.debugOverlapping,
            timeout: const Duration(seconds: 10),
          );
          final List<double> o = List<double>.of(
            r.xf.debugLastOverlapOffsetsMs,
          )..sort();
          medians.add(o[o.length ~/ 2]);
          rows.add(
            'adv-vs-ideal=${((r.advanceAtUs - r.idealAtUs) / 1000).toStringAsFixed(1)}ms '
            'median=${o[o.length ~/ 2].toStringAsFixed(1)} '
            'min=${o.first.toStringAsFixed(1)} max=${o.last.toStringAsFixed(1)} n=${o.length}',
          );
        } finally {
          await r.rec.cancel();
          await r.xf.dispose();
        }
      }
      // ignore: avoid_print
      print('[xf-wasapi]\n  ${rows.join('\n  ')}');
      for (final double m in medians) {
        expect(m.abs(), lessThan(60));
      }
    },
    skip: wasapiSkip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'WASAPI 真设备：资源——第二实例按需创建、重叠后释放；CPU / 内存增量',
    () async {
      final _Instances instances = _Instances(wasapi);
      final MusicCrossfadeBackend xf = MusicCrossfadeBackend(
        instanceFactory: instances.call,
        platform: MusicOutputPlatform.windows,
      );
      final _Recorder rec = _Recorder(xf.events);
      final List<String> samples = <String>[];
      Future<void> sample(String label, Duration window) async {
        final int rss0 = ProcessInfo.currentRss;
        final double c0 = await cpuMs();
        final Stopwatch sw = Stopwatch()..start();
        await Future<void>.delayed(window);
        final double c1 = await cpuMs();
        samples.add(
          '$label: instances=${xf.debugInstanceCount} '
          'rss=${(rss0 / 1048576).toStringAsFixed(1)}MB '
          'cpu=${((c1 - c0) / sw.elapsedMilliseconds * 100).toStringAsFixed(2)}% of one core',
        );
      }

      try {
        // 真实内容（正弦）而不是静音，解码 / 滤镜开销才真实；音量 0 不出可闻声。
        await xf.applySettings(
          const MusicOutputSettings(
            gapless: true,
            replayGain: MusicReplayGainMode.off,
            crossfade: Duration(seconds: 6),
            volume: 0,
          ),
        );
        final String a = await _tone(dir, 'resA.flac', 30, 440);
        final String b = await _tone(dir, 'resB.flac', 30, 661);
        await xf.openPair(
          _item('a', a, durationMs: 30000, album: 'x'),
          _item('b', b, durationMs: 30000, album: 'y'),
          play: true,
          crossfadeNext: true,
        );
        await Future<void>.delayed(const Duration(seconds: 2));
        await sample('single (0–?s)', const Duration(seconds: 8));
        // 淡出起点 = 30 - 0.05 - 6 = 23.95 s；预加载在起点前 5 s。
        while (xf.debugInstanceCount < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        samples.add('preload created at instances=${xf.debugInstanceCount}');
        await rec.waitFor(() => rec.count<MusicBackendAdvanced>() >= 1);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await sample('overlap', const Duration(seconds: 5));
        await rec.waitFor(() => !xf.debugOverlapping);
        await Future<void>.delayed(const Duration(seconds: 1));
        await sample('after overlap', const Duration(seconds: 5));
      } finally {
        await rec.cancel();
        await xf.dispose();
      }
      // ignore: avoid_print
      print('[xf-res]\n  ${samples.join('\n  ')}');
      expect(instances.created.length, 2);
      expect(samples.last, contains('instances=1'));
    },
    skip: wasapiSkip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

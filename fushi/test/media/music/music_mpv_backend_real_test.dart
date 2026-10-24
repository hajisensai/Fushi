import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:media_kit/media_kit.dart';

/// 音乐输出后端对**真 libmpv** 的验证：FLAC 播放、CUE 拆轨（逐文件 start/end）切换时的
/// 时间连续性、两首文件的 gapless 衔接、ReplayGain 属性生效、Advanced 事件时序。
///
/// 需要真实 libmpv：`FUSHI_TEST_LIBMPV` 指向 libmpv-2.dll（其依赖的 FFmpeg DLL 所在目录要在
/// PATH 里），或先构建 Windows Debug（runner 目录自带 libmpv-2.dll）。`ao=null` 不出声。
String? _libmpvPath() {
  final String? override = Platform.environment['FUSHI_TEST_LIBMPV'];
  final String path = override ?? 'build/windows/x64/runner/Debug/libmpv-2.dll';
  return File(path).existsSync() ? File(path).absolute.path : null;
}

Future<String> _ffmpegTone(
  Directory dir,
  String name,
  double seconds,
  int freq, {
  List<String> extra = const <String>[],
}) async {
  final String out = '${dir.path}${Platform.pathSeparator}$name';
  final FfmpegRunResult r = await resolveFfmpegBackend().run(<String>[
    '-y',
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=$freq:sample_rate=44100:duration=$seconds',
    '-ac',
    '2',
    '-c:a',
    'flac',
    ...extra,
    out,
  ], const Duration(seconds: 60));
  if (!r.isSuccess) throw StateError('ffmpeg failed: ${r.failureSummary}');
  return out;
}

/// 数字静音 FLAC（真声卡用例：只验格式协商，不发出可闻声音）。
Future<String> _ffmpegSilence(
  Directory dir,
  String name,
  int sampleRate,
  String sampleFormat,
  int bits,
) async {
  final String out = '${dir.path}${Platform.pathSeparator}$name';
  final FfmpegRunResult r = await resolveFfmpegBackend().run(<String>[
    '-y',
    '-f',
    'lavfi',
    '-i',
    'anullsrc=r=$sampleRate:cl=stereo',
    '-t',
    '1.5',
    '-c:a',
    'flac',
    '-sample_fmt',
    sampleFormat,
    '-bits_per_raw_sample',
    '$bits',
    out,
  ], const Duration(seconds: 60));
  if (!r.isSuccess) throw StateError('ffmpeg failed: ${r.failureSummary}');
  return out;
}

/// ffmpeg volumedetect 的 max_volume（dBFS）。
Future<double> _maxVolumeDb(String path) async {
  final FfmpegRunResult r = await resolveFfmpegBackend().run(<String>[
    '-hide_banner',
    '-nostats',
    '-i',
    path,
    '-af',
    'volumedetect',
    '-f',
    'null',
    '-',
  ], const Duration(seconds: 60));
  final RegExpMatch? m = RegExp(
    r'max_volume:\s*(-?[0-9.]+) dB',
  ).firstMatch(r.output);
  if (m == null) throw StateError('volumedetect failed: ${r.failureSummary}');
  return double.parse(m.group(1)!);
}

/// 手写一个 DSF（DSD64 立体声，0x69 静音样式；FFmpeg 没有 DSF muxer），格式同
/// `native/fushi_music/tests/fixtures/generate.sh`。
String _writeDsf(Directory dir, String name, {required int seconds}) {
  const int rate = 2822400;
  const int channels = 2;
  const int block = 4096;
  final int samples = rate * seconds;
  final int blocks = (samples + block * 8 - 1) ~/ (block * 8);
  final int dataLen = blocks * block * channels;
  final BytesBuilder b = BytesBuilder();
  void u32(int v) =>
      b.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
  void u64(int v) =>
      b.add(Uint8List(8)..buffer.asByteData().setUint64(0, v, Endian.little));
  const int fmtLen = 52;
  final int dataChunk = 12 + dataLen;
  b.add('DSD '.codeUnits);
  u64(28);
  u64(28 + fmtLen + dataChunk);
  u64(0);
  b.add('fmt '.codeUnits);
  u64(fmtLen);
  u32(1); // version
  u32(0); // format id: DSD raw
  u32(2); // channel type: stereo
  u32(channels);
  u32(rate);
  u32(1); // bits per sample (LSB first)
  u64(samples);
  u32(block);
  u32(0);
  b.add('data'.codeUnits);
  u64(dataChunk);
  b.add(Uint8List(dataLen)..fillRange(0, dataLen, 0x69));
  final File f = File('${dir.path}${Platform.pathSeparator}$name')
    ..writeAsBytesSync(b.takeBytes());
  return f.path;
}

MusicPlayItem _item(
  String uid,
  String path, {
  int? startMs,
  int? endMs,
  int? durationMs,
}) => MusicPlayItem(
  trackUid: uid,
  path: path,
  title: uid,
  startMs: startMs,
  endMs: endMs,
  durationMs: durationMs,
);

/// 收集后端事件（带墙钟时刻）。
class _Recorder {
  _Recorder(MusicOutputBackend backend) {
    _sub = backend.events.listen((MusicBackendEvent e) {
      events.add((at: _clock.elapsedMilliseconds, event: e));
    });
  }

  final Stopwatch _clock = Stopwatch()..start();
  final List<({int at, MusicBackendEvent event})> events =
      <({int at, MusicBackendEvent event})>[];
  late final StreamSubscription<MusicBackendEvent> _sub;

  Future<void> waitFor(
    bool Function() done, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final Stopwatch sw = Stopwatch()..start();
    while (!done()) {
      if (sw.elapsed > timeout) {
        throw TimeoutException('condition not met; events: $events');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  int count<T extends MusicBackendEvent>() =>
      events.where((e) => e.event is T).length;

  Future<void> cancel() => _sub.cancel();
}

MpvMusicOutputBackend _backend({MPVLogLevel log = MPVLogLevel.error}) =>
    MpvMusicOutputBackend(
      configuration: PlayerConfiguration(
        vo: 'null',
        title: 'Fushi Music test',
        logLevel: log,
      ),
      initialProperties: const <String, String>{'ao': 'null'},
    );

void main() {
  final String? libmpv = _libmpvPath();
  final String? skip = libmpv == null
      ? 'Build Windows Debug or set FUSHI_TEST_LIBMPV to libmpv-2.dll'
      : null;
  Directory? tempDir;
  late String a;
  late String b;
  late String full;
  late String hiRes;
  late String cdQuality;

  setUpAll(() async {
    if (libmpv == null) return;
    MediaKit.ensureInitialized(libmpv: libmpv);
    final Directory dir = tempDir = Directory.systemTemp.createTempSync(
      'fushi_music_mpv_',
    );
    a = await _ffmpegTone(dir, 'a.flac', 1.5, 440);
    b = await _ffmpegTone(dir, 'b.flac', 1.5, 660);
    full = await _ffmpegTone(dir, 'full.flac', 3, 330);
    hiRes = await _ffmpegSilence(dir, 'hires.flac', 96000, 's32', 24);
    cdQuality = await _ffmpegSilence(dir, 'cd.flac', 44100, 's16', 16);
  });
  tearDownAll(() => tempDir?.deleteSync(recursive: true));

  test(
    'FLAC 播放：位置前进，播放态为真',
    () async {
      final MpvMusicOutputBackend backend = _backend();
      final _Recorder rec = _Recorder(backend);
      try {
        await backend.applySettings(
          const MusicOutputSettings(
            gapless: true,
            replayGain: MusicReplayGainMode.track,
          ),
        );
        await backend.openPair(
          _item('a', a, durationMs: 1500),
          null,
          play: true,
        );
        await rec.waitFor(
          () => rec.events.any(
            (e) =>
                e.event is MusicBackendPosition &&
                (e.event as MusicBackendPosition).position >
                    const Duration(milliseconds: 500),
          ),
        );
        expect(
          rec.events.any(
            (e) =>
                e.event is MusicBackendPlaying &&
                (e.event as MusicBackendPlaying).playing,
          ),
          isTrue,
        );
        await rec.waitFor(() => rec.count<MusicBackendCompleted>() > 0);
      } finally {
        await rec.cancel();
        await backend.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CUE 拆轨：start/end 切换无缝，相对位置从 0 重新开始、墙钟不断',
    () async {
      final MpvMusicOutputBackend backend = _backend();
      final _Recorder rec = _Recorder(backend);
      try {
        await backend.applySettings(
          const MusicOutputSettings(
            gapless: true,
            replayGain: MusicReplayGainMode.album,
          ),
        );
        await backend.openPair(
          _item('t1', full, startMs: 0, endMs: 1500, durationMs: 1500),
          _item('t2', full, startMs: 1500, endMs: 3000, durationMs: 1500),
          play: true,
        );
        await rec.waitFor(() => rec.count<MusicBackendAdvanced>() >= 1);
        final int advIdx = rec.events.indexWhere(
          (e) => e.event is MusicBackendAdvanced,
        );
        final ({int at, MusicBackendEvent event}) adv = rec.events[advIdx];
        // 推进之前最后一个位置应接近第一首终点；之后第一个位置应接近第二首起点（相对 0）。
        final List<({int at, Duration pos})> before =
            <({int at, Duration pos})>[
              for (final e in rec.events.sublist(0, advIdx))
                if (e.event is MusicBackendPosition)
                  (at: e.at, pos: (e.event as MusicBackendPosition).position),
            ];
        await rec.waitFor(
          () => rec.events
              .skip(advIdx + 1)
              .any((e) => e.event is MusicBackendPosition),
        );
        final ({int at, MusicBackendEvent event}) firstAfter = rec.events
            .skip(advIdx + 1)
            .firstWhere((e) => e.event is MusicBackendPosition);
        final Duration afterPos =
            (firstAfter.event as MusicBackendPosition).position;
        // ignore: avoid_print
        print(
          '[cue] last-before=${before.last.pos.inMilliseconds}ms '
          'first-after=${afterPos.inMilliseconds}ms '
          'wall-gap=${firstAfter.at - before.last.at}ms adv-at=${adv.at}',
        );
        expect(before.last.pos.inMilliseconds, greaterThan(1100));
        expect(afterPos.inMilliseconds, lessThan(500));
        expect(
          firstAfter.at - before.last.at,
          lessThan(600),
          reason: '拆轨点墙钟不该出现停顿（无缝）',
        );
        // 后端此后只剩当前这一项要播：播完第二首即 Completed，不会再 Advanced。
        await backend.replaceNext(null);
        await rec.waitFor(() => rec.count<MusicBackendCompleted>() > 0);
        expect(rec.count<MusicBackendAdvanced>(), 1);
      } finally {
        await rec.cancel();
        await backend.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'gapless 两首衔接：属性为 weak、推进一次、衔接无停顿',
    () async {
      final MpvMusicOutputBackend backend = _backend();
      final _Recorder rec = _Recorder(backend);
      try {
        await backend.applySettings(
          const MusicOutputSettings(
            gapless: true,
            replayGain: MusicReplayGainMode.album,
          ),
        );
        await backend.openPair(
          _item('a', a, durationMs: 1500),
          _item('b', b, durationMs: 1500),
          play: true,
        );
        final NativePlayer native =
            backend.debugPlayer.platform! as NativePlayer;
        expect(await native.getProperty('gapless-audio'), 'weak');
        expect(await native.getProperty('prefetch-playlist'), 'yes');
        await rec.waitFor(() => rec.count<MusicBackendAdvanced>() >= 1);
        final int advIdx = rec.events.indexWhere(
          (e) => e.event is MusicBackendAdvanced,
        );
        final int lastBefore = rec.events
            .sublist(0, advIdx)
            .lastWhere((e) => e.event is MusicBackendPosition)
            .at;
        await rec.waitFor(
          () => rec.events
              .skip(advIdx + 1)
              .any((e) => e.event is MusicBackendPosition),
        );
        final int firstAfter = rec.events
            .skip(advIdx + 1)
            .firstWhere((e) => e.event is MusicBackendPosition)
            .at;
        // ignore: avoid_print
        print('[gapless] wall-gap=${firstAfter - lastBefore}ms');
        expect(firstAfter - lastBefore, lessThan(600));
        await backend.replaceNext(null);
        await rec.waitFor(() => rec.count<MusicBackendCompleted>() > 0);
        expect(rec.count<MusicBackendAdvanced>(), 1);
      } finally {
        await rec.cancel();
        await backend.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'ReplayGain：按出声曲目施加曲库增益（volume-gain），ao=pcm 实测输出电平',
    () async {
      // 源是 lavfi sine 默认振幅（约 -18 dBFS 峰值）；曲库增益 track -6 / album -3。
      for (final (MusicReplayGainMode mode, double expectDb)
          in <(MusicReplayGainMode, double)>[
            (MusicReplayGainMode.track, -6),
            (MusicReplayGainMode.album, -3),
          ]) {
        final String wav =
            '${tempDir!.path}${Platform.pathSeparator}rg_${mode.name}.wav';
        final MpvMusicOutputBackend backend = MpvMusicOutputBackend(
          configuration: const PlayerConfiguration(
            vo: 'null',
            title: 'Fushi Music test',
          ),
          initialProperties: <String, String>{
            'ao': 'pcm',
            'ao-pcm-file': wav,
            'ao-pcm-waveheader': 'yes',
          },
        );
        final _Recorder rec = _Recorder(backend);
        try {
          await backend.applySettings(
            MusicOutputSettings(gapless: true, replayGain: mode),
          );
          await backend.openPair(
            MusicPlayItem(
              trackUid: 'g',
              path: a,
              title: 'g',
              durationMs: 1500,
              rgTrackGain: -6,
              rgTrackPeak: 0.125,
              rgAlbumGain: -3,
              rgAlbumPeak: 0.125,
            ),
            null,
            play: true,
          );
          final NativePlayer native =
              backend.debugPlayer.platform! as NativePlayer;
          expect(await native.getProperty('replaygain'), 'no');
          expect(
            double.parse(await native.getProperty('volume-gain')),
            closeTo(expectDb, 0.01),
          );
          await rec.waitFor(() => rec.count<MusicBackendCompleted>() > 0);
        } finally {
          await rec.cancel();
          await backend.dispose();
        }
        final double srcMax = await _maxVolumeDb(a);
        final double outMax = await _maxVolumeDb(wav);
        // ignore: avoid_print
        print('[replaygain:${mode.name}] src=$srcMax out=$outMax');
        expect(outMax - srcMax, closeTo(expectDb, 0.3));
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    '无缝切歌：Advanced 在前一首真正放完的时刻发（误差 ≤ 30 ms），增益随出声切换',
    () async {
      // 真值：前一首最后一个 time-pos 采样（index 还没切时，mpv 的 time-pos 已扣掉设备延迟）
      // + 剩余时长 = 前一首放完的墙钟时刻。改前 Advanced 在 index 切换（解码器开始读下一首）
      // 时就发了，实测提前约 360 ms。
      for (final bool cue in <bool>[false, true]) {
        final MpvMusicOutputBackend backend = _backend();
        final Stopwatch clock = Stopwatch()..start();
        final List<({int at, Duration pos, int index})> raw =
            <({int at, Duration pos, int index})>[];
        int index = 0;
        int? switchAt;
        final StreamSubscription<Playlist> plSub = backend
            .debugPlayer
            .stream
            .playlist
            .listen((Playlist p) {
              if (p.index == 1 && index == 0) {
                switchAt = clock.elapsedMilliseconds;
              }
              index = p.index;
            });
        final StreamSubscription<Duration> posSub = backend
            .debugPlayer
            .stream
            .position
            .listen(
              (Duration d) => raw.add((
                at: clock.elapsedMilliseconds,
                pos: d,
                index: index,
              )),
            );
        int? advancedAt;
        String? advancedUid;
        final StreamSubscription<MusicBackendEvent> evSub = backend.events
            .listen((MusicBackendEvent e) {
              if (e is MusicBackendAdvanced && advancedAt == null) {
                advancedAt = clock.elapsedMilliseconds;
                advancedUid = e.trackUid;
              }
            });
        try {
          await backend.applySettings(
            const MusicOutputSettings(
              gapless: true,
              replayGain: MusicReplayGainMode.track,
            ),
          );
          final MusicPlayItem first = MusicPlayItem(
            trackUid: 't1',
            path: cue ? full : a,
            title: 't1',
            startMs: cue ? 0 : null,
            endMs: cue ? 1500 : null,
            durationMs: 1500,
            rgTrackGain: -4,
          );
          final MusicPlayItem second = MusicPlayItem(
            trackUid: 't2',
            path: cue ? full : b,
            title: 't2',
            startMs: cue ? 1500 : null,
            endMs: cue ? 3000 : null,
            durationMs: 1500,
            rgTrackGain: -1,
          );
          await backend.openPair(first, second, play: true);
          final NativePlayer native =
              backend.debugPlayer.platform! as NativePlayer;
          final List<String> gainsInWindow = <String>[];
          final Stopwatch sw = Stopwatch()..start();
          while (advancedAt == null &&
              sw.elapsed < const Duration(seconds: 10)) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            if (index == 1 && advancedAt == null) {
              final String g = await native.getPropertyAsync('volume-gain');
              // 读回来之前 Advanced 已发的那一个样本不算切换期。
              if (advancedAt == null) gainsInWindow.add(g);
            }
          }
          expect(advancedAt, isNotNull);
          expect(advancedUid, 't2');
          final ({int at, Duration pos, int index}) lastFirst = raw.lastWhere(
            (e) => e.index == 0 && e.pos > Duration.zero,
          );
          final int truth =
              lastFirst.at + (1500 - lastFirst.pos.inMilliseconds);
          // ignore: avoid_print
          print(
            '[advance cue=$cue] decoder-switch=${switchAt! - truth}ms '
            'advanced=${advancedAt! - truth}ms (relative to audible end)',
          );
          expect(
            (advancedAt! - truth).abs(),
            lessThanOrEqualTo(30),
            reason: 'Advanced 应在前一首实际出声结束时发',
          );
          expect(
            truth - switchAt!,
            greaterThan(100),
            reason: '本用例要覆盖「解码先切、出声后切」的切换期',
          );
          // 切换期（index 已到 1、还没 Advanced）里增益仍是前一首的。
          expect(gainsInWindow, isNotEmpty);
          expect(
            gainsInWindow.every((String g) => double.parse(g) == -4),
            isTrue,
            reason: '$gainsInWindow',
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(double.parse(await native.getProperty('volume-gain')), -1);
        } finally {
          await plSub.cancel();
          await posSub.cancel();
          await evSub.cancel();
          await backend.dispose();
        }
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'CUE 拆轨点样本级无缝：两段 EDL 依次播完，ao=pcm 输出与整轨解码逐样本一致',
    () async {
      // 改前用逐文件 start 选项：第二段加载时 mpv 做播放器级 seek，丢掉设备缓冲里第一段
      // 的尾巴，输出比整轨短约 360 ms。
      final String wav = '${tempDir!.path}${Platform.pathSeparator}cue.wav';
      final MpvMusicOutputBackend backend = MpvMusicOutputBackend(
        configuration: const PlayerConfiguration(
          vo: 'null',
          title: 'Fushi Music test',
        ),
        initialProperties: <String, String>{
          'ao': 'pcm',
          'ao-pcm-file': wav,
          'ao-pcm-waveheader': 'yes',
        },
      );
      final _Recorder rec = _Recorder(backend);
      try {
        await backend.applySettings(
          const MusicOutputSettings(
            gapless: true,
            replayGain: MusicReplayGainMode.off,
          ),
        );
        await backend.openPair(
          _item('t1', full, startMs: 0, endMs: 1500, durationMs: 1500),
          _item('t2', full, startMs: 1500, durationMs: 1500),
          play: true,
        );
        await rec.waitFor(() => rec.count<MusicBackendAdvanced>() >= 1);
        await backend.replaceNext(null);
        await rec.waitFor(() => rec.count<MusicBackendCompleted>() > 0);
      } finally {
        await rec.cancel();
        await backend.dispose();
      }
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

      Future<String> describe(String path) async {
        final FfmpegRunResult r = await resolveFfmpegBackend().run(<String>[
          '-hide_banner',
          '-i',
          path,
          '-af',
          'astats=metadata=0:reset=0',
          '-f',
          'null',
          '-',
        ], const Duration(seconds: 60));
        return RegExp(
          r'(Number of samples|Stream #0:0|DC offset|Peak level dB): [^\n]*',
        ).allMatches(r.output).map((Match m) => m.group(0)).join(' | ');
      }

      expect(
        await md5Of(wav),
        await md5Of(full),
        reason:
            '两段拼起来必须与整轨逐样本相同（不丢尾、不插静音）\n'
            'out: ${await describe(wav)}\nsrc: ${await describe(full)}',
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'DSD → PCM：逐文件 audio-samplerate 生效，面板标 DSD→PCM、不判 bit-perfect',
    () async {
      final String dsf = _writeDsf(tempDir!, 'dsd.dsf', seconds: 2);
      for (final MusicDsdPcmRate rate in MusicDsdPcmRate.values) {
        final MpvMusicOutputBackend backend = _backend();
        final _Recorder rec = _Recorder(backend);
        try {
          await backend.applySettings(
            MusicOutputSettings(
              gapless: true,
              replayGain: MusicReplayGainMode.off,
              dsdPcmRate: rate,
            ),
          );
          await backend.openPair(
            MusicPlayItem(
              trackUid: 'd',
              path: dsf,
              title: 'd',
              durationMs: 2000,
              codec: 'dsd',
            ),
            null,
            play: true,
          );
          await rec.waitFor(
            () => rec.events.any(
              (e) =>
                  e.event is MusicBackendPosition &&
                  (e.event as MusicBackendPosition).position >
                      const Duration(milliseconds: 300),
            ),
          );
          final MusicSignalPathSnapshot snap = (await backend
              .readSignalPath())!;
          // ignore: avoid_print
          print(
            '[dsd ${rate.hz}] codec=${snap.codec} '
            'decoded=${snap.decoded} out=${snap.output}',
          );
          expect(snap.isDsd, isTrue);
          expect(snap.output?.sampleRate, rate.hz);
          final MusicSignalPathVerdict v = judgeMusicSignalPath(snap);
          expect(v.isBitPerfect, isFalse);
          expect(v.stages, contains(MusicSignalStage.dsdToPcm));
        } finally {
          await rec.cancel();
          await backend.dispose();
        }
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    '信号路径：变速 / 音量 / ReplayGain 各环都从 mpv 属性读出并降级',
    () async {
      final MpvMusicOutputBackend backend = _backend();
      final _Recorder rec = _Recorder(backend);
      try {
        await backend.applySettings(
          const MusicOutputSettings(
            gapless: true,
            replayGain: MusicReplayGainMode.track,
            speed: 1.25,
            volume: 80,
          ),
        );
        await backend.openPair(
          MusicPlayItem(
            trackUid: 'a',
            path: a,
            title: 'a',
            durationMs: 1500,
            rgTrackGain: -2,
          ),
          null,
          play: true,
        );
        await rec.waitFor(
          () => rec.events.any(
            (e) =>
                e.event is MusicBackendPosition &&
                (e.event as MusicBackendPosition).position >
                    const Duration(milliseconds: 300),
          ),
        );
        final MusicSignalPathSnapshot snap = (await backend.readSignalPath())!;
        expect(snap.speed, closeTo(1.25, 1e-6));
        expect(snap.volume, closeTo(80, 1e-6));
        expect(snap.volumeGainDb, closeTo(-2, 1e-6));
        expect(snap.decoded?.sampleRate, 44100);
        final MusicSignalPathVerdict v = judgeMusicSignalPath(snap);
        expect(
          v.stages,
          containsAll(<MusicSignalStage>[
            MusicSignalStage.speed,
            MusicSignalStage.volume,
            MusicSignalStage.replayGain,
          ]),
        );
        expect(v.isBitPerfect, isFalse);
      } finally {
        await rec.cancel();
        await backend.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // ── 真实声卡（会占用设备、播放约 1.5 s 数字静音）：只在显式给了设备时跑 ──────────
  // FUSHI_TEST_MUSIC_WASAPI_DEVICES = 逗号分隔的 mpv 设备名（`wasapi/{guid}`），
  // 例如一个支持 24/96 独占的数字输出、一个只支持 16 bit 的普通声卡。
  final List<String> wasapiDevices =
      (Platform.environment['FUSHI_TEST_MUSIC_WASAPI_DEVICES'] ?? '')
          .split(',')
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toList();
  final String? wasapiSkip =
      skip ??
      (!Platform.isWindows || wasapiDevices.isEmpty
          ? 'set FUSHI_TEST_MUSIC_WASAPI_DEVICES (Windows) to run on real devices'
          : null);

  test(
    'WASAPI 独占：audio-out-params 与源一致时判 bit-perfect，不一致时指出哪一环',
    () async {
      for (final String device in wasapiDevices) {
        for (final (String label, String path, bool exclusive)
            in <(String, String, bool)>[
              ('24/96 exclusive', hiRes, true),
              ('16/44.1 exclusive', cdQuality, true),
              ('24/96 shared', hiRes, false),
            ]) {
          final MpvMusicOutputBackend backend = MpvMusicOutputBackend(
            configuration: const PlayerConfiguration(
              vo: 'null',
              title: 'Fushi Music test',
            ),
            platform: MusicOutputPlatform.windows,
          );
          final _Recorder rec = _Recorder(backend);
          try {
            await backend.applySettings(
              MusicOutputSettings(
                gapless: true,
                replayGain: MusicReplayGainMode.off,
                exclusive: exclusive,
                audioDevice: device,
              ),
            );
            await backend.openPair(
              MusicPlayItem(
                trackUid: label,
                path: path,
                title: label,
                durationMs: 1500,
                bitDepth: path == hiRes ? 24 : 16,
              ),
              null,
              play: true,
            );
            await rec.waitFor(
              () => rec.events.any(
                (e) =>
                    e.event is MusicBackendPosition &&
                    (e.event as MusicBackendPosition).position >
                        const Duration(milliseconds: 400),
              ),
            );
            final NativePlayer native =
                backend.debugPlayer.platform! as NativePlayer;
            final MusicAudioFormat? inRaw = MusicAudioFormat.fromMpvJson(
              await native.getProperty('audio-params'),
            );
            final MusicAudioFormat? outRaw = MusicAudioFormat.fromMpvJson(
              await native.getProperty('audio-out-params'),
            );
            final MusicSignalPathSnapshot snap = (await backend
                .readSignalPath())!;
            final MusicSignalPathVerdict v = judgeMusicSignalPath(snap);
            // ignore: avoid_print
            print(
              '[wasapi $device $label] ao=${snap.currentAo} '
              'exclusive=${snap.exclusiveRequested} in=$inRaw out=$outRaw '
              'verdict=${v.quality.name} '
              '${v.stages.map((MusicSignalStage s) => s.name).toList()}',
            );
            // 设备不接受独占（或这个格式的独占）时后端退回共享并发明确提示。
            final bool fellBack = rec.count<MusicBackendOutputFallback>() > 0;
            final bool exclusiveActive = exclusive && !fellBack;
            // ignore: avoid_print
            if (fellBack)
              print(
                '  fallback: ${rec.events.firstWhere((e) => e.event is MusicBackendOutputFallback).event}',
              );
            expect(snap.currentAo, 'wasapi');
            expect(snap.exclusiveRequested, exclusiveActive);
            expect(inRaw, isNotNull);
            expect(outRaw, isNotNull);
            final bool rawIdentical =
                inRaw!.packedFormat == outRaw!.packedFormat &&
                inRaw.sampleRate == outRaw.sampleRate &&
                inRaw.channelCount == outRaw.channelCount;
            // 面板判定与实测一致：独占且输出 = 源 ⇔ bit-perfect。
            expect(v.isBitPerfect, exclusiveActive && rawIdentical);
            if (!exclusiveActive) {
              expect(v.stages, contains(MusicSignalStage.systemMixer));
            }
            if (inRaw.sampleRate != outRaw.sampleRate) {
              expect(v.stages, contains(MusicSignalStage.resampler));
            }
            if (inRaw.packedFormat != outRaw.packedFormat) {
              expect(v.stages, contains(MusicSignalStage.formatConversion));
            }
          } finally {
            await rec.cancel();
            await backend.dispose();
          }
        }
      }
    },
    skip: wasapiSkip,
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'WASAPI：独占 + 不存在的设备 → 先退共享、再退默认设备，两次都明确提示且继续播放',
    () async {
      final MpvMusicOutputBackend backend = MpvMusicOutputBackend(
        configuration: const PlayerConfiguration(
          vo: 'null',
          title: 'Fushi Music test',
        ),
        platform: MusicOutputPlatform.windows,
      );
      final _Recorder rec = _Recorder(backend);
      try {
        await backend.applySettings(
          const MusicOutputSettings(
            gapless: true,
            replayGain: MusicReplayGainMode.off,
            exclusive: true,
            audioDevice: 'wasapi/{00000000-0000-0000-0000-000000000000}',
          ),
        );
        await backend.openPair(
          _item('x', cdQuality, durationMs: 1500),
          null,
          play: true,
        );
        await rec.waitFor(() => rec.count<MusicBackendOutputFallback>() >= 2);
        final List<MusicOutputFallbackReason> reasons =
            <MusicOutputFallbackReason>[
              for (final e in rec.events)
                if (e.event is MusicBackendOutputFallback)
                  (e.event as MusicBackendOutputFallback).reason,
            ];
        expect(reasons, <MusicOutputFallbackReason>[
          MusicOutputFallbackReason.exclusiveUnavailable,
          MusicOutputFallbackReason.deviceUnavailable,
        ]);
        await rec.waitFor(
          () => rec.events.any(
            (e) =>
                e.event is MusicBackendPosition &&
                (e.event as MusicBackendPosition).position >
                    const Duration(milliseconds: 300),
          ),
        );
        final MusicSignalPathSnapshot snap = (await backend.readSignalPath())!;
        expect(snap.currentAo, 'wasapi');
        expect(snap.exclusiveRequested, isFalse);
        expect(snap.audioDevice, 'auto');
        expect(
          rec.count<MusicBackendCompleted>(),
          0,
          reason:
              '输出失败导致的「播完」不能当成曲目播完：'
              '${rec.events.where((e) => e.event is! MusicBackendPosition).map((e) => '${e.at}:${e.event.runtimeType}').toList()}',
        );
      } finally {
        await rec.cancel();
        await backend.dispose();
      }
    },
    skip: wasapiSkip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    '引擎 + 真后端：三首推进两次，后端始终只排「当前 + 下一首」',
    () async {
      late MpvMusicOutputBackend backend;
      final MusicPlayerEngine engine = MusicPlayerEngine(
        backendFactory: () => backend = _backend(),
      );
      final List<String> started = <String>[];
      engine.onTrackStarted = (MusicPlayItem i) => started.add(i.trackUid);
      try {
        await engine.playQueue(<MusicPlayItem>[
          _item('a', a, durationMs: 1500),
          _item('b', b, durationMs: 1500),
          _item('c', a, durationMs: 1500),
        ], context: MusicQueueContext.album);
        final Stopwatch sw = Stopwatch()..start();
        final List<int> playlistSizes = <int>[];
        while (started.length < 3 && sw.elapsed < const Duration(seconds: 15)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          playlistSizes.add(backend.debugPlayer.state.playlist.medias.length);
        }
        expect(started, <String>['a', 'b', 'c']);
        expect(engine.current?.trackUid, 'c');
        // 推进后 replaceNext 收尾：稳态下 mpv 播放列表恒 ≤ 2 项。
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(backend.debugPlayer.state.playlist.medias.length, 1);
        expect(
          playlistSizes.every((int n) => n <= 2),
          isTrue,
          reason: 'playlist sizes over time: $playlistSizes',
        );
        final Stopwatch done = Stopwatch()..start();
        while (engine.isPlaying && done.elapsed < const Duration(seconds: 10)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(engine.isPlaying, isFalse, reason: '最后一首播完应停');
      } finally {
        await engine.stop();
        engine.dispose();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

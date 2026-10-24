import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
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
  late Directory dir;
  late String a;
  late String b;
  late String full;
  late String gained;

  setUpAll(() async {
    if (libmpv == null) return;
    MediaKit.ensureInitialized(libmpv: libmpv);
    dir = Directory.systemTemp.createTempSync('fushi_music_mpv_');
    a = await _ffmpegTone(dir, 'a.flac', 1.5, 440);
    b = await _ffmpegTone(dir, 'b.flac', 1.5, 660);
    full = await _ffmpegTone(dir, 'full.flac', 3, 330);
    gained = await _ffmpegTone(
      dir,
      'gained.flac',
      1,
      550,
      extra: <String>[
        '-metadata',
        'REPLAYGAIN_TRACK_GAIN=-6.00 dB',
        '-metadata',
        'REPLAYGAIN_ALBUM_GAIN=-3.00 dB',
      ],
    );
  });
  tearDownAll(() {
    if (libmpv == null) return;
    dir.deleteSync(recursive: true);
  });

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
    'ReplayGain：属性下发后 mpv 按标签施加增益（track / album 两档）',
    () async {
      // 标签：track -6 dB、album -3 dB → 线性 0.501 / 0.708。
      for (final (MusicReplayGainMode mode, double expectGain)
          in <(MusicReplayGainMode, double)>[
            (MusicReplayGainMode.track, 0.501187),
            (MusicReplayGainMode.album, 0.707946),
          ]) {
        final MpvMusicOutputBackend backend = _backend(log: MPVLogLevel.v);
        final List<String> logs = <String>[];
        final StreamSubscription<PlayerLog> logSub = backend
            .debugPlayer
            .stream
            .log
            .listen((PlayerLog l) => logs.add(l.text));
        final _Recorder rec = _Recorder(backend);
        try {
          await backend.applySettings(
            MusicOutputSettings(gapless: true, replayGain: mode),
          );
          final NativePlayer native =
              backend.debugPlayer.platform! as NativePlayer;
          expect(await native.getProperty('replaygain'), mode.mpvValue);
          expect(await native.getProperty('replaygain-clip'), 'no');
          await backend.openPair(
            _item('g', gained, durationMs: 1000),
            null,
            play: true,
          );
          await rec.waitFor(() => rec.count<MusicBackendCompleted>() > 0);
          final String rgLog = logs
              .where((String l) => l.toLowerCase().contains('gain'))
              .join(' | ');
          // ignore: avoid_print
          print('[replaygain:${mode.name}] $rgLog');
          // mpv 的实际施加：`Applying replay-gain: <线性系数>`。
          final RegExpMatch? applied = RegExp(
            r'Applying replay-gain: ([0-9.]+)',
          ).firstMatch(rgLog);
          expect(applied, isNotNull, reason: 'mpv 没有施加 ReplayGain：$rgLog');
          expect(
            double.parse(applied!.group(1)!),
            closeTo(expectGain, 0.001),
            reason: '${mode.name} 档应按对应标签施加增益',
          );
        } finally {
          await logSub.cancel();
          await rec.cancel();
          await backend.dispose();
        }
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 90)),
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

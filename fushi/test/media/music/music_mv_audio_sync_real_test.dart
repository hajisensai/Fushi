import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/music/music_mv_page.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:media_kit/media_kit.dart';

/// MV 页「曲库音轨」模式对**真 libmpv** 的验证：MV 画面 + `audio-add` 外挂的本地音轨，
/// `audio-delay = offset − cueStart`（[musicMvAudioDelaySeconds]）之后，外挂音轨在 MV 时刻 v
/// 播的是文件时刻 `v − delay`——即歌词 / 音频与画面按偏移对齐，符号没反。
///
/// 需要真实 libmpv：`FUSHI_TEST_LIBMPV` 指向 libmpv-2.dll，或先构建 Windows Debug。
String? _libmpvPath() {
  final String? override = Platform.environment['FUSHI_TEST_LIBMPV'];
  final String path = override ?? 'build/windows/x64/runner/Debug/libmpv-2.dll';
  return File(path).existsSync() ? File(path).absolute.path : null;
}

Future<void> _ff(List<String> args) async {
  final FfmpegRunResult r = await resolveFfmpegBackend().run(<String>[
    '-y',
    '-v',
    'error',
    ...args,
  ], const Duration(seconds: 120));
  if (!r.isSuccess) throw StateError('ffmpeg failed: ${r.failureSummary}');
}

void main() {
  final String? libmpv = _libmpvPath();
  final String? skip = libmpv == null
      ? 'Build Windows Debug or set FUSHI_TEST_LIBMPV to libmpv-2.dll'
      : null;
  Directory? dir;
  late String mv;
  late String song;

  setUpAll(() async {
    if (libmpv == null) return;
    MediaKit.ensureInitialized(libmpv: libmpv);
    final Directory d = dir = Directory.systemTemp.createTempSync('mv_sync_');
    mv = '${d.path}${Platform.pathSeparator}mv.mp4';
    song = '${d.path}${Platform.pathSeparator}song.wav';
    // MV：画面 + 静音音轨（不选它）。
    await _ff(<String>[
      '-f',
      'lavfi',
      '-i',
      'color=c=blue:s=160x90:r=24:d=12',
      '-f',
      'lavfi',
      '-i',
      'anullsrc=r=48000:cl=stereo',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-c:a',
      'aac',
      '-t',
      '12',
      mv,
    ]);
    // 曲库音轨：40 s 静音，文件时刻 4.0 s 与 12.0 s 各一记 50 ms 的 1 kHz 脉冲。
    await _ff(<String>[
      '-f',
      'lavfi',
      '-i',
      "aevalsrc='if(between(t,4,4.05)+between(t,12,12.05),0.8*sin(2*PI*1000*t),0)':s=48000:d=40",
      '-ac',
      '1',
      '-c:a',
      'pcm_s16le',
      song,
    ]);
  });
  tearDownAll(() => dir?.deleteSync(recursive: true));

  /// 用 `ao=pcm` 把 mpv 实际送出的音频落盘：跳到 MV 时刻 [seekTo] 起播 [seconds] 秒，返回输出
  /// 里第一记脉冲距输出开头的秒数。输出开头就是 MV 时刻 [seekTo]，所以脉冲的 MV 时刻 =
  /// [seekTo] + 返回值——这是「外挂音轨在 MV 时刻 v 播的是文件哪一刻」的直接观测
  /// （`audio-pts` 已含 `audio-delay`，量不出符号）。
  Future<double?> firstPulseAt({
    required int offsetMs,
    int? cueStartMs,
    required Duration seekTo,
    required double seconds,
  }) async {
    final String dump =
        '${dir!.path}${Platform.pathSeparator}out_${offsetMs}_${cueStartMs ?? 0}.wav';
    final Player player = Player();
    final NativePlayer native = player.platform! as NativePlayer;
    try {
      await native.setProperty('vo', 'null');
      await native.setProperty('ao', 'pcm');
      await native.setProperty('ao-pcm-file', dump);
      await native.setProperty('ao-pcm-waveheader', 'no');
      await native.setProperty('audio-format', 's16');
      await native.setProperty('audio-samplerate', '48000');
      await native.setProperty('audio-channels', 'mono');
      await native.setProperty('hr-seek', 'yes');
      await player.open(Media(mv), play: false);
      await player.stream.duration.firstWhere(
        (Duration d) => d > Duration.zero,
      );
      await native.command(<String>['audio-add', song, 'select']);
      await native.setProperty(
        'audio-delay',
        musicMvAudioDelaySeconds(
          offsetMs: offsetMs,
          cueStartMs: cueStartMs,
        ).toStringAsFixed(3),
      );
      await player.seek(seekTo);
      await player.play();
      await player.stream.position.firstWhere(
        (Duration p) =>
            p.inMilliseconds >= seekTo.inMilliseconds + seconds * 1000,
      );
    } finally {
      await player.dispose();
    }
    final Uint8List bytes = File(dump).readAsBytesSync();
    final ByteData view = ByteData.sublistView(bytes);
    for (int i = 0; i + 1 < bytes.length; i += 2) {
      if (view.getInt16(i, Endian.little).abs() > 8000) {
        return (i ~/ 2) / 48000;
      }
    }
    return null;
  }

  test(
    'MV 有 2 s 前奏：从 MV 5 s 起播，听到的是文件 3 s 起（文件 4 s 的脉冲在输出 1 s 处）',
    () async {
      final double? at = await firstPulseAt(
        offsetMs: 2000,
        seekTo: const Duration(seconds: 5),
        seconds: 3,
      );
      // ignore: avoid_print
      print('offset 2000 seek 5: pulse at +$at');
      // 符号反了会听到文件 7 s 起（窗口里没有脉冲）。
      expect(at, isNotNull);
      expect(at!, closeTo(1.0, 0.1));
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CUE 曲目（整轨 10 s 处起）+ MV 偏移 1 s：从 MV 2 s 起播，听到的是文件 11 s 起',
    () async {
      // 曲目时刻 = 文件时刻 − 10；MV 时刻 = 曲目时刻 + 1 → MV 2 s = 文件 11 s，文件 12 s 的脉冲
      // 在输出 1 s 处。忽略 CUE 起点会听到文件 1 s 起（脉冲在输出 3 s 处：文件 4 s）。
      final double? at = await firstPulseAt(
        offsetMs: 1000,
        cueStartMs: 10000,
        seekTo: const Duration(seconds: 2),
        seconds: 3,
      );
      // ignore: avoid_print
      print('offset 1000 cue 10000 seek 2: pulse at +$at');
      expect(at, isNotNull);
      expect(at!, closeTo(1.0, 0.1));
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

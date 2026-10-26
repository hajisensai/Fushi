import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_loudness_scanner.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';

const String _summary = '''
[Parsed_ebur128_0 @ 000001] t: 2.9   TARGET:-23 LUFS    M: -21.0 S: -21.0     I: -21.0 LUFS
[Parsed_ebur128_0 @ 000001] Summary:

  Integrated loudness:
    I:         -21.2 LUFS
    Threshold: -31.2 LUFS

  Loudness range:
    LRA:         0.0 LU

  True peak:
    Peak:      -18.1 dBFS
''';

MusicTracksCompanion _track(
  String uid, {
  required String path,
  String? albumUid,
  double? gain,
  int? cueStartMs,
  int? cueEndMs,
  int durationMs = 2000,
}) => MusicTracksCompanion.insert(
  trackUid: uid,
  path: path,
  title: uid,
  albumUid: Value<String?>(albumUid),
  rgTrackGain: Value<double?>(gain),
  cueStartMs: Value<int?>(cueStartMs),
  cueEndMs: Value<int?>(cueEndMs),
  durationMs: Value<int?>(durationMs),
  fileMtimeAt: 1,
  fileSize: 1,
  addedAt: 1,
);

/// 测扫描编排（开关门 / 失败落库 / FFmpeg 起不来）用的确定性后端：不依赖本机有没有
/// FFmpeg——CI（Linux runner）没装，真 FFmpeg 只在下面的「真 FFmpeg」组里用。
class _ScriptedFfmpeg implements FfmpegBackend {
  _ScriptedFfmpeg({this.launchError, this.result});

  /// 非 null：每次 run 都像 `Process.start` 找不到可执行那样抛出。
  final ProcessException? launchError;

  /// launchError 为 null 时 run 返回它。
  final FfmpegRunResult? result;
  int runs = 0;

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    runs++;
    final ProcessException? error = launchError;
    if (error != null) throw error;
    return result!;
  }

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) =>
      throw UnimplementedError('loudness scan never probes');

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) =>
      throw UnimplementedError('loudness scan never queries');
}

/// 本机（程序旁捆绑 / PATH / `FUSHI_FFMPEG`）能否真起 FFmpeg。与
/// `test/media/video/ffmpeg_backend_test.dart` 同一判据；`dart_test.yaml` 的
/// `ffmpeg` 标签约定：真跑 FFmpeg 的用例缺 FFmpeg 时自身跳过。
Future<bool> _ffmpegAvailable() async {
  try {
    final FfmpegRunResult r = await resolveFfmpegBackend().run(<String>[
      '-hide_banner',
      '-version',
    ], const Duration(seconds: 15));
    return r.isSuccess;
  } on ProcessException {
    return false;
  }
}

void main() {
  test('ebur128 摘要解析：只认 Summary 段；增益 = -18 - I；静音不给增益', () {
    final MusicLoudnessMeasurement m = parseEbur128Summary(_summary)!;
    expect(m.integratedLufs, -21.2);
    expect(m.truePeakDbtp, -18.1);
    expect(m.replayGainDb, closeTo(3.2, 1e-9));
    expect(m.linearPeak, closeTo(math.pow(10, -18.1 / 20), 1e-12));
    expect(parseEbur128Summary('no summary here'), isNull);
    final MusicLoudnessMeasurement silent = parseEbur128Summary(
      'Summary:\n I:  -70.0 LUFS\n Peak:  -inf dBFS',
    )!;
    expect(silent.replayGainDb, isNull);
    expect(silent.truePeakDbtp, isNull);
  });

  test('专辑增益：按时长加权能量平均；缺任何一首返回 null', () {
    // 两首同响度 → 专辑 = 曲目。
    final ({double gain, double? peak}) same = musicAlbumLoudnessOf(
      <({double? trackGain, double? trackPeak, int? durationMs})>[
        (trackGain: -3, trackPeak: 0.5, durationMs: 1000),
        (trackGain: -3, trackPeak: 0.8, durationMs: 3000),
      ],
    )!;
    expect(same.gain, closeTo(-3, 1e-9));
    expect(same.peak, 0.8);
    // -18-(-6)=-12 LUFS 与 -18-0=-18 LUFS 等长：能量平均 ≈ -14.03 LUFS → 增益 -3.97。
    final ({double gain, double? peak}) mixed = musicAlbumLoudnessOf(
      <({double? trackGain, double? trackPeak, int? durationMs})>[
        (trackGain: -6, trackPeak: null, durationMs: 1000),
        (trackGain: 0, trackPeak: null, durationMs: 1000),
      ],
    )!;
    final double expected =
        -18 -
        10 *
            math.log((math.pow(10, -1.2) + math.pow(10, -1.8)) / 2) /
            math.ln10;
    expect(mixed.gain, closeTo(expected, 1e-9));
    expect(
      musicAlbumLoudnessOf(
        <({double? trackGain, double? trackPeak, int? durationMs})>[
          (trackGain: -6, trackPeak: null, durationMs: 1000),
          (trackGain: null, trackPeak: null, durationMs: 1000),
        ],
      ),
      isNull,
    );
  });

  test('CUE 虚拟曲目只测自己那一段', () {
    final List<String> args = musicEbur128Args(
      MusicTrackRow(
        trackUid: 'c',
        path: '/m/full.flac',
        cueStartMs: 61500,
        cueEndMs: 120000,
        title: 'c',
        isLossless: true,
        fileMtimeAt: 1,
        fileSize: 1,
        hasEmbeddedCover: false,
        addedAt: 1,
      ),
    );
    expect(args.join(' '), contains('-ss 61.500 -t 58.500 -i /m/full.flac'));
    expect(args, contains('ebur128=peak=true'));
  });

  test('ReplayGain 增益：专辑 / 曲目模式互为回退，预放大后受峰值钳制', () {
    expect(
      musicReplayGainDb(
        albumMode: true,
        trackGain: -6,
        trackPeak: 0.5,
        albumGain: -3,
        albumPeak: 0.9,
        preampDb: 0,
      ),
      -3,
    );
    expect(
      musicReplayGainDb(
        albumMode: true,
        trackGain: -6,
        trackPeak: 0.5,
        albumGain: null,
        albumPeak: null,
        preampDb: 0,
      ),
      -6,
    );
    // +6 dB 预放大，峰值 0.9 → 最多 +0.915 dB。
    expect(
      musicReplayGainDb(
        albumMode: false,
        trackGain: 2,
        trackPeak: 0.9,
        albumGain: null,
        albumPeak: null,
        preampDb: 6,
      ),
      closeTo(-20 * math.log(0.9) / math.ln10, 1e-9),
    );
    expect(
      musicReplayGainDb(
        albumMode: false,
        trackGain: null,
        trackPeak: null,
        albumGain: null,
        albumPeak: null,
        preampDb: 6,
      ),
      0,
      reason: '没有响度信息时不施加预放大',
    );
  });

  test('「自动测量」关掉时曲库扫描触发的请求不跑，「立即测量」(force) 照跑', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    // FFmpeg 跑起来了、但这个文件读不了（与真 FFmpeg 对不存在路径的退出形态一致）。
    final _ScriptedFfmpeg ffmpeg = _ScriptedFfmpeg(
      result: const FfmpegRunResult(
        returnCode: 1,
        output: '/nonexistent/x.flac: No such file or directory',
      ),
    );
    final MusicLoudnessScanner scanner = MusicLoudnessScanner(
      database: () => db,
      enabled: () => false,
      ffmpeg: () => ffmpeg,
    );
    await db
        .into(db.musicTracks)
        .insert(_track('x', path: '/nonexistent/x.flac'));
    await scanner.schedule();
    expect(ffmpeg.runs, 0);
    expect((await db.getMusicTrack('x'))!.r128ScannedAt, isNull);
    await scanner.schedule(force: true);
    expect(ffmpeg.runs, 1);
    // 文件读不了：记扫描时刻（不无限重试），增益留空。
    final MusicTrackRow x = (await db.getMusicTrack('x'))!;
    expect(x.r128ScannedAt, isNotNull);
    expect(x.rgTrackGain, isNull);
    expect(scanner.lastError, contains('/nonexistent/x.flac'));
  });

  test('FFmpeg 本身起不来：schedule 不抛、原因进 lastError、曲目保持待测', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final _ScriptedFfmpeg ffmpeg = _ScriptedFfmpeg(
      launchError: const ProcessException(
        'ffmpeg',
        <String>['-hide_banner'],
        'No such file or directory',
        2,
      ),
    );
    final MusicLoudnessScanner scanner = MusicLoudnessScanner(
      database: () => db,
      enabled: () => true,
      ffmpeg: () => ffmpeg,
    );
    await db.into(db.musicTracks).insert(_track('a', path: '/m/a.flac'));
    await db.into(db.musicTracks).insert(_track('b', path: '/m/b.flac'));
    // 三个生产调用点都是 unawaited(schedule())：异常逃出去就是未处理的异步错误。
    await scanner.schedule(force: true);
    expect(ffmpeg.runs, 1, reason: 'FFmpeg 起不来是环境问题，整轮停下，不逐首再撞一次');
    expect(scanner.isRunning, isFalse);
    expect(scanner.lastError, contains('ffmpeg launch failed'));
    // 不能记成「已扫描」：否则装好 FFmpeg 后这些曲目再也不会被测。
    expect((await db.getMusicTrack('a'))!.r128ScannedAt, isNull);
    expect((await db.getMusicTrack('b'))!.r128ScannedAt, isNull);
  });

  group('真 FFmpeg + 内存 DB', () {
    late FushiDatabase db;
    late Directory dir;
    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      dir = Directory.systemTemp.createTempSync('fushi_music_r128_');
    });
    tearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });

    Future<String> tone(String name, double amplitude) async {
      final String out = '${dir.path}${Platform.pathSeparator}$name';
      final FfmpegRunResult r = await resolveFfmpegBackend().run(<String>[
        '-y',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=997:sample_rate=48000:duration=4',
        '-af',
        'volume=$amplitude',
        '-ac',
        '2',
        '-c:a',
        'flac',
        out,
      ], const Duration(seconds: 60));
      if (!r.isSuccess) throw StateError(r.failureSummary);
      return out;
    }

    test('缺标签曲目被测出增益写库，有标签的不碰；专辑增益补齐；扫过的不再扫', () async {
      if (!await _ffmpegAvailable()) {
        markTestSkipped('本机没有可用 FFmpeg（CI Linux runner 未装），跳过真跑用例');
        return;
      }
      final String loud = await tone('loud.flac', 4);
      final String quiet = await tone('quiet.flac', 1);
      await db
          .into(db.musicTracks)
          .insert(_track('loud', path: loud, albumUid: 'al'));
      await db
          .into(db.musicTracks)
          .insert(_track('quiet', path: quiet, albumUid: 'al'));
      await db
          .into(db.musicTracks)
          .insert(_track('tagged', path: quiet, gain: -7.5));
      int runs = 0;
      final MusicLoudnessScanner scanner = MusicLoudnessScanner(
        database: () => db,
        enabled: () => true,
        ffmpeg: () {
          runs++;
          return resolveFfmpegBackend();
        },
      );
      await scanner.schedule();
      expect(runs, 2, reason: '只测两首缺标签的');
      final MusicTrackRow l = (await db.getMusicTrack('loud'))!;
      final MusicTrackRow q = (await db.getMusicTrack('quiet'))!;
      final MusicTrackRow t = (await db.getMusicTrack('tagged'))!;
      expect(l.r128ScannedAt, isNotNull);
      expect(t.rgTrackGain, -7.5);
      expect(t.r128ScannedAt, isNull);
      // 振幅 ×4 = +12.04 dB：响的那首增益应低约 12 dB。
      expect(q.rgTrackGain! - l.rgTrackGain!, closeTo(12.04, 0.2));
      expect(l.rgTrackPeak, isNotNull);
      expect(l.rgAlbumGain, isNotNull);
      expect(l.rgAlbumGain, q.rgAlbumGain);
      // 专辑在两首之间、偏向响的那首（能量平均）。
      expect(l.rgAlbumGain!, lessThan(q.rgTrackGain!));
      expect(l.rgAlbumGain!, greaterThan(l.rgTrackGain!));
      expect(l.rgAlbumPeak, l.rgTrackPeak);
      await scanner.schedule();
      expect(runs, 2, reason: '扫过的曲目不再重扫');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}

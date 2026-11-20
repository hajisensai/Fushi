/// 歌曲制卡句子音频的响度（issue #3405）：片段按「播放时听到的响度」截，而不是源文件的
/// 原始电平。
///
/// 播放侧由 mpv 后端按曲目施加 ReplayGain（[musicReplayGainDb]：标签 / EBU R128 扫描的
/// 增益 + preamp，按峰值限幅），音量滑块再叠在上面。制卡以前直接按原始电平裁，流行歌母带
/// 常在 -8～-10 LUFS，卡里的句子比视频对白卡响一大截。这里给出片段该加的增益：
///
/// * ReplayGain 关：0 dB（播放时也是原始电平，卡与播放一致）。
/// * ReplayGain 开、曲目有增益数据：与播放同一份算法（同模式、同 preamp、同峰值限幅）。
/// * ReplayGain 开、曲目没有增益数据（插件 / YouTube 流、还没扫描到）：对这一小段测
///   `ebur128`，归一到 ReplayGain 2.0 参考响度（[kReplayGain2ReferenceLufs]）+ preamp，
///   按真峰值限幅到 0 dBTP。测不出（静音 / 太短 / FFmpeg 失败）按 0 dB，并记日志。
///
/// **不照搬音量滑块**：滑块是相对当下设备 / 系统音量的临时偏好，烤进卡里换到手机 /
/// AnkiWeb 上可能几乎听不见，且不同时间制的卡忽大忽小、不可逆。
library;

import 'dart:math' as math;

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show buildFfmpegRemoteInputArgs;

import 'package:fushi/src/media/music/music_loudness_scanner.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 测一段源音频的响度（[inputPath] 的 `[startMs, endMs)`，文件时间）。测不出返回 null。
typedef MusicClipLoudnessMeasurer =
    Future<MusicLoudnessMeasurement?> Function({
      required String inputPath,
      required Map<String, String> httpHeaders,
      required int startMs,
      required int endMs,
    });

/// 纯函数：不用测就能定的增益。ReplayGain 关 → 0；开且曲目有增益数据 → 与播放同一份
/// 增益；开但没有任何增益数据 → null（调用方去测片段）。
double? musicClipKnownGainDb({
  required MusicPlayItem item,
  required MusicOutputSettings settings,
}) {
  if (settings.replayGain == MusicReplayGainMode.off) return 0;
  if (item.rgTrackGain == null && item.rgAlbumGain == null) return null;
  return musicReplayGainDb(
    albumMode: settings.replayGain == MusicReplayGainMode.album,
    trackGain: item.rgTrackGain,
    trackPeak: item.rgTrackPeak,
    albumGain: item.rgAlbumGain,
    albumPeak: item.rgAlbumPeak,
    preampDb: settings.replayGainPreampDb,
  );
}

/// 纯函数：片段测量值 → 增益。归一到参考响度 + [preampDb]，再按真峰值限幅到 0 dBTP
/// （与 [musicReplayGainDb] 的峰值限幅同口径）。测不出响度（静音）返回 null。
double? musicClipGainFromMeasurement(
  MusicLoudnessMeasurement measurement, {
  required double preampDb,
}) {
  final double? gain = measurement.replayGainDb;
  if (gain == null) return null;
  double db = gain + preampDb;
  final double? peak = measurement.truePeakDbtp;
  if (peak != null) db = math.min(db, -peak);
  return db;
}

/// 纯函数：FFmpeg 参数，测 [inputPath] 的 `[startMs, endMs)` 一段。远端输入带上与裁剪
/// 同一组连接参数（[buildFfmpegRemoteInputArgs]），起止写法与裁剪相同（`-ss`/`-t` 在
/// `-i` 前），测的就是要写进卡的那一段。
List<String> musicClipEbur128Args({
  required String inputPath,
  required int startMs,
  required int endMs,
  Map<String, String> httpHeaders = const <String, String>{},
}) => <String>[
  '-hide_banner',
  '-nostats',
  ...buildFfmpegRemoteInputArgs(inputPath, httpHeaders: httpHeaders),
  '-ss',
  (startMs / 1000).toStringAsFixed(3),
  '-t',
  ((endMs - startMs) / 1000).toStringAsFixed(3),
  '-i',
  inputPath,
  '-vn',
  '-filter:a',
  'ebur128=peak=true',
  '-f',
  'null',
  '-',
];

/// 一段句子音频的测量上限（本机文件 / 已物化的流毫秒级；远端直链按网速）。
const Duration _kMeasureTimeout = Duration(seconds: 60);

/// 缺省测量：走 app 统一的 FFmpeg 后端（[resolveFfmpegBackend]），与响度扫描同一个解析
/// （[parseEbur128Summary]）。FFmpeg 失败返回 null 并记日志。
Future<MusicLoudnessMeasurement?> measureMusicClipLoudness({
  required String inputPath,
  required Map<String, String> httpHeaders,
  required int startMs,
  required int endMs,
}) async {
  final FfmpegRunResult r = await resolveFfmpegBackend().run(
    musicClipEbur128Args(
      inputPath: inputPath,
      startMs: startMs,
      endMs: endMs,
      httpHeaders: httpHeaders,
    ),
    _kMeasureTimeout,
  );
  if (!r.isSuccess) {
    ErrorLogService.instance.log(
      'musicClipGain.measure',
      'ebur128 failed: ${r.failureSummary}',
      StackTrace.current,
    );
    return null;
  }
  return parseEbur128Summary(r.output);
}

/// 制卡片段该加的增益（dB）。见文件头的三种情况；[inputPath]、[startMs]、[endMs] 是
/// 交给裁剪的同一组源与文件时间。测不出时按 0 dB（片段仍照常写卡），原因进日志。
Future<double> resolveMusicClipGainDb({
  required MusicPlayItem item,
  required MusicOutputSettings settings,
  required String inputPath,
  required Map<String, String> httpHeaders,
  required int startMs,
  required int endMs,
  MusicClipLoudnessMeasurer measurer = measureMusicClipLoudness,
}) async {
  final double? known = musicClipKnownGainDb(item: item, settings: settings);
  if (known != null) return known;
  final MusicLoudnessMeasurement? m = await measurer(
    inputPath: inputPath,
    httpHeaders: httpHeaders,
    startMs: startMs,
    endMs: endMs,
  );
  final double? measured = m == null
      ? null
      : musicClipGainFromMeasurement(m, preampDb: settings.replayGainPreampDb);
  if (measured == null) {
    ErrorLogService.instance.log(
      'musicClipGain',
      'no loudness for ${item.trackUid} [$startMs, $endMs); clip kept at 0 dB',
      StackTrace.current,
    );
    return 0;
  }
  return measured;
}

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/utils/misc/synchronized_video_exporter.dart'
    show FfmpegMuxedBytes, parseFfmpegMuxedBytes;

/// 校验解码用的 PCM 规格：单声道 16 kHz s16le，每毫秒 32 字节。
const int _kProbeSampleRate = 16000;
const int _kProbeBytesPerMs = _kProbeSampleRate * 2 ~/ 1000;

/// 时间窗内实际解码出的音频至少要有窗长的这么多，才算副本里的音轨完整。
///
/// 坏副本的实测比例约 1/8（见 [cachedSnapshotAudioCoversWindow]），正常副本恒为
/// 1.0（± ffmpeg 统计行把 KiB 四舍五入到整数的 16 ms），阈值落在中间、两头都远。
const double kSnapshotAudioMinCoverage = 0.9;

/// 解码时间窗 `[startMs, endMs)` 的第一条音轨，丢弃输出、只留收尾统计行。
///
/// 解成固定规格的 PCM，统计行里的 `audio:<n>KiB` 就是**真实采样数**换算出的长度。
/// 不能用进度行的 `time=`：它取的是时间戳，副本里稀疏的音频包照样把它撑满整个窗。
List<String> buildSnapshotAudioCoverageArgs({
  required String inputPath,
  required int startMs,
  required int endMs,
}) => <String>[
  '-hide_banner',
  '-ss',
  (startMs / 1000).toStringAsFixed(3),
  '-t',
  ((endMs - startMs) / 1000).toStringAsFixed(3),
  '-i',
  inputPath,
  '-map',
  '0:a:0',
  '-vn',
  '-sn',
  '-dn',
  '-c:a',
  'pcm_s16le',
  '-ac',
  '1',
  '-ar',
  '$_kProbeSampleRate',
  '-f',
  'null',
  '-',
];

/// 纯函数：解码出的 PCM 体积（[decodedAudioKiB]，规格见 [buildSnapshotAudioCoverageArgs]）
/// 是否覆盖了 [windowMs] 长的时间窗。
bool snapshotAudioCoversWindow({
  required double decodedAudioKiB,
  required int windowMs,
}) {
  if (windowMs <= 0) return true;
  final double decodedMs = decodedAudioKiB * 1024 / _kProbeBytesPerMs;
  return decodedMs >= windowMs * kSnapshotAudioMinCoverage;
}

/// 播放器缓冲副本（libmpv `dump-cache` 写出的 mkv）在 `[startMs, endMs)`（副本自己的
/// 时间轴）里的音轨是否完整。
///
/// 副本可能「写成功了但音频缺了一大半」：mpv 的 mkv demuxer 对 lacing 块只给第一帧
/// 时间戳，块里其余帧的 PTS/DTS 都是空的（源轨没有 `DefaultDuration` 时，例如 mkvmerge
/// 封装的 Opus）；随包 libmpv 的 FFmpeg 9 matroska muxer 把这些包全部拒收（`non
/// monotonically increasing dts ... >= NOPTS` / `recorder: Failed writing packet`），
/// 副本里每个块只剩一帧，而 mpv 照样报 `Cache dumping successfully ended`。拿这样的
/// 副本制卡，句子音频只剩 0.2～0.4 秒且断断续续。mpv 把日志排在命令回包之后投递，
/// 制卡时拿不到可靠的失败信号，所以直接看副本的内容。
///
/// 探不出（ffmpeg 失败、没有音轨、没有统计行）一律返回 false：副本只是加速手段，
/// 调用方回到远端抽取，不会因此丢卡。
Future<bool> cachedSnapshotAudioCoversWindow({
  required String snapshotPath,
  required int startMs,
  required int endMs,
  FfmpegBackend? backend,
  Duration timeout = const Duration(seconds: 30),
}) async {
  if (endMs <= startMs) return true;
  try {
    final FfmpegRunResult result = await (backend ?? resolveFfmpegBackend())
        .run(
          buildSnapshotAudioCoverageArgs(
            inputPath: snapshotPath,
            startMs: startMs,
            endMs: endMs,
          ),
          timeout,
        );
    if (!result.isSuccess) return false;
    final FfmpegMuxedBytes? muxed = parseFfmpegMuxedBytes(result.output);
    if (muxed == null) return false;
    return snapshotAudioCoversWindow(
      decodedAudioKiB: muxed.audioKiB,
      windowMs: endMs - startMs,
    );
  } catch (_) {
    return false;
  }
}

/// S3 校对的「画面参考」（spec `2026-11-11-video-subtitle-ai-reference`）：每批台词附上
/// 对应时刻的视频画面，让能收图的模型用画面里的文字（招牌 / 信件 / 屏幕 / 名牌 /
/// 烧录字幕）、说话人和场景判断人名、用语、同音词。
///
/// - 取哪些时刻是纯函数 [planSubtitleReferenceFrames]：批内各行的中点，相邻两张至少隔
///   [kSubtitleReferenceFrameMinGapMs]，超过 [kSubtitleReferenceFramesPerBatch] 张就
///   均匀抽稀——一批 30 句约一两分钟，十张足够覆盖场景变化，也不让图片淹没正文。
/// - 取帧是可注入的 [SubtitleFrameSource]：生产实现 [ffmpegSubtitleFrameSource] 走
///   全仓唯一的 ffmpeg 出口（引擎不能碰播放器）；没有本机媒体字节的路径（网络流 /
///   `.strm`）不取。
/// - **画面只能让字幕更好，不能让生成失败**：单张取不到就少一张，一张都没有这一批
///   就按纯文字校对。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart' show fushiDebugPrint;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/embedded_reference_subtitle_sync.dart'
    show isNetworkMediaPath;
import 'package:fushi_engine/media/video/video_member_file.dart'
    show hasLocalMediaFile;
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show extractVideoFrameViaFfmpeg;
import 'package:path/path.dart' as p;

/// 一批最多附几张画面。
const int kSubtitleReferenceFramesPerBatch = 10;

/// 相邻两张画面至少隔多久：连着的短句共用一张。
const int kSubtitleReferenceFrameMinGapMs = 4000;

/// 画面缩到多宽再发（高按比例）：768 时 16:9 画面里的招牌 / 烧录字幕仍可读，
/// 三家协议的图片计费都还在一两格之内。
const int kSubtitleReferenceFrameWidth = 768;

/// 费用预估里一张画面按多少输入 token 算。768×432：Anthropic 约 440（宽×高÷750），
/// OpenAI 高清档 2 格约 425，Gemini 约 520——预估宁可偏贵。
const int kSubtitleReferenceFrameTokens = 600;

/// 取 [videoPath] 在 [atMs] 的一帧：JPEG 字节（已缩到 [kSubtitleReferenceFrameWidth]
/// 宽）；取不到返回 null。实现不得抛出「取不到」这类预期内的失败。
typedef SubtitleFrameSource =
    Future<Uint8List?> Function(String videoPath, int atMs);

/// 一集的画面参考装配：给 `SubtitleProofreader.proofread`。
class SubtitleProofreadFrames {
  const SubtitleProofreadFrames({
    required this.videoPath,
    required this.source,
    this.maxFramesPerBatch = kSubtitleReferenceFramesPerBatch,
    this.minGapMs = kSubtitleReferenceFrameMinGapMs,
  }) : assert(maxFramesPerBatch > 0 && minGapMs >= 0);

  final String videoPath;
  final SubtitleFrameSource source;
  final int maxFramesPerBatch;
  final int minGapMs;
}

/// 一张取到的画面。
class SubtitleReferenceFrame {
  const SubtitleReferenceFrame({required this.atMs, required this.bytes});

  final int atMs;

  /// JPEG 字节。
  final Uint8List bytes;
}

/// **纯函数**：`cues[lo, hi)` 这一批该看哪些时刻（毫秒，升序）。
///
/// 每行取中点（台词说到一半时说话人与相关画面最可能在镜头里）；空文本行不取；与上
/// 一张相隔不足 [minGapMs] 的跳过；多于 [maxFrames] 张时按序号均匀抽稀（保留首尾）。
List<int> planSubtitleReferenceFrames(
  List<SubtitleDraftCue> cues,
  int lo,
  int hi, {
  int maxFrames = kSubtitleReferenceFramesPerBatch,
  int minGapMs = kSubtitleReferenceFrameMinGapMs,
}) {
  if (maxFrames <= 0) return const <int>[];
  final List<int> picked = <int>[];
  final int end = hi > cues.length ? cues.length : hi;
  for (int i = lo < 0 ? 0 : lo; i < end; i++) {
    final SubtitleDraftCue c = cues[i];
    if (c.text.trim().isEmpty) continue;
    final int span = c.endMs > c.startMs ? c.endMs - c.startMs : 0;
    final int at = c.startMs + span ~/ 2;
    if (picked.isNotEmpty && at - picked.last < minGapMs) continue;
    picked.add(at);
  }
  if (picked.length <= maxFrames) return picked;
  if (maxFrames == 1) return <int>[picked[picked.length ~/ 2]];
  return <int>[
    for (int k = 0; k < maxFrames; k++)
      picked[(k * (picked.length - 1) / (maxFrames - 1)).round()],
  ];
}

/// 按 [timestamps] 逐张取帧。取不到的跳过（只记诊断日志）；取消照常抛
/// [SubtitlePipelineCancelled]。
Future<List<SubtitleReferenceFrame>> loadSubtitleReferenceFrames(
  SubtitleProofreadFrames frames,
  List<int> timestamps, {
  SubtitleCancelToken cancel = const SubtitleNeverCancel(),
}) async {
  final List<SubtitleReferenceFrame> out = <SubtitleReferenceFrame>[];
  for (final int at in timestamps) {
    throwIfSubtitleCancelled(cancel);
    Uint8List? bytes;
    try {
      bytes = await frames.source(frames.videoPath, at);
    } on SubtitlePipelineCancelled {
      rethrow;
    } on Exception catch (error) {
      fushiDebugPrint(
        '[SubtitleFrameReference] ${p.basename(frames.videoPath)} @$at ms: '
        '$error',
      );
    }
    if (bytes == null || bytes.isEmpty) continue;
    out.add(SubtitleReferenceFrame(atMs: at, bytes: bytes));
  }
  return out;
}

/// 生产取帧：ffmpeg 输入定位抽一帧，缩到 [kSubtitleReferenceFrameWidth] 宽的 JPEG。
/// 没有本机媒体字节（网络流 / `.strm` / 文件不在）→ null：逐帧对网络源开连接定位太慢，
/// 与证据收集「网络路径不 demux 整片」同一口径。
Future<Uint8List?> ffmpegSubtitleFrameSource(String videoPath, int atMs) async {
  if (isNetworkMediaPath(videoPath) || !await hasLocalMediaFile(videoPath)) {
    return null;
  }
  final Directory tmp = await Directory.systemTemp.createTemp(
    'fushi_subtitle_frame_',
  );
  try {
    final String? produced = await extractVideoFrameViaFfmpeg(
      inputPath: videoPath,
      outputPath: p.join(tmp.path, 'frame.jpg'),
      atSeconds: atMs / 1000,
      scaleWidth: kSubtitleReferenceFrameWidth,
      // 取不到（定位落在片尾之后、没有视频流的纯音频）是预期内的结果，不算错误。
      diagnosticOnly: true,
    );
    if (produced == null) return null;
    return await File(produced).readAsBytes();
  } finally {
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // 临时目录删不掉不影响结果，留给系统清理。
    }
  }
}

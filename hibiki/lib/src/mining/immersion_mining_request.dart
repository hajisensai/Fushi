import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki_anki/hibiki_anki.dart' show AnkiMiningSource;

/// 沉浸制卡片段音频的容器扩展名，按平台分（TODO-1217 / BUG-460）：
/// - iOS：`m4a`——AnkiMobile 只自动下载它识别为媒体的 localhost URL，`.aac` 裸流会被当成
///   可见文本不下载（da22cd42a）；iOS 端 ffmpeg-kit 自带 ipod muxer，能产出 `.m4a`。
/// - 桌面 / Android：`aac`（adts）——桌面捆绑的 ffmpeg-min
///   （`tool/ffmpeg-min/build-ffmpeg-min.sh` 的 MUXERS 白名单只有 adts，无 ipod/mp4/m4a）
///   写 `.m4a` 会自动选一个不存在的 ipod muxer → `Unable to choose output format` /
///   exit -22 → `extractAudioSegmentViaFfmpeg` 返 null → 音频丢（桌面网飞/YouTube/应用内
///   视频制卡有图无声，正是 da22cd42a 的桌面回归）；Android AnkiDroid 历来接受 `.aac`（BUG-460）。
///
/// 纯逻辑放在 [immersionMiningAudioExtensionFor]，便于对两分支单测（测试宿主上
/// `Platform.isIOS` 恒为 false，无法直接覆盖 iOS 分支）。
String immersionMiningAudioExtensionFor({required bool isIOS}) =>
    isIOS ? 'm4a' : 'aac';

/// 当前运行平台下沉浸制卡片段音频的容器扩展名（见 [immersionMiningAudioExtensionFor]）。
String immersionMiningAudioExtension() =>
    immersionMiningAudioExtensionFor(isIOS: Platform.isIOS);

/// 统一沉浸制卡请求。任何来源（本地/YouTube/Netflix）都构造这个喂 [ImmersionMiningEngine]。
///
/// [mediaSource] 是 ffmpeg 的 inputPath——本地绝对路径 或 可 seek 的 http 流 URL。
/// 若 [mediaSource] 为 null（如 Netflix 前台无本地源），引擎只用 [stillFallback] /
/// [providedCoverBytes] / [providedAudioBytes] 组卡。
class ImmersionMiningRequest {
  const ImmersionMiningRequest({
    required this.fields,
    required this.clipStartMs,
    required this.clipEndMs,
    required this.sentence,
    this.mediaSource,
    this.audioSource,
    this.cueSentence,
    this.documentTitle,
    this.audioStreamIndex,
    this.audioStreamCount,
    this.source = AnkiMiningSource.video,
    this.bookTitleTag,
    this.updateNoteId,
    this.stillFallback,
    this.providedCoverBytes,
    this.providedCoverName,
    this.providedAudioBytes,
    this.providedAudioName,
    this.requireAudio = true,
  });

  final Map<String, String> fields;
  final int clipStartMs;
  final int clipEndMs;
  final String sentence;
  final String? mediaSource;

  /// 音频段抽取源（ffmpeg inputPath）。null = 用 [mediaSource]（本地文件/muxed）。
  /// YouTube 分离流时 = audio-only 流 URL（视频流无音轨，音频得从这里裁）。
  final String? audioSource;
  final String? cueSentence;
  final String? documentTitle;
  final int? audioStreamIndex;
  final int? audioStreamCount;
  final AnkiMiningSource source;
  final String? bookTitleTag;

  /// 非 null = 覆盖现有卡（走 updateMinedNote，不计统计）。
  final int? updateNoteId;

  /// 当前解码帧兜底（本地路径链全失败时）。本地传 `controller.screenshot`。
  final Future<Uint8List?> Function()? stillFallback;

  /// 外部已抓好的封面/音频字节（Netflix 后台实例直接给字节，无本地文件）。
  final Uint8List? providedCoverBytes;
  final String? providedCoverName;
  final Uint8List? providedAudioBytes;
  final String? providedAudioName;

  /// true = 无音频则中止制卡（本地/YouTube 默认）；false = 允许无音频卡（Netflix 2A 截图卡）。
  final bool requireAudio;

  bool get hasRange => clipEndMs > clipStartMs;
}

/// 引擎产出。[outcome] 用 Object? 承 MineOutcome，避免此值对象文件依赖 anki_models 全量。
class ImmersionMiningResult {
  const ImmersionMiningResult({
    required this.aborted,
    this.outcome,
    this.degradedToStill = false,
    this.abortReason,
  });

  /// true = 因缺音频等前置条件中止，未调后端。
  final bool aborted;

  /// MineOutcome（成功路径）。
  final Object? outcome;
  final bool degradedToStill;

  /// TODO-1303：仅在 [aborted] 时非空——中止的人类可读原因（缺音频 / 空壳卡）。远端
  /// 制卡（浏览器扩展）据此把失败原因写进错误日志并随响应体回传，终结「制卡失败报成功
  /// + 诊断黑洞」。null（成功路径）时无诊断。
  final String? abortReason;
}

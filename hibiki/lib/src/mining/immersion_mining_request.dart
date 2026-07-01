import 'dart:typed_data';

import 'package:hibiki_anki/hibiki_anki.dart' show AnkiMiningSource;

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
  });

  /// true = 因缺音频等前置条件中止，未调后端。
  final bool aborted;

  /// MineOutcome（成功路径）。
  final Object? outcome;
  final bool degradedToStill;
}

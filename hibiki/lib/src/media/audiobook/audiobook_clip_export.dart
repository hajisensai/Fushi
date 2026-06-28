import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-945 M1：把「有声书查词选区 → 整句 cue 区间」的边界判定抽成纯函数，方便单测
/// 覆盖所有兜底分支（空选区 / 纯外字 / 跨章 / 跨音频文件），并让弹窗入口只负责收集
/// 输入 + 按结果路由（导出 / toast）。
///
/// 这里**不**做任何 ffmpeg / 视频合成（留给 M2-M5）；M1 仅把选区扩成单 cue / 单文件的
/// [AudioPlaybackRange] 并暴露所有无法导出的边界。

/// 选区 → 整句 cue 区间的分类结果（M1）。
enum AudiobookClipBoundaryKind {
  /// 选中文本为空（含纯外字图选区：JS 端选区文本会剔除 gaiji 图，纯外字 → 空文本）。
  emptySelection,

  /// 本书没有可用音频文件（无声书 / 控制器未就绪）。无音频不可能裁片段。
  noAudio,

  /// 选区命中文本，但 `_sentenceAudioRangeFor` 解析不出可裁区间。
  ///
  /// 实测覆盖两类：①跨章选区——cue 解析落空（`miningSentenceAudioRange` 返回 null）；
  /// ②跨音频文件选区——helper 天生只返回**单个** `audioFileIndex`，跨文件时只会落在
  /// 它命中的那一段或返回 null，永远不会拼出跨文件区间。两类在 M1 都走兜底提示，不导出。
  unsupportedRange,

  /// 可导出：拿到单 cue / 单文件的有效区间。
  exportable,
}

/// 选区 → 整句 cue 区间的判定结果（M1，纯数据）。
class AudiobookClipBoundaryResult {
  const AudiobookClipBoundaryResult({
    required this.kind,
    this.range,
  });

  final AudiobookClipBoundaryKind kind;

  /// 仅当 [kind] == [AudiobookClipBoundaryKind.exportable] 时非空，且
  /// `audioFileIndex` 已校验落在 [0, audioFileCount)。
  final AudioPlaybackRange? range;

  bool get isExportable => kind == AudiobookClipBoundaryKind.exportable;
}

/// 把「选中文本 + 整句音频区间 + 音频文件数」分类成 M1 的可导出 / 兜底结果。
///
/// 入参语义：
/// - [selectedText]：弹窗当前选中的词/片段文本（JS 端已剔除外字图；纯外字 → 空串）。
/// - [audioFileCount]：本会话可用音频文件数（控制器 `audioFiles?.length`，无音频传 0）。
/// - [sentenceRange]：`_sentenceAudioRangeFor(...)` 已算出的单 cue / 单文件区间（可空）。
///
/// 判定顺序固定（先空选区 → 再无音频 → 再无区间 → 否则可导出），保证每个分支互斥、
/// 可被单测逐一命中。**不**在这里访问任何可变 reader 状态，便于纯函数测试。
AudiobookClipBoundaryResult classifyAudiobookClipSelection({
  required String selectedText,
  required int audioFileCount,
  required AudioPlaybackRange? sentenceRange,
}) {
  if (selectedText.trim().isEmpty) {
    return const AudiobookClipBoundaryResult(
      kind: AudiobookClipBoundaryKind.emptySelection,
    );
  }
  if (audioFileCount <= 0) {
    return const AudiobookClipBoundaryResult(
      kind: AudiobookClipBoundaryKind.noAudio,
    );
  }
  final AudioPlaybackRange? range = sentenceRange;
  if (range == null ||
      range.audioFileIndex < 0 ||
      range.audioFileIndex >= audioFileCount ||
      range.endMs <= range.startMs) {
    return const AudiobookClipBoundaryResult(
      kind: AudiobookClipBoundaryKind.unsupportedRange,
    );
  }
  return AudiobookClipBoundaryResult(
    kind: AudiobookClipBoundaryKind.exportable,
    range: range,
  );
}

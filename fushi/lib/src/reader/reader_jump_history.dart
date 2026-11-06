import 'package:fushi/src/utils/misc/jump_history.dart';

// 小说阅读器「跳转回退」的落脚点：跳章 / 目录 / 内链 / 搜索 / 收藏 / 字数跳转，
// 以及有声书拖进度、点句、章节定位等非连续移动之前的位置（历史栈见
// JumpHistory，落地由阅读器页按 kind 分派）。

/// 一次跳转移动的是什么：决定「回去」时恢复哪条轴。
enum ReaderJumpKind {
  /// 正文跳转（目录 / 内链 / 搜索 / 收藏 / 字数跳转）：只恢复正文位置，不动音频。
  text,

  /// 音频跳转（拖进度、点句播放、有声书章节定位、歌词模式跳章）：恢复音频位置，
  /// 正文跟随当前句。
  audio,
}

class ReaderJumpPoint {
  const ReaderJumpPoint({
    required this.kind,
    required this.chapter,
    required this.progress,
    required this.charOffset,
    this.audioGlobalMs,
  });

  /// 音频落点相差不到这么多毫秒算同一处。
  static const int sameAudioPlaceMs = 1000;

  final ReaderJumpKind kind;

  /// 章（spine）下标。
  final int chapter;

  /// 章内进度分数 0~1（[charOffset] 缺失时的落点）。
  final double progress;

  /// 章内学习单位偏移（JS `getNormalizedOffset` 口径）；-1 = 无精确锚。
  final int charOffset;

  /// 全书时间轴毫秒；[kind] 为 [ReaderJumpKind.audio] 时必有。
  final int? audioGlobalMs;

  /// 两个点是否「同一处」：同一处不重复压栈（连点两次同一目录项、来回点同一句）。
  bool isSamePlaceAs(ReaderJumpPoint other) {
    if (kind != other.kind) return false;
    if (kind == ReaderJumpKind.audio) {
      final int a = audioGlobalMs ?? 0;
      final int b = other.audioGlobalMs ?? 0;
      return (a - b).abs() < sameAudioPlaceMs;
    }
    if (chapter != other.chapter) return false;
    if (charOffset >= 0 && other.charOffset >= 0) {
      return charOffset == other.charOffset;
    }
    return (progress - other.progress).abs() < 0.001;
  }

  @override
  String toString() =>
      'ReaderJumpPoint($kind, ch=$chapter, p=$progress, off=$charOffset, '
      'ms=$audioGlobalMs)';
}

/// 小说阅读器的跳转历史。
JumpHistory<ReaderJumpPoint> newReaderJumpHistory() =>
    JumpHistory<ReaderJumpPoint>(
      isSamePlace: (ReaderJumpPoint a, ReaderJumpPoint b) => a.isSamePlaceAs(b),
    );

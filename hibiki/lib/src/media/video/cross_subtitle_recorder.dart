import 'package:flutter/foundation.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// 跨字幕制卡（区间录制，TODO-102；参考 asbplayer）。
///
/// 一种「区间录制」制卡模式：第一次按下=**开始**（记录按下时正在学的那条字幕作起始
/// cue 并继续播放），播放到想要的结束句再按一次=**结束**（记录结束 cue）。把起始 cue 到
/// 结束 cue 之间**所有字幕文本拼接** + 这段**区间音频** `[起始cue.startMs, 结束cue.endMs]`
/// 抽成一个音频片段，合并到**一张** Anki 卡。
///
/// 本类只承载**纯逻辑 + 录制态**（idle ⇄ recording），不碰播放器 / ffmpeg / Anki——这些
/// 副作用留在 [VideoHibikiPage]。media_kit 跑不了 headless，故把区间计算、文本拼接、退化
/// 单句这些可测不变量收敛到这里用纯函数单测覆盖（真音频抽取靠真机）。
///
/// 录制态用 [ValueNotifier] 暴露 [isRecording]：与 `_subtitleListVisible` /
/// `_immersiveLocked` 同源——录制中的视觉反馈（OSD / 按钮高亮）渲染在 media_kit controls
/// builder 内的 Stack 里，全屏是推到根 navigator 的独立路由、不随页面 setState 重建
/// （BUG-120），监听 notifier 才能在窗口与全屏两种场景都跟随录制态翻转。
class CrossSubtitleRecorder {
  /// 录制是否进行中（全屏路由也响应；与 `_immersiveLocked` 同源，BUG-120）。
  final ValueNotifier<bool> isRecording = ValueNotifier<bool>(false);

  /// 录制起始 cue 下标（按下「开始」那一刻解析到的当前句）；未录制时为 null。
  int? _startCueIndex;

  /// 仅测试可见：当前录制起点（断言录制态用）。
  @visibleForTesting
  int? get debugStartCueIndex => _startCueIndex;

  /// 开始录制：记录起点 [startCueIndex]（已由调用方按位置解析、含 gap 兜底），置位录制态。
  ///
  /// [startCueIndex] 为 null（无字幕 / 位置早于全部 cue，一句都没起播）时拒绝开始，返回
  /// false——跨字幕制卡必须落在真实字幕上，否则没有可拼接的文本/可裁的区间。
  bool start(int? startCueIndex) {
    if (startCueIndex == null || startCueIndex < 0) return false;
    _startCueIndex = startCueIndex;
    isRecording.value = true;
    return true;
  }

  /// 结束录制：用结束 cue 下标 [endCueIndex] 与起点规范化成升序区间，复位录制态。
  ///
  /// 返回区间选择（[CrossSubtitleSelection]）；起点缺失 / [endCueIndex] 非法时返回 null
  /// （不应发生——录制态保证 start 已成功，但防御性兜底）。startIdx == endIdx（只按了一下
  /// 没动）退化成单句区间（[CrossSubtitleSelection.isSingleCue] 为真），由调用方走原单句制卡。
  CrossSubtitleSelection? stop(int? endCueIndex) {
    final int? startIndex = _startCueIndex;
    _startCueIndex = null;
    isRecording.value = false;
    if (startIndex == null) return null;
    if (endCueIndex == null || endCueIndex < 0) {
      // 结束时位置不在任何 cue（且无 floor）：退化成只录起始那一句，不丢用户这次录制。
      return CrossSubtitleSelection(
          startIndex: startIndex, endIndex: startIndex);
    }
    return CrossSubtitleSelection.normalized(startIndex, endCueIndex);
  }

  /// 取消录制（换集 / dispose）：直接复位，不产出区间。
  void cancel() {
    _startCueIndex = null;
    isRecording.value = false;
  }

  void dispose() {
    isRecording.dispose();
  }
}

/// 跨字幕区间选择结果：规范化后的升序 cue 下标区间 `[startIndex, endIndex]`（闭区间，含
/// 两端）。所有派生（文本拼接 / 音频区间）都从这两个下标 + cue 列表算出，无冗余状态。
@immutable
class CrossSubtitleSelection {
  const CrossSubtitleSelection({
    required this.startIndex,
    required this.endIndex,
  });

  /// 把任意先后顺序的两个下标规范化成升序闭区间（用户可能从后往前录，或结束句早于起始
  /// 句——一律取 min/max，保证 startIndex <= endIndex）。
  factory CrossSubtitleSelection.normalized(int a, int b) {
    return CrossSubtitleSelection(
      startIndex: a <= b ? a : b,
      endIndex: a <= b ? b : a,
    );
  }

  final int startIndex;
  final int endIndex;

  /// 起止同一句：退化成单句制卡（用户只按了一下没动，或起止落在同一条字幕）。
  bool get isSingleCue => startIndex == endIndex;

  /// 区间覆盖的字幕句数（含两端）。
  int get cueCount => endIndex - startIndex + 1;

  /// 拼接区间内所有 cue 的文本（[startIndex]..[endIndex] 顺序），用 [separator] 连接。
  ///
  /// 越界保护：下标超出 [cues] 范围时按可用范围 clamp（防御性，正常不发生）。空文本 cue
  /// 跳过（不产出多余分隔符）。结果作 Anki 句子字段。
  String joinText(List<AudioCue> cues, {String separator = '\n'}) {
    if (cues.isEmpty) return '';
    final int lo = startIndex.clamp(0, cues.length - 1);
    final int hi = endIndex.clamp(0, cues.length - 1);
    final List<String> parts = <String>[];
    for (int i = lo; i <= hi; i++) {
      final String text = cues[i].text.trim();
      if (text.isNotEmpty) parts.add(text);
    }
    return parts.join(separator);
  }

  /// 区间音频范围 `[cues[startIndex].startMs, cues[endIndex].endMs]`。
  ///
  /// **不逐句抽再拼**——直接一个连续区间（用户要的就是「中间所有语音连续录到一张卡」），
  /// 复用 [extractAudioSegmentViaFfmpeg]（它本就接受任意 startMs/endMs，非单 cue）。
  /// [delayMs] 是用户的全局音画延迟：区间是按「用户看到的字幕」时间算的，抽真实声轨音频
  /// 时要把延迟加回去（与有声书 [miningSentenceAudioRange] 的 delay 处理同向）。
  /// 返回 null：cues 空 / 下标全越界 / 算出的区间非正（endMs <= startMs）。
  CrossSubtitleAudioRange? audioRange(List<AudioCue> cues, {int delayMs = 0}) {
    if (cues.isEmpty) return null;
    final int lo = startIndex.clamp(0, cues.length - 1);
    final int hi = endIndex.clamp(0, cues.length - 1);
    final int startMs = (cues[lo].startMs + delayMs).clamp(0, 1 << 30);
    final int endMs = (cues[hi].endMs + delayMs).clamp(0, 1 << 30);
    if (endMs <= startMs) return null;
    return CrossSubtitleAudioRange(startMs: startMs, endMs: endMs);
  }

  @override
  bool operator ==(Object other) =>
      other is CrossSubtitleSelection &&
      other.startIndex == startIndex &&
      other.endIndex == endIndex;

  @override
  int get hashCode => Object.hash(startIndex, endIndex);

  @override
  String toString() =>
      'CrossSubtitleSelection(startIndex: $startIndex, endIndex: $endIndex)';
}

/// 跨字幕区间音频范围（毫秒，已含音画延迟）。喂给 [extractAudioSegmentViaFfmpeg] 的
/// [startMs]/[endMs] 契约对象，便于单测断言「抽的就是整段区间」。
@immutable
class CrossSubtitleAudioRange {
  const CrossSubtitleAudioRange({required this.startMs, required this.endMs});

  final int startMs;
  final int endMs;

  @override
  bool operator ==(Object other) =>
      other is CrossSubtitleAudioRange &&
      other.startMs == startMs &&
      other.endMs == endMs;

  @override
  int get hashCode => Object.hash(startMs, endMs);

  @override
  String toString() =>
      'CrossSubtitleAudioRange(startMs: $startMs, endMs: $endMs)';
}

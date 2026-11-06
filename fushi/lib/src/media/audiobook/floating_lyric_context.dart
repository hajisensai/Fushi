import 'package:fushi_audio/fushi_audio.dart';

/// TODO-708 P4：悬浮字幕「显示当前字幕的前后 N 行上下文」纯函数层（路线 A）。
///
/// 设计（Linus 式「消除特殊情况」）：Dart 已持有完整 cue 列表 + 当前索引，原生只画。
/// 这里把「取上下文窗口」和「组装多行文本块 + 当前行块内区间」两件事拆成纯函数，
/// 完全可单测，不碰任何原生 / 平台 / 时序。N=0 时窗口退化为单元素、块退化为单行，
/// 与今天逐字节一致（never-break userspace）。
///
/// 窗口用对称单值 N：返回 cues[index-n .. index+n]，头尾不足少显示（不留空行）。

/// 值对象：一块多行悬浮字幕文本 + 当前行在块内的 UTF-16 区间。
///
/// - [text]：多行文本，行间用 `\n` 连接（原生单 TextView / DWrite 直接渲染）。
/// - [start]：当前行首字符在 [text] 中的 UTF-16 offset；-1 = 无当前行标记
///   （空块 / 未匹配），原生据此退化为无行明暗区分。
/// - [length]：当前行的 UTF-16 长度。start=-1 时为 0。
class FloatingLyricBlock {
  const FloatingLyricBlock({
    required this.text,
    required this.start,
    required this.length,
  });

  /// 空块常量：无当前行（index<0 或空列表），退化为「无行标记」payload。
  static const FloatingLyricBlock empty = FloatingLyricBlock(
    text: '',
    start: -1,
    length: 0,
  );

  final String text;
  final int start;
  final int length;
}

/// 返回以 [index] 为中心、半径 [n] 的上下文窗口文本列表。
///
/// - 有效范围 `[max(0, index-n), min(len-1, index+n)]` 夹取，头尾不足少显示。
/// - [n] 负值按 0 处理（只当前行）。
/// - [index] < 0 或越界（>= 列表长度）或空列表 → 返回空列表（无当前行）。
List<String> floatingLyricContextWindow({
  required List<AudioCue> cues,
  required int index,
  required int n,
}) {
  final int len = cues.length;
  if (len == 0 || index < 0 || index >= len) {
    return const <String>[];
  }
  final int radius = n < 0 ? 0 : n;
  final int start = (index - radius) < 0 ? 0 : (index - radius);
  final int end = (index + radius) > (len - 1) ? (len - 1) : (index + radius);
  final List<String> window = <String>[];
  for (int i = start; i <= end; i++) {
    window.add(cues[i].text);
  }
  return window;
}

/// 组装上下文窗口为单块多行文本，并算出当前行在块内的 UTF-16 区间。
///
/// join 用 `\n`；当前行 offset = 窗口内当前行之前所有行文本长度 + 分隔符数
/// （每个前置行贡献 `行文本.length + 1`）。全部按 String.length（UTF-16 code unit）
/// 计，与原生 SpannableString / DWrite HitTestTextRange 的区间语义一致。
FloatingLyricBlock buildFloatingLyricBlock({
  required List<AudioCue> cues,
  required int index,
  required int n,
}) =>
    buildFloatingLyricBlockRange(cues: cues, index: index, before: n, after: n);

/// [buildFloatingLyricBlock] 的非对称版：当前句之前取 [before] 句、之后取
/// [after] 句（负值按 0），头尾不足少显示。
FloatingLyricBlock buildFloatingLyricBlockRange({
  required List<AudioCue> cues,
  required int index,
  required int before,
  required int after,
}) {
  final int len = cues.length;
  if (len == 0 || index < 0 || index >= len) {
    return FloatingLyricBlock.empty;
  }
  final int lead = before < 0 ? 0 : before;
  final int trail = after < 0 ? 0 : after;
  final int windowStart = (index - lead) < 0 ? 0 : (index - lead);
  final int windowEnd = (index + trail) > (len - 1)
      ? (len - 1)
      : (index + trail);

  final StringBuffer buffer = StringBuffer();
  int currentStart = 0;
  int currentLength = 0;
  for (int i = windowStart; i <= windowEnd; i++) {
    if (i > windowStart) {
      buffer.write('\n');
    }
    final String line = cues[i].text;
    if (i == index) {
      currentStart = buffer.length;
      currentLength = line.length;
    }
    buffer.write(line);
  }
  return FloatingLyricBlock(
    text: buffer.toString(),
    start: currentStart,
    length: currentLength,
  );
}

/// 「同时显示句数」→ 当前句前后各取几句。
///
/// - `1..`：当前句居中，偶数时下文多一句（与歌词模式「往下读」的方向一致）。
/// - `0` = 自动：[autoFillsWindow] 为 true（Windows 原生窗会把当前句滚到视口
///   中央、裁掉超出窗高的部分）时前后各送 [autoRadius] 句，拖高窗口即看到更多；
///   否则（Android TextView 按内容撑高，没有视口可裁）退回 3 句。
({int before, int after}) floatingLyricVisibleSpan(
  int visibleLines, {
  required bool autoFillsWindow,
  int autoRadius = 12,
}) {
  if (visibleLines <= 0) {
    return autoFillsWindow
        ? (before: autoRadius, after: autoRadius)
        : (before: 1, after: 1);
  }
  final int before = (visibleLines - 1) ~/ 2;
  return (before: before, after: visibleLines - 1 - before);
}

/// 把真实集号集合压缩成连续段的共享格式化器（BUG-1986）。
///
/// `{1, 2, 4, 16, 17}` → `EP1–EP2, EP4, EP16–EP17`。
///
/// **为什么是共享的**：视频资源版本卡与字幕版本卡原本各写了一份
/// `min/max` + `'EP$first–EP$last'`，是同一个 bug 的两个副本——只修一处，另一处
/// 照旧把 5 个离散集号显示成 `5 集 (EP1–EP17)`，错误暗示 EP1 到 EP17 连续存在。
/// 根因是「两处 min/max 伪装成范围」，所以真相源只能有一份。
library;

/// 元信息行里最多显示几段。
///
/// 这是**显示**上限，不是数据上限。两张卡的元信息行都是 `maxLines: 1` +
/// `TextOverflow.ellipsis`，而段串排在 `parts` 的第一位；不封顶时，一个组吃满
/// provider 的单次上限（100 条）就能展开到几百字符，把后面的相对时间、体积、
/// **做种数**整体挤出可视区——做种数恰恰是这张卡上最重要的选择信号。修一个显示
/// 错误换掉一个显示信号，不划算。
const int kMaxEpisodeSpansShown = 4;

/// 把 [episodes] 排序后压缩成连续段，超过 [maxSpans] 段时收成
/// 「前若干段 + 省略号 + 最后一段」。
///
/// 超限形态刻意保留**最后一段**：只截前几段会丢掉上界，读者无法判断这个版本到底
/// 覆盖到第几集；保留首尾则「不连续」和「覆盖到哪」两个结论都在。
///
/// 空集合返回空串（调用方据此整段跳过，不要渲染成 `()`）。
String formatEpisodeSpans(
  Set<int> episodes, {
  int maxSpans = kMaxEpisodeSpansShown,
}) {
  if (episodes.isEmpty) return '';
  final List<int> sorted = episodes.toList()..sort();
  final List<String> spans = <String>[];
  int start = sorted.first;
  int end = start;

  void flush() {
    spans.add(start == end ? 'EP$start' : 'EP$start–EP$end');
  }

  for (final int episode in sorted.skip(1)) {
    if (episode == end + 1) {
      end = episode;
      continue;
    }
    flush();
    start = episode;
    end = episode;
  }
  flush();

  if (maxSpans >= 1 && spans.length > maxSpans) {
    // 前 (maxSpans - 1) 段 + 省略号 + 末段。maxSpans == 1 时退化成「首段 + 省略号」，
    // 仍然不会伪装成连续范围。
    final List<String> head = spans.take(maxSpans - 1).toList();
    return <String>[...head, '…', spans.last].join(', ');
  }
  return spans.join(', ');
}

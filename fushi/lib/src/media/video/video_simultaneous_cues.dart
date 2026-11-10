import 'package:fushi_audio/fushi_audio.dart';

// 「同时出现的多行字幕 = 一句」：复制 / 制卡取句的唯一判据（PR #3160 待决策项，
// 反馈 rLCxUJ-2i4）。
//
// ASS 常把一句台词拆成几条起止相同、各带 `\pos` 的 Dialogue（反馈原文两条都是
// `0:07:26.00-0:07:28.30`，Style 都是 Default，一条 y=600 一条 y=680）。解析器每条
// Dialogue 各成一条 cue，复制 / 制卡按单条 cue 取文本，就只能拿到半句。
//
// 两条 cue 算同一句，需同时满足：
// - 起点、终点都严格相等（ASS 时间精度 10ms，同一句拆的行恰好相等，不设容差）；
// - 同一 `Layer`（多层特效同位叠画，不是一句的上下两行）；
// - 同一 ASS Style（字体 / 颜色 / 字号 / 粗斜体 / 对齐等，**不比边距**：作者常用
//   事件级 MarginV 把同一句的两行上下错开）——标牌、注释、另一说话人常用别的 Style，
//   不合进对白。没有 Style 的 cue（srt / vtt）不合并：同时显示的多条 SRT cue 照旧各算
//   一句；
// - 两条都有可读正文（图形字幕时间表 cue、`\p` 绘图 cue 没有正文，不参与）。
//
// 组内按**显示顺序**（画面自上而下，[subtitleAuthoredVerticalFraction]）排；竖直位置相同
// 保持字幕流原顺序（文件序）。组内文本按 `\N` 硬换行同一口径（解析器把 `\N` 落成空格，
// 见 `SubtitleMarkup.lineBreakGraphemes`）以空格拼接：同一段台词无论作者用 `\N` 断行
// 还是拆成两条 Dialogue，复制 / 制卡得到的文本一致。组内完全相同的文本（多层同文特效
// 漏网的重复）只保留一份。

/// [a] 与 [b] 在画面上是否属于同一句（判据见文件头）。
bool cuesShowAsOneSentence(AudioCue a, AudioCue b) {
  if (identical(a, b)) return true;
  if (a.startMs != b.startMs || a.endMs != b.endMs) return false;
  if (a.text.trim().isEmpty || b.text.trim().isEmpty) return false;
  if (a.isRenderOnly || b.isRenderOnly) return false;
  if ((a.markup?.layer ?? 0) != (b.markup?.layer ?? 0)) return false;
  return _sameBaseStyle(a.markup?.cueStyle, b.markup?.cueStyle);
}

/// 同一 ASS Style 的判据：比较 Style 行的全部外观列，不比 MarginL/R/V（事件级边距会让
/// 解析器给同一 Style 派生新实例，见 `SubtitleCueStyle.withEventMargins`）。
bool _sameBaseStyle(SubtitleCueStyle? a, SubtitleCueStyle? b) {
  // 没有 Style 的 cue（srt / vtt / 无 `[V4+ Styles]` 段）不合并：拍板范围是 ASS。
  if (a == null || b == null) return false;
  if (identical(a, b)) return true;
  return a.fontName == b.fontName &&
      a.primaryColorArgb == b.primaryColorArgb &&
      a.secondaryColorArgb == b.secondaryColorArgb &&
      a.outlineColorArgb == b.outlineColorArgb &&
      a.shadowColorArgb == b.shadowColorArgb &&
      a.fontSizePx == b.fontSizePx &&
      a.outlineWidthPx == b.outlineWidthPx &&
      a.shadowDepthPx == b.shadowDepthPx &&
      a.bold == b.bold &&
      a.italic == b.italic &&
      a.underline == b.underline &&
      a.strikeOut == b.strikeOut &&
      a.anchor?.vertical == b.anchor?.vertical &&
      a.anchor?.horizontal == b.anchor?.horizontal &&
      a.spacingPx == b.spacingPx &&
      a.angleDeg == b.angleDeg &&
      a.scaleXPct == b.scaleXPct &&
      a.scaleYPct == b.scaleYPct;
}

/// 一条 cue 在**作者排版**里的竖直位置（0=画面顶，1=画面底）。`\pos` 取 y 分数、`\move`
/// 取起点 y；无显式位置按 `\an` 竖直锚点 + MarginV（有 PlayResY 才折算）近似：底部
/// `1 - MarginV/PlayResY`、顶部 `MarginV/PlayResY`、中部 0.5。无 markup（srt/vtt）视作
/// 底部（1.0）。字幕 overlay 纯字幕模式排行序（BUG-3608）与这里的「显示顺序」共用。
double subtitleAuthoredVerticalFraction(SubtitleMarkup? m) {
  if (m == null) return 1.0;
  final SubtitlePos? pos = m.posFraction;
  if (pos != null) return pos.yFraction;
  final SubtitleMove? move = m.move;
  if (move != null) return move.y1Fraction;
  final double? playResY = m.playResY;
  final double mv = m.cueStyle?.marginV ?? 0;
  final double mvFraction = (playResY != null && playResY > 0 && mv > 0)
      ? (mv / playResY).clamp(0.0, 1.0).toDouble()
      : 0.0;
  switch (m.anchor?.vertical ?? SubtitleVAlign.bottom) {
    case SubtitleVAlign.top:
      return mvFraction;
    case SubtitleVAlign.middle:
      return 0.5;
    case SubtitleVAlign.bottom:
      return 1.0 - mvFraction;
  }
}

/// 把 [cues] 按显示顺序（画面自上而下）稳定排序；竖直位置相同保持输入顺序。
List<AudioCue> orderCuesTopToBottom(List<AudioCue> cues) {
  if (cues.length < 2) return cues;
  final List<double> ys = <double>[
    for (final AudioCue c in cues) subtitleAuthoredVerticalFraction(c.markup),
  ];
  final List<int> idx = List<int>.generate(cues.length, (int i) => i)
    ..sort((int a, int b) {
      final int byY = ys[a].compareTo(ys[b]);
      return byY != 0 ? byY : a.compareTo(b);
    });
  return <AudioCue>[for (final int i in idx) cues[i]];
}

/// 把 [cues]（一条字幕流，按 startMs 升序）切成「句」：每句是同时显示、按
/// [cuesShowAsOneSentence] 归为一组的 cue（组内按显示顺序排），句与句按起点顺序排。
/// 同一起点下有几组不同的句（如对白 + 标牌）时按各组首条在流里的先后排。纯函数。
List<List<AudioCue>> groupSimultaneousCues(List<AudioCue> cues) {
  final List<List<AudioCue>> out = <List<AudioCue>>[];
  int runStart = 0;
  while (runStart < cues.length) {
    int runEnd = runStart + 1;
    while (runEnd < cues.length &&
        cues[runEnd].startMs == cues[runStart].startMs) {
      runEnd++;
    }
    final List<List<AudioCue>> clusters = <List<AudioCue>>[];
    for (int i = runStart; i < runEnd; i++) {
      final AudioCue cue = cues[i];
      List<AudioCue>? home;
      for (final List<AudioCue> cluster in clusters) {
        if (cuesShowAsOneSentence(cluster.first, cue)) {
          home = cluster;
          break;
        }
      }
      if (home == null) {
        clusters.add(<AudioCue>[cue]);
      } else {
        home.add(cue);
      }
    }
    for (final List<AudioCue> cluster in clusters) {
      out.add(orderCuesTopToBottom(cluster));
    }
    runStart = runEnd;
  }
  return out;
}

/// [anchor] 所在的那一句（同时显示的同组 cue，按显示顺序）。[anchor] 不在 [cues] 里
/// （如流已切换）时只按判据从 [cues] 收同组 cue，再把 [anchor] 补进去。恒含 [anchor]。
List<AudioCue> simultaneousCueGroup(List<AudioCue> cues, AudioCue anchor) {
  final List<AudioCue> members = <AudioCue>[
    for (final AudioCue c in cues)
      if (c.startMs == anchor.startMs && cuesShowAsOneSentence(anchor, c)) c,
  ];
  if (!members.any((AudioCue c) => identical(c, anchor))) {
    members.add(anchor);
  }
  return orderCuesTopToBottom(members);
}

/// 一句（[group]，已按显示顺序）的文本：逐行 trim、丢空行、去掉重复行，以空格拼接
/// （与 `\N` 硬换行落成空格同一口径，见文件头）。
String joinSimultaneousCueText(List<AudioCue> group) {
  final List<String> lines = <String>[];
  for (final AudioCue cue in group) {
    final String text = cue.text.trim();
    if (text.isEmpty || lines.contains(text)) continue;
    lines.add(text);
  }
  return lines.join(' ');
}

/// [anchor] 所在那一句的完整文本（复制 / 制卡用）。不与别的行同时显示时就是
/// `anchor.text.trim()`。
String simultaneousCueText(List<AudioCue> cues, AudioCue anchor) =>
    joinSimultaneousCueText(simultaneousCueGroup(cues, anchor));

/// 查词制卡的「当前句」：用户在 [tappedSentence]（被点的那一行字幕）上查词、锚点 cue 为
/// [anchor] 时，制卡句应是锚点那一句的完整文本。只有被点的行确实属于锚点那一句时才
/// 换成整句——锚点是按播放位置兜底解析出来、与被点的行不是同一句时，保留被点的行，
/// 不把别的句子塞进卡片。[anchor] 为 null 时原样返回 [tappedSentence]。
String videoLookupMiningSentence({
  required List<AudioCue> cues,
  required AudioCue? anchor,
  required String tappedSentence,
}) {
  if (anchor == null) return tappedSentence;
  final String tapped = tappedSentence.trim();
  final List<AudioCue> group = simultaneousCueGroup(cues, anchor);
  if (group.length < 2) return tappedSentence;
  if (!group.any((AudioCue c) => c.text.trim() == tapped)) {
    return tappedSentence;
  }
  return joinSimultaneousCueText(group);
}

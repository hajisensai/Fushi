import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:hibiki/src/focus/hibiki_focus_scroll.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

String formatCueTimestamp(int startMs) =>
    HibikiTimeFormat.clock(Duration(milliseconds: startMs < 0 ? 0 : startMs));

/// 把 ASS **逐字卡拉OK 事件**合并回整句（TODO-1384）。纯函数，列表与测试同源。
///
/// 背景：OP/ED 卡拉OK 常把一句歌词拆成每字一条独立 `Dialogue`，各带自己的 `\pos`，靠
/// 坐标在画面上拼成一行（用户片源每集 175 条）：
///
/// ```
/// {\an7\pos(461,672)\fad(250,250)}手
/// {\an7\pos(491,672)\fad(250,250)}を
/// {\an7\pos(521,672)\fad(250,250)}伸
/// ```
///
/// 字幕列表按事件 1:1 列行，于是整屏都是单字行——既读不出句子，逐字行的查词/制卡也只能
/// 拿到一个字。合并**只作用于字幕列表**：渲染层必须保留逐字事件（每字有各自的 `\pos` 与
/// 淡入淡出时刻），两者消费同一份 cue 的不同视图。
///
/// 判据刻意收窄，宁可漏合也不错合（错合会把正常双语/多行字幕并成一行）。同组要求：
/// - 每条都带 `\pos`（无 `\pos` 的常规对白永不参与）；
/// - 文本是**单个 grapheme**（多字事件已是完整句，不该被并）；
/// - 同一行：`\pos` 的 y 分数相等（容差 [_kSameRowEps]）且同 ASS Layer；
/// - 时间上与本组已累积的区间**有重叠**（同一句歌词逐字入场；跨句的下一行不重叠 → 断组）；
/// - 组内至少 2 条（单条不构成「被拆开的句子」）。
///
/// 组内按 `\pos` 的 x 分数升序拼接文本（复现 libass 的画面横向顺序，而非文件顺序）。
/// 返回两张表：
/// - `byRep`：代表行 raw（该组在原列表中的**首个下标**）→ 合成 [AudioCue]（`startMs` 取
///   组内最小、`endMs` 取最大，其余字段沿用代表行）；
/// - `repByRaw`：组内**每个**成员 raw → 该组代表行 raw，供列表把「当前播放句落在某个单字
///   事件上」映射回唯一渲染的整句行（复用既有代表行机制，高亮/自动滚动零改动）。
///
/// 合成 cue 是**真 [AudioCue] 对象**而非显示层字符串，故列表的查词、收藏、制卡、搜索
/// 全部自动作用于整句——收藏判据是 `(text, startMs)` 值语义，不依赖对象身份。
({Map<int, AudioCue> byRep, Map<int, int> repByRaw}) mergePerCharacterCueGroups(
    List<AudioCue> cues) {
  const double kSameRowEps = 0.001;
  final Map<int, AudioCue> merged = <int, AudioCue>{};
  final Map<int, int> repByRaw = <int, int>{};

  bool isPerCharCue(AudioCue c) =>
      c.markup?.posFraction != null && c.text.characters.length == 1;

  int i = 0;
  while (i < cues.length) {
    if (!isPerCharCue(cues[i])) {
      i++;
      continue;
    }
    final AudioCue head = cues[i];
    final SubtitlePos headPos = head.markup!.posFraction!;
    final int headLayer = head.markup?.layer ?? 0;
    final List<AudioCue> group = <AudioCue>[head];
    int spanStart = head.startMs;
    int spanEnd = head.endMs;

    int j = i + 1;
    while (j < cues.length) {
      final AudioCue c = cues[j];
      if (!isPerCharCue(c)) break;
      final SubtitlePos p = c.markup!.posFraction!;
      if ((c.markup?.layer ?? 0) != headLayer) break;
      if ((p.yFraction - headPos.yFraction).abs() > kSameRowEps) break;
      // 与本组已累积区间不重叠 → 是下一句，断组。
      if (c.startMs > spanEnd || c.endMs < spanStart) break;
      group.add(c);
      if (c.startMs < spanStart) spanStart = c.startMs;
      if (c.endMs > spanEnd) spanEnd = c.endMs;
      j++;
    }

    if (group.length >= 2) {
      final List<AudioCue> ordered = List<AudioCue>.of(group)
        ..sort((AudioCue a, AudioCue b) => a.markup!.posFraction!.xFraction
            .compareTo(b.markup!.posFraction!.xFraction));
      for (int k = i; k < j; k++) {
        repByRaw[k] = i;
      }
      merged[i] = AudioCue()
        ..bookKey = head.bookKey
        ..chapterHref = head.chapterHref
        ..sentenceIndex = head.sentenceIndex
        ..textFragmentId = head.textFragmentId
        ..text = ordered.map((AudioCue c) => c.text).join()
        ..startMs = spanStart
        ..endMs = spanEnd
        ..audioFileIndex = head.audioFileIndex
        // markup 不继承：合成句没有单一的 \pos / \fad，渲染层也不消费本结果
        // （列表只用 text/时间）。留 null 避免下游误以为它有作者位置。
        ..markup = null;
    }
    i = j > i ? j : i + 1;
  }
  return (byRep: merged, repByRaw: repByRaw);
}

/// 字幕列表行**时间戳列宽度**（TODO-567 / TODO-1200）。纯函数，页面与测试同源。
///
/// 时间戳用 tabular figures 单行不换行渲染，列宽须容下最宽的时间戳字符串，否则文本溢出到
/// 右侧字幕文本列（TODO-567）。但旧实现恒按**小时级**最坏宽度（`(字号-1) × 4.6`、下界 52）
/// 预留，即便整段视频不足 1 小时（时间戳只有 `m:ss`，约 5 字符 ≈ 40px）也占 ~60px——短时间戳
/// 左对齐在过宽的列里，时间戳与字幕文本之间凭空多出一段空白（TODO-1200 用户报的「奇怪空隙」），
/// 且白白吃掉本就紧张的文本列宽度（窄面板上字幕被挤成 3-4 字硬折行）。
///
/// 修正：按列表**是否真的出现小时级时间戳**（[hasHours]）取宽——不足 1 小时只按 `mm:ss`
/// （约 5 字符）算窄列，达到 1 小时才按 `h:mm:ss`（约 7 字符）算宽列。既不溢出（仍容下实际
/// 最宽时间戳），又消除短视频的空隙、把宽度还给文本列。tabular figures 下每字位约 0.62em，
/// 加一点余量并随字号缩放，设下界防极窄字号下列太窄。[effectiveFontSize] 传行内时间戳同源
/// 的有效字号（渲染时时间戳用 `effectiveFontSize - 1`，故此处一致用 `-1` 折算字位宽）。
double subtitleTimestampColumnWidth(double effectiveFontSize, bool hasHours) {
  const double emPerChar = 0.62;
  final double chars = hasHours ? 7.2 : 5.0;
  final double scaled = (effectiveFontSize - 1) * emPerChar * chars;
  final double floor = hasHours ? 52.0 : 36.0;
  return scaled < floor ? floor : scaled;
}

/// 字幕列表行的**固定几何**（BUG-1034）。行高由 `itemExtentBuilder` 事先给出，若与真实
/// 渲染几何有一丝偏差，`SliverVariedExtentList` 就按给定 extent 裁掉超出的文本（用户报的
/// 「ら 只露半个」）。所以文本列宽必须由**同一组常量**同时喂给测量与渲染，不能各算各的。
///
/// 行内水平结构（见 `_buildRow`）：
/// `padding.left(8) | [勾选框 36 + 间隙 4] | 时间戳列 | 间隙 8 | 文本(Expanded) | 动作列 | padding.right(4)`
const double kSubtitleRowPaddingLeft = 8;
const double kSubtitleRowPaddingRight = 4;

/// 行垂直内缩（上 8 + 下 8）。
const double kSubtitleRowPaddingVertical = 16;

/// 勾选框列宽：`Checkbox`（compact + shrinkWrap）实际是 36×36，用 [SizedBox.square] 锁死，
/// 免得主题里的 visualDensity 改动悄悄改变列宽、把测量算歪。
const double kSubtitleRowSelectionSize = 36;
const double kSubtitleRowSelectionGap = 4;

/// 时间戳列与文本列之间的间隙。
const double kSubtitleRowTimestampGap = 8;

/// 收藏行左侧竖色条宽度（画在 `padding.left` 内，不占内容宽度）。
const double kSubtitleRowFavoriteBarWidth = 3;

/// 动作列宽度：3 个图标，每个 `Icon(size: 字号+2)` 外加 `Padding(all: 2)` → 字号+6。
double subtitleRowActionsWidth(double effectiveFontSize) =>
    3 * (effectiveFontSize + 6);

/// 行内字幕**文本列可用宽度**（BUG-1034）。纯函数，行高测量与真实渲染同源。
double subtitleRowTextWidth({
  required double rowWidth,
  required double effectiveFontSize,
  required double timestampColumnWidth,
  required bool hasSelectionControls,
}) {
  final double selectionWidth = hasSelectionControls
      ? kSubtitleRowSelectionSize + kSubtitleRowSelectionGap
      : 0;
  final double width = rowWidth -
      kSubtitleRowPaddingLeft -
      kSubtitleRowPaddingRight -
      selectionWidth -
      timestampColumnWidth -
      kSubtitleRowTimestampGap -
      subtitleRowActionsWidth(effectiveFontSize);
  return width < 48 ? 48 : width;
}

/// 按局部坐标在一行字幕的 grapheme 屏幕矩形里反查命中的字下标（纯函数，可测）。
///
/// BUG-916：旧实现走 `TextPainter.getPositionForOffset(point).offset` 取 caret 边界、
/// 再映射回字下标。但 `getPositionForOffset` 把某字**左半格与右半格的点塌陷到同一条 caret
/// 边界**（点在字 i 左半 → 返回 `starts[i]`，即字 i 与 i-1 之间的边界），单凭这个偏移量
/// 无法区分点落在边界哪一侧；旧 `graphemeIndexForOffset` 又把边界一律归给**左边**那个字
/// （`offset <= starts[i]` 返回 `i-1`），于是指向某字左半时系统性查到**左边一个字**
/// （视频里指「護」查出「の」、指「ね」查出「衛」）。
///
/// 根治：丢弃 caret 偏移这一层，直接用**真实像素点**做几何命中——
/// 1. 先取包含点的字（[Rect.contains] 含左/上边、排右/下边，故落在两字边界的点归**右侧**
///    那个字，与「指向某字起笔」的直觉一致）。
/// 2. miss 则取欧氏距离最近、且在半字宽 / [minTolerance] 容差内的字（兜底 [Wrap] 字缝、
///    换行首尾的空隙）。垂直用 clamp 距离参与，避免把点归到相邻行的远字。
///
/// 空矩形（零宽组合字符等）跳过。无有效矩形或全部超容差返回 -1。
@visibleForTesting
int resolveSubtitleListGraphemeHit(
  List<Rect> graphemeRects,
  Offset point, {
  double minTolerance = 4.0,
}) {
  for (int i = 0; i < graphemeRects.length; i++) {
    final Rect r = graphemeRects[i];
    if (r.isEmpty) continue;
    if (r.contains(point)) return i;
  }
  int bestIndex = -1;
  double bestDistance = double.infinity;
  for (int i = 0; i < graphemeRects.length; i++) {
    final Rect r = graphemeRects[i];
    if (r.isEmpty) continue;
    final double dx = point.dx.clamp(r.left, r.right) - point.dx;
    final double dy = point.dy.clamp(r.top, r.bottom) - point.dy;
    final double distance = dx * dx + dy * dy;
    if (distance >= bestDistance) continue;
    final double tolerance = (r.width / 2).clamp(minTolerance, double.infinity);
    if (distance <= tolerance * tolerance) {
      bestDistance = distance;
      bestIndex = i;
    }
  }
  return bestIndex;
}

/// 字幕列表行字号缩放档位（BUG-878）。原上限只到 1.3×，用户反馈「字号拉到最大才够用、
/// 上限不够」，向上扩到 2.0×（1.5 / 1.75 / 2.0 三档）。默认档 [_kDefaultFontScaleIndex]=1
/// （1.0×）。数组扩容后旧持久化下标仍安全（seed / [_stepFont] 都 clamp 到数组范围）。
const List<double> _kFontScaleSteps = <double>[
  0.85,
  1.0,
  1.15,
  1.3,
  1.5,
  1.75,
  2.0,
];

/// 默认字号档位（1.0×）。持久化 key 从未写过时的初值，与 `preferences_repository.dart`
/// 的 `videoSubtitleListFontScaleIndex` 默认值一致。
const int _kDefaultFontScaleIndex = 1;

/// 字幕列表行内点击命中的字符：被点 grapheme 下标 + 该字符的全局屏幕矩形。
/// 供 [VideoSubtitleJumpPanel.onLookupCue] 精确查词（TODO-340）。
typedef SubtitleListCharHit = ({int graphemeIndex, Rect charRect});

/// 命中字幕列表某行某字符：整条 [cue] + grapheme 下标 + 该字符的全局屏幕矩形。
/// 比 [SubtitleListCharHit] 多带所属 [cue]，供查词浮层 dismiss barrier 直接切换查词
/// （BUG-874）。
typedef SubtitleListHit = ({AudioCue cue, int graphemeIndex, Rect charRect});

/// 给上层（查词浮层的 dismiss barrier）按全局坐标反查「点到的是字幕列表哪行哪个字符」
/// 用的句柄。[VideoSubtitleJumpPanel] 每帧 build 把命中实现绑进来；上层持有同一对象、
/// 调 [hitTest]（BUG-874）。
///
/// 与画面底部内嵌字幕的 `VideoSubtitleHitTester`（`video_subtitle_overlay.dart`）同范式：
/// 查词浮层打开时，根 Overlay 的全屏 dismiss barrier 盖在**推挤式字幕列表侧栏**之上、抢走
/// 点击 → 点列表里下一个词只会关浮层、查不了下一个词。让 barrier 先用本句柄反查是否点到了
/// 列表字符，是则切换查词（保持暂停 + `replaceStack`），否则才 dismiss。
class VideoSubtitleListHitTester {
  SubtitleListHit? Function(Offset globalPos, {bool exactOnly})? _impl;

  /// [VideoSubtitleJumpPanel] build 时绑定当前可见行的命中实现。
  void bindHitTest(
          SubtitleListHit? Function(Offset globalPos, {bool exactOnly}) impl) =>
      _impl = impl;

  /// 面板卸载（侧栏隐藏）时解绑，避免 barrier 调到已失效的实现。
  void unbind() => _impl = null;

  /// 无绑定（无查词能力 / 面板已卸载）时返回 null，barrier 落回原 dismiss。
  ///
  /// [exactOnly]（BUG-910）：为 true 时只在点**落在字形选区盒内**才命中，跳过半字格裙边
  /// 容差——查词浮层 dismiss barrier 用它区分「点列表空白想关闭」与「点列表字上想切词」。
  /// 列表面板占右半屏、行文本满宽，若 barrier 判定吃裙边容差，点面板行距 / 行尾空白想关闭
  /// 浮层会被误判成切词重查（用户报「点半个屏幕外一直重复查词」）。悬停查词仍用宽容差。
  SubtitleListHit? hitTest(Offset globalPos, {bool exactOnly = false}) =>
      _impl?.call(globalPos, exactOnly: exactOnly);
}

/// 字幕文本每个 grapheme 的 UTF-16 起始偏移（按 [String.characters] 顺序）。列表行内 tap 的
/// `hitAt` 与 [subtitleListCharHitFromParagraph] 共用（消除重复，BUG-874）。
@visibleForTesting
List<int> subtitleGraphemeStartOffsets(String text) {
  final List<int> starts = <int>[];
  int offset = 0;
  for (final String grapheme in text.characters) {
    starts.add(offset);
    offset += grapheme.length;
  }
  return starts;
}

/// 字幕文本每个 grapheme 的 UTF-16 结束偏移（与 [subtitleGraphemeStartOffsets] 一一对应）。
@visibleForTesting
List<int> subtitleGraphemeEndOffsets(String text) {
  final List<int> ends = <int>[];
  int offset = 0;
  for (final String grapheme in text.characters) {
    offset += grapheme.length;
    ends.add(offset);
  }
  return ends;
}

Rect _subtitleUnionBoxes(List<TextBox> boxes) {
  if (boxes.isEmpty) return Rect.zero;
  Rect rect = boxes.first.toRect();
  for (final TextBox box in boxes.skip(1)) {
    rect = rect.expandToInclude(box.toRect());
  }
  return rect;
}

/// 在一个已布局的行文本 [RenderParagraph] 上，按行内 [localPosition] 反查命中的字符
/// （BUG-874，供 [VideoSubtitleListHitTester] 用）。逻辑与 [VideoSubtitleJumpPanel] 行内 tap
/// 的 `hitAt` 同构（同一 grapheme 映射 + 选区盒并集 + 1px 容差），只是取位置 / 选区盒改用
/// 实时 [RenderParagraph]（免重建 TextPainter），并去掉 caret 兜底（miss 落回 dismiss，安全）。
///
/// 返回被点 grapheme 下标 + 该字符的**全局**屏幕矩形（`globalPosition - localPosition` 平移，
/// 与 `hitAt` 同式，保证与底部字幕查词定位一致）。空文本 / 越界 / 容差外返回 null。
SubtitleListCharHit? subtitleListCharHitFromParagraph(
  RenderParagraph paragraph,
  String text, {
  required Offset localPosition,
  required Offset globalPosition,
  // BUG-910：为 true 时只在点落在字形选区盒内才命中，跳过半字格裙边容差（barrier 关闭
  // 判定用）——点列表行距 / 行尾空白想关闭浮层不被误判成切词。查词/悬停默认 false。
  bool exactOnly = false,
}) {
  final List<int> starts = subtitleGraphemeStartOffsets(text);
  if (starts.isEmpty) return null;
  final List<int> ends = subtitleGraphemeEndOffsets(text);
  // BUG-916：对**每个 grapheme 的真实渲染盒**做几何命中，不再走 getPositionForOffset 的
  // caret 边界（后者把某字左右半格塌陷到同一边界、无法区分点在哪侧 → 旧实现系统性偏左一格）。
  // BUG-879：盒用 BoxHeightStyle.max 覆盖整行视觉格（含 1.25 行高的 leading），点在行距里
  // 也落在盒内命中，不退 seek。
  final List<Rect> rects = <Rect>[
    for (int i = 0; i < starts.length; i++)
      _subtitleUnionBoxes(
        paragraph.getBoxesForSelection(
          TextSelection(baseOffset: starts[i], extentOffset: ends[i]),
          boxHeightStyle: BoxHeightStyle.max,
        ),
      ),
  ];
  final int graphemeIndex =
      resolveSubtitleListGraphemeHit(rects, localPosition);
  if (graphemeIndex < 0) return null;
  Rect localRect = rects[graphemeIndex];
  if (!localRect.contains(localPosition)) {
    // BUG-910：exactOnly（barrier 关闭判定）不吃裙边——点在字形盒外一律 miss → barrier
    // 落回 dismiss，不把「点面板空白想关闭」误判成切词重查。
    if (exactOnly) return null;
    // 字缝 / 行距上的兜底命中：把返回盒扩到含点，保证 charRect 始终含指针（浮层锚点、
    // barrier 反查的 contains 判定不落空）。BUG-916 起盒用 BoxHeightStyle.max 覆盖整行
    // 视觉格，行距点也落盒内，无需再叠半字格容差。
    localRect = localRect.expandToInclude(
      Rect.fromCenter(center: localPosition, width: 1, height: 1),
    );
  }
  final Offset globalOrigin = globalPosition - localPosition;
  return (
    graphemeIndex: graphemeIndex,
    charRect: localRect.shift(globalOrigin),
  );
}

enum VideoSubtitleListFilter {
  all,
  favorites,
  selected,
}

class VideoSubtitleJumpPanel extends StatefulWidget {
  const VideoSubtitleJumpPanel({
    super.key,
    required this.controller,
    required this.onTapCue,
    required this.onCopyCue,
    required this.onFavoriteCue,
    required this.isCueFavorited,
    required this.onClose,
    this.onLookupCue,
    this.hitTester,
    required this.colorScheme,
    required this.title,
    required this.emptyHint,
    this.loadingHint,
    this.isCueSelectedForCard,
    this.onToggleCueSelection,
    this.onClearCueSelection,
    this.initialAutoScroll = true,
    this.onAutoScrollChanged,
    this.initialFontScaleIndex = _kDefaultFontScaleIndex,
    this.onFontScaleIndexChanged,
    this.hoverAutoLookupEnabled = false,
    this.fontSize = 14,
    this.width = 320,
  });

  final VideoPlayerController controller;
  final void Function(AudioCue cue) onTapCue;
  final void Function(AudioCue cue) onCopyCue;
  final Future<void> Function(AudioCue cue) onFavoriteCue;
  final bool Function(AudioCue cue) isCueFavorited;
  final VoidCallback onClose;

  /// 点列表项字幕文本 → 从点击命中的字符起查词（TODO-340）。[cue] 为被点行的字幕句，
  /// [graphemeIndex] 为点击位置命中的 grapheme 下标（与底部字幕逐字查词同语义，
  /// 调用方据此从该位置起取词最长匹配），[charRect] 为被点字符的全局屏幕矩形（查词
  /// 浮层定位用）。null 时文本不可查词、行点击仅 seek（向后兼容：部分调用方 / 测试不
  /// 接查词）。
  final void Function(AudioCue cue, int graphemeIndex, Rect charRect)?
      onLookupCue;

  /// 可选：按全局坐标反查列表字符命中的句柄（BUG-874）。非 null 时面板每帧把当前可见行的
  /// 命中实现绑进去，供查词浮层 dismiss barrier「点列表下一个词切换查词、保持浮层」。null
  /// （测试 / 无查词能力）时不绑，行为与历史一致。
  final VideoSubtitleListHitTester? hitTester;
  final ColorScheme colorScheme;
  final String title;
  final String emptyHint;
  final String? loadingHint;
  final bool Function(AudioCue cue)? isCueSelectedForCard;
  final void Function(AudioCue cue)? onToggleCueSelection;
  final VoidCallback? onClearCueSelection;

  /// 自动滚动到当前播放句的初始开关（TODO-613）。面板内 [_autoScroll] 以此为初值，
  /// 用户切换时回调 [onAutoScrollChanged] 通知页面层落盘（默认 true，向后兼容）。
  final bool initialAutoScroll;

  /// 用户在面板头部切换「自动滚动」时回调（TODO-613）。null 时仍可切换（纯本地），
  /// 但不通知外部持久化（部分调用方 / 测试不接落盘）。
  final ValueChanged<bool>? onAutoScrollChanged;

  /// 行字号档位初值（BUG-878）：面板内 [_fontScaleIndex] 以此为种子（seed 时 clamp 到
  /// [_kFontScaleSteps] 范围），用户 A+/A- 或 Ctrl+滚轮调节时回调 [onFontScaleIndexChanged]
  /// 通知页面层落 Drift preferences。默认 [_kDefaultFontScaleIndex]（1.0×，向后兼容：
  /// 旧调用方 / 测试不传即默认档）。
  final int initialFontScaleIndex;

  /// 用户调节行字号档位时回调（BUG-878）。null 时仍可调（纯本地），但不通知外部持久化
  /// （部分调用方 / 测试不接落盘）。旧版本字号是纯内存 State、每次重开重置，这条回调让它
  /// 跨开关 / 跨重启记住。
  final ValueChanged<int>? onFontScaleIndexChanged;

  /// 「悬停即查词」门控（BUG-879，与 `VideoSubtitleOverlay.hoverAutoLookupEnabled` 同源）：
  /// true 时列表行文本纯悬停即查词，false 时退回按住 Shift 悬停才查词。由页面层从
  /// `ReaderHibikiSource.instance.hoverAutoLookup` 传入。默认 false（向后兼容）。
  final bool hoverAutoLookupEnabled;

  final double fontSize;
  final double width;

  @override
  State<VideoSubtitleJumpPanel> createState() => _VideoSubtitleJumpPanelState();
}

class _VideoSubtitleJumpPanelState extends State<VideoSubtitleJumpPanel> {
  late final ScrollController _scrollController;

  int _lastScrolledIndex = -1;
  int _lastControllerCueIndex = -1;
  bool _lastSubtitleCuesLoading = false;
  int? _scrollTargetRawIndex;
  int _hoveredIndex = -1;
  late bool _autoScroll = widget.initialAutoScroll;
  bool _scrollPostFrameScheduled = false;
  // BUG-878：字号档位以持久化初值为种子（clamp 防越界），不再每次重开都回默认档。
  late int _fontScaleIndex =
      widget.initialFontScaleIndex.clamp(0, _kFontScaleSteps.length - 1);
  VideoSubtitleListFilter _filter = VideoSubtitleListFilter.all;

  /// BUG-878：Ctrl / ⌘ 是否按住。按住时列表滚动物理改为 [NeverScrollableScrollPhysics]，
  /// 让 Ctrl+滚轮只缩字号而不同时滚动列表（裸滚轮仍正常滚列表，浏览器式缩放）。由
  /// [_handleHardwareKey]（挂在 [HardwareKeyboard]）同步键状态；纯读修饰键、绝不消费按键。
  bool _zoomModifierHeld = false;

  /// BUG-879：列表行 Shift-悬停查词节流锚（与画面字幕 overlay `_lastShiftHoverPos` /
  /// `_handleShiftHover` 同构、与阅读器 8px 阈值同源）。[Offset.zero] / 空句 / -1 表示未进入
  /// （松开 Shift / 离开行时复位），下次按 Shift 进入即触发；命中同一 cue 同一 grapheme 且
  /// 移动未越阈值时短路去重，避免每帧 hover 重复查词。
  Offset _lastRowHoverPos = Offset.zero;
  Object? _lastRowHoverCueKey;
  int _lastRowHoverGrapheme = -1;

  /// 列表行 Shift-悬停查词的移动节流阈值（像素平方，与 overlay `_kShiftHoverThresholdPx`=8
  /// 同构）。
  static const double _kRowHoverThresholdPx = 8;

  /// 只给当前/待滚动目标行保留 [GlobalKey]，供自适应行高下精确
  /// [HibikiFocusScroll.ensureVisible]。普通可见行走 [ValueKey]，避免长列表滚动后
  /// [GlobalKey] map 按历史 visibleIndex 无限制增长。
  final Map<int, GlobalKey> _rowKeys = <int, GlobalKey>{};

  /// BUG-874：当前已构建（可见）行的文本 [RenderParagraph] 命中登记表，键为 ListView.builder
  /// 的 **builder 下标 i**（同一时刻每 i 唯一，稳定不撞 GlobalKey）。逐行在 [_buildRow] 里把
  /// 行文本 [RichText] 的 [GlobalKey]（[_rowTextKeys]）与所属 cue（[_rowHitCues]）登记进来；
  /// [_hitTestRows] 遍历本表、用各行 RenderParagraph 反查全局坐标命中的字符。行滚出屏后
  /// element 卸载、`currentContext` 为 null，自动跳过（不残留误命中）；[_rowHitCues] 每帧 build
  /// 前清空、仅当帧真正构建的行回填，保证不会读到旧 cue。
  final Map<int, GlobalKey> _rowTextKeys = <int, GlobalKey>{};
  final Map<int, AudioCue> _rowHitCues = <int, AudioCue>{};
  List<AudioCue>? _cachedCues;
  int _cachedCuesLength = -1;
  VideoSubtitleListFilter? _cachedFilter;
  List<int> _cachedVisibleIndexes = const <int>[];
  Map<int, int> _cachedVisibleIndexByRawIndex = const <int, int>{};

  /// BUG-841：特效叠加 / 多层 ASS 用多条 Dialogue 事件渲染**同一句可见文本**（不同
  /// layer / style / 位置做描边、辉光、逐字变色等特效），画面 overlay 有意全渲染各层
  /// （TODO-1312），但字幕列表按 `(startMs, 文本)` 折叠这些重复，只保留首条**代表行**，
  /// 一句话不再在列表里出现多行。双语（同时间、文本不同）文本不同不折叠，日/中各占一行。
  /// [_cachedDedupIndexes] 是代表行的 raw 下标（升序，`setCues` 已排序）；
  /// [_cachedRepresentativeByRaw] 把**每个** raw 下标（含被折叠的重复）映射到其代表行的
  /// raw 下标，供当前播放句落在重复项时把高亮 / 自动滚动定位到那唯一渲染的代表行。
  List<AudioCue>? _cachedDedupCues;
  int _cachedDedupCuesLength = -1;
  List<int> _cachedDedupIndexes = const <int>[];
  Map<int, int> _cachedRepresentativeByRaw = const <int, int>{};

  /// TODO-1384：代表行 raw → 该行的**合成整句 cue**（ASS 逐字卡拉OK 事件合并，判据见
  /// [mergePerCharacterCueGroups]）。与 [_cachedDedupCues] 同生命周期、同一次遍历刷新。
  /// 非逐字行不在表内，[_rowCue] 回落原 cue（既有行为逐像素不变）。
  Map<int, AudioCue> _cachedMergedByRep = const <int, AudioCue>{};
  List<AudioCue>? _cachedSelectedCues;
  int _cachedSelectedCuesLength = -1;
  int _cachedSelectedCount = 0;

  /// 行高保底下界（TODO-340 的历史视觉密度）：内容比它矮的行仍占这么高，内容更高的行
  /// 按 [_measureRowExtent] 的真实测量值走。
  double get _minRowExtent => 56 * _fontScaleSteps;

  /// 行高测量缓存（BUG-1034），key = `加粗位 + 文本`。宽度 / 字号 / textScaler 变化时整体
  /// 作废，见 [_rowExtentForCue]。
  final Map<String, double> _rowExtentCache = <String, double>{};
  double _rowExtentCacheWidth = -1;
  double _rowExtentCacheFontSize = -1;
  TextScaler _rowExtentCacheScaler = TextScaler.noScaling;
  double? _timestampLineHeight;

  /// 测量用的排版环境，[build] 每帧从 context 刷新。`initState` 里读 `MediaQuery` /
  /// `Directionality` 会触发 `dependOnInheritedWidgetOfExactType` 断言，故先用默认值供
  /// 初始滚动偏移粗估，首帧 build 后即为真值（变化时缓存自动作废）。
  TextDirection _textDirection = TextDirection.ltr;
  TextScaler _textScaler = TextScaler.noScaling;

  double get _fontScaleSteps => _kFontScaleSteps[_fontScaleIndex];

  double get _effectiveFontSize => widget.fontSize * _fontScaleSteps;

  /// 列表里是否出现**小时级**时间戳（TODO-1200）：cue 升序（`setCues` 保证），故最后一条
  /// cue 的起始时间即最大值，>= 1 小时才需要 `h:mm:ss` 宽列；空列表按无小时（窄列）。用它
  /// 让 [_timestampColumnWidth] 只在真有小时级时间戳时才取宽列，短视频用窄列消除空隙。
  bool get _hasHourTimestamps {
    final List<AudioCue> cues = widget.controller.cues;
    if (cues.isEmpty) return false;
    return cues.last.startMs >= 3600 * 1000;
  }

  /// 时间戳列宽度（TODO-567 / TODO-1200）：内容自适应，见 [subtitleTimestampColumnWidth]。
  /// 短视频（无小时级时间戳）取窄列消除时间戳与文本间的「奇怪空隙」并把宽度还给文本列，
  /// 达到 1 小时才取宽列容下 `h:mm:ss`。配合时间戳 Text 单行不换行（`maxLines:1` /
  /// `softWrap:false`），列内容永不溢出到文本列。
  double get _timestampColumnWidth =>
      subtitleTimestampColumnWidth(_effectiveFontSize, _hasHourTimestamps);

  /// 行内字幕文本列的可用宽度（与 [_buildRow] 的实际布局同源，见 [subtitleRowTextWidth]）。
  double _rowTextWidth(double rowWidth) => subtitleRowTextWidth(
        rowWidth: rowWidth,
        effectiveFontSize: _effectiveFontSize,
        timestampColumnWidth: _timestampColumnWidth,
        hasSelectionControls: _hasCueSelectionControls,
      );

  /// 行内字幕文本的样式。测量（[_measureRowExtent]）与渲染（[_buildRowText]）共用，
  /// 保证 `itemExtentBuilder` 给出的行高与真实换行结果一致（BUG-1034）。
  TextStyle _rowTextStyle({required bool bold, Color? color}) => TextStyle(
        color: color,
        fontSize: _effectiveFontSize,
        fontWeight: bold ? FontWeight.w600 : null,
        height: 1.25,
      );

  /// 一行**真实**高度（BUG-1034）。
  ///
  /// 旧实现按「文本长度 ÷ 每行估算字数」推行数（`字号 × 0.95` 当字宽），再乘行高当作
  /// `itemExtentBuilder` 的返回值。但 `ListView` 的 `itemExtentBuilder` 不是提示而是**硬约束**：
  /// 行拿到的就是这个高度，多出来的文本直接被裁掉。而那套估算复现不了 Flutter 的真实断行
  /// —— 全角字宽是 1em（不是 0.95em）、日文禁则会把行首的小假名 / 标点挤到下一行、选中行
  /// 还会加粗——于是长句实际换成 N+1 行、extent 只给了 N 行，末行被拦腰切掉（用户截图里
  /// 当前播放行的「ら」只露出上半截）。
  ///
  /// 根治：用 [TextPainter] 按与渲染**完全相同**的样式、字宽约束、textScaler 真跑一次
  /// 布局，拿 `painter.height` 当真值；同时把行内其它子项（勾选框 / 动作图标 / 时间戳）的
  /// 高度纳入取最大值，因为 `Row` 的高度是子项高度的最大值。结果按「文本 + 是否加粗」缓存，
  /// 宽度、字号或 textScaler 变化时整体作废——`SliverVariedExtentList` 每次布局都要遍历
  /// 全部条目累加 maxScrollExtent，没有缓存会把 TextPainter 跑进每一帧。
  double _rowExtentForCue(AudioCue cue, double rowWidth, {required bool bold}) {
    if (rowWidth != _rowExtentCacheWidth ||
        _effectiveFontSize != _rowExtentCacheFontSize ||
        _textScaler != _rowExtentCacheScaler) {
      _rowExtentCache.clear();
      _timestampLineHeight = null;
      _rowExtentCacheWidth = rowWidth;
      _rowExtentCacheFontSize = _effectiveFontSize;
      _rowExtentCacheScaler = _textScaler;
    }
    final String key = '${bold ? 1 : 0}\u0000${cue.text}';
    final double? cached = _rowExtentCache[key];
    if (cached != null) return cached;
    final double extent = _measureRowExtent(cue.text, rowWidth, bold);
    _rowExtentCache[key] = extent;
    return extent;
  }

  double _measureRowExtent(String text, double rowWidth, bool bold) {
    final double textHeight = _measureTextHeight(
      text: text,
      style: _rowTextStyle(bold: bold),
      maxWidth: _rowTextWidth(rowWidth),
    );
    // Row 高度 = 子项高度最大值：文本、时间戳单行、动作图标，以及（有勾选控件时）勾选框。
    double content = textHeight;
    final double timestampHeight = _timestampLineHeight ??= _measureTextHeight(
      text: '0:00',
      style: TextStyle(fontSize: _effectiveFontSize - 1),
      maxWidth: double.infinity,
    );
    if (content < timestampHeight) content = timestampHeight;
    final double actionHeight = _effectiveFontSize + 6;
    if (content < actionHeight) content = actionHeight;
    if (_hasCueSelectionControls && content < kSubtitleRowSelectionSize) {
      content = kSubtitleRowSelectionSize;
    }
    final double extent = kSubtitleRowPaddingVertical + content;
    // 保底最小行高（历史视觉密度，TODO-340）：只抬高内容矮于它的行，绝不压低内容。
    return extent < _minRowExtent ? _minRowExtent : extent;
  }

  double _measureTextHeight({
    required String text,
    required TextStyle style,
    required double maxWidth,
  }) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: TextAlign.start,
      textDirection: _textDirection,
      textScaler: _textScaler,
      maxLines: null,
    );
    try {
      painter.layout(maxWidth: maxWidth);
      return painter.height;
    } finally {
      painter.dispose();
    }
  }

  /// 行是否按「当前播放 / 已选中制卡」加粗——加粗会改变断行，故行高测量必须同步判定
  /// （与 [_buildRowText] 的 `selected || selectedForCard` 同源，BUG-1034）。
  bool _isRowBold(int rawIndex, AudioCue cue) =>
      rawIndex == _representativeRaw(widget.controller.currentCueIndex) ||
      _isCueSelectedForCard(cue);

  double _estimatedScrollOffsetForVisibleIndex(
    int visibleIndex,
    List<int> visibleIndexes,
    List<AudioCue> cues,
    double rowWidth,
  ) {
    double offset = 0;
    for (int i = 0; i < visibleIndex; i++) {
      final int rawIndex = visibleIndexes[i];
      final AudioCue cue = _rowCue(cues, rawIndex);
      offset += _rowExtentForCue(
        cue,
        rowWidth,
        bold: _isRowBold(rawIndex, cue),
      );
    }
    return offset;
  }

  bool get _hasCueSelectionControls =>
      widget.isCueSelectedForCard != null &&
      widget.onToggleCueSelection != null;

  @override
  void initState() {
    super.initState();
    _lastControllerCueIndex = widget.controller.currentCueIndex;
    _lastSubtitleCuesLoading = widget.controller.isSubtitleCuesLoading;
    // BUG-841：当前句可能落在被折叠的重复项上——追踪其**代表行** raw（列表渲染的唯一行），
    // 否则高亮 / 滚动定位不到（rowKey 按代表行 raw 挂）。
    final int initialRawIndex =
        _representativeRaw(widget.controller.currentCueIndex);
    _scrollTargetRawIndex =
        _isCurrentCueVisible(initialRawIndex) ? initialRawIndex : null;
    _retainRowKeyFor(_scrollTargetRawIndex);
    _scrollController = ScrollController(
      initialScrollOffset: _initialScrollOffsetForCurrentCue(),
    );
    widget.controller.addListener(_onControllerChanged);
    // BUG-878：跟踪 Ctrl / ⌘ 键状态，供 Ctrl+滚轮缩字号时把列表滚动物理切成禁滚。
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    _scheduleScrollToCurrentCue();
  }

  /// BUG-878：同步 Ctrl / ⌘ 修饰键状态（纯观察、恒返回 false 不消费按键，不干扰任何快捷键
  /// 或播放器键盘操作）。修饰键变化时 setState 让 [build] 切换 ListView 的滚动物理，使
  /// Ctrl+滚轮期间列表不滚动、只缩字号。
  bool _handleHardwareKey(KeyEvent event) {
    final bool held = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (held != _zoomModifierHeld && mounted) {
      setState(() => _zoomModifierHeld = held);
    }
    return false;
  }

  /// BUG-878：Ctrl / ⌘ + 鼠标滚轮缩放行字号（浏览器式，与 app 界面缩放偏好一致）。裸滚轮
  /// 仍走 ListView 正常滚动列表（[_zoomModifierHeld] 为真时 [build] 才把物理切成禁滚，避免
  /// 缩放与滚动同时发生）。上滚（`dy < 0`）放大、下滚缩小，步进复用 [_stepFont]（含 clamp
  /// 与持久化）。非缩放修饰键 / 非滚轮信号一律忽略，交回列表滚动。
  void _handleZoomWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed) {
      return;
    }
    if (event.scrollDelta.dy == 0) return;
    _stepFont(event.scrollDelta.dy < 0 ? 1 : -1);
  }

  /// BUG-879：字幕列表 Shift-悬停查词（面板级单一入口，复用 [_hitTestRows] 的 RenderParagraph
  /// 反查——不为每次 hover 新建 TextPainter 重排整行，与画面字幕 overlay 的几何反查一样轻，
  /// 消除「列表查词比画面字幕卡」）。门控（开了「悬停即查词」则纯悬停、否则按住 Shift）+
  /// 8px 阈值 + 同 cue 同 grapheme 短路去重都与 overlay `_handleShiftHover` 同构。命中经
  /// [VideoSubtitleJumpPanel.onLookupCue] → 页面 `_handleSubtitleListLookup` → `_lookupAt`。
  void _handleListShiftHover(PointerHoverEvent event) {
    final void Function(AudioCue, int, Rect)? onLookup = widget.onLookupCue;
    if (onLookup == null) return;
    if (!widget.hoverAutoLookupEnabled &&
        !HardwareKeyboard.instance.isShiftPressed) {
      // 未开「悬停即查词」且未按 Shift：复位节流锚，下次按 Shift 进入即触发。
      _lastRowHoverPos = Offset.zero;
      _lastRowHoverCueKey = null;
      _lastRowHoverGrapheme = -1;
      return;
    }
    final SubtitleListHit? hit = _hitTestRows(event.position);
    if (hit == null) return;
    final double dx = event.position.dx - _lastRowHoverPos.dx;
    final double dy = event.position.dy - _lastRowHoverPos.dy;
    final bool sameChar = identical(_lastRowHoverCueKey, hit.cue) &&
        hit.graphemeIndex == _lastRowHoverGrapheme;
    if (sameChar &&
        dx * dx + dy * dy < _kRowHoverThresholdPx * _kRowHoverThresholdPx) {
      return;
    }
    _lastRowHoverPos = event.position;
    _lastRowHoverCueKey = hit.cue;
    _lastRowHoverGrapheme = hit.graphemeIndex;
    onLookup(hit.cue, hit.graphemeIndex, hit.charRect);
  }

  @override
  void didUpdateWidget(covariant VideoSubtitleJumpPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _lastControllerCueIndex = widget.controller.currentCueIndex;
      _lastSubtitleCuesLoading = widget.controller.isSubtitleCuesLoading;
      _lastScrolledIndex = -1;
      final int currentRep =
          _representativeRaw(widget.controller.currentCueIndex);
      _scrollTargetRawIndex =
          _isCurrentCueVisible(currentRep) ? currentRep : null;
      _rowKeys.clear();
      _retainRowKeyFor(_scrollTargetRawIndex);
      _scheduleScrollToCurrentCue();
    }
    _clearCueCaches();
  }

  @override
  void dispose() {
    // BUG-874：面板卸载（侧栏隐藏）时解绑命中句柄，避免 barrier 调到已失效的实现。
    widget.hitTester?.unbind();
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    widget.controller.removeListener(_onControllerChanged);
    _scrollController.dispose();
    super.dispose();
  }

  /// BUG-874：按全局坐标反查当前可见行里命中的字符，返回 `(cue, grapheme, charRect)`。
  /// 供 [VideoSubtitleListHitTester] 绑定给查词浮层 dismiss barrier。无查词能力 / 无命中
  /// 返回 null（barrier 落回原 dismiss）。遍历 [_rowTextKeys]：滚出屏的行 `currentContext`
  /// 为 null 自动跳过；先粗判点落在哪行的段落框内，再逐字符精查。
  SubtitleListHit? _hitTestRows(Offset globalPos, {bool exactOnly = false}) {
    if (widget.onLookupCue == null || _rowHitCues.isEmpty) return null;
    for (final MapEntry<int, GlobalKey> entry in _rowTextKeys.entries) {
      final AudioCue? cue = _rowHitCues[entry.key];
      if (cue == null) continue;
      final RenderObject? ro = entry.value.currentContext?.findRenderObject();
      if (ro is! RenderParagraph || !ro.attached) continue;
      final Offset local = ro.globalToLocal(globalPos);
      if (!(Offset.zero & ro.size).contains(local)) continue;
      final SubtitleListCharHit? hit = subtitleListCharHitFromParagraph(
        ro,
        cue.text,
        localPosition: local,
        globalPosition: globalPos,
        exactOnly: exactOnly,
      );
      if (hit == null) continue;
      return (
        cue: cue,
        graphemeIndex: hit.graphemeIndex,
        charRect: hit.charRect,
      );
    }
    return null;
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final int currentIndex = widget.controller.currentCueIndex;
    final bool cuesLoading = widget.controller.isSubtitleCuesLoading;
    final bool cueChanged = currentIndex != _lastControllerCueIndex;
    final bool loadingChanged = cuesLoading != _lastSubtitleCuesLoading;
    if (!cueChanged && !loadingChanged) return;
    _lastControllerCueIndex = currentIndex;
    _lastSubtitleCuesLoading = cuesLoading;
    setState(() {
      // BUG-841：追踪代表行 raw（当前句可能是被折叠的重复项）。
      _scrollTargetRawIndex =
          currentIndex >= 0 ? _representativeRaw(currentIndex) : null;
      _retainRowKeyFor(_scrollTargetRawIndex);
    });
    if (cueChanged) _scheduleScrollToCurrentCue();
  }

  void _scheduleScrollToCurrentCue() {
    if (!_autoScroll) return;
    if (_scrollPostFrameScheduled) return;
    _scrollPostFrameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollPostFrameScheduled = false;
      if (mounted) _scrollToCurrentCueIfNeeded();
    });
  }

  void _scrollToCurrentCueIfNeeded() {
    if (!_autoScroll) return;
    final int rawIndex = widget.controller.currentCueIndex;
    final List<AudioCue> cues = widget.controller.cues;
    if (rawIndex < 0 || rawIndex >= cues.length) return;
    final List<int> visibleIndexes = _visibleCueIndexes(cues);
    // BUG-841：当前句若是被折叠的重复项，定位到其代表行（列表渲染的唯一行、rowKey 所在）。
    final int currentIndex = _representativeRaw(rawIndex);
    final int visibleIndex =
        _visibleIndexForRawIndex(currentIndex, visibleIndexes);
    if (visibleIndex < 0 || visibleIndex == _lastScrolledIndex) return;
    if (!_scrollController.hasClients) return;
    _lastScrolledIndex = visibleIndex;
    _scrollTargetRawIndex = currentIndex;
    _retainRowKeyFor(currentIndex);
    const Duration duration = Duration(milliseconds: 240);
    const Curve curve = Curves.easeOutCubic;
    // 可变行高下优先用 ensureVisible 把当前行精确居中（alignment 0.5）；目标行已挂载
    // 才有 RenderObject。未挂载（在远处视口外）时先按估算行高粗滚使其进入视口、下一帧
    // 再精确居中（TODO-340）。
    final BuildContext? rowContext = _rowKeys[currentIndex]?.currentContext;
    if (rowContext != null) {
      HibikiFocusScroll.ensureVisible(rowContext, duration: duration);
      return;
    }
    final double viewport = _scrollController.position.viewportDimension;
    final double rowWidth = widget.width;
    final double rowOffset = _estimatedScrollOffsetForVisibleIndex(
      visibleIndex,
      visibleIndexes,
      cues,
      rowWidth,
    );
    final double rowExtent = _rowExtentForCue(
      _rowCue(cues, currentIndex),
      rowWidth,
      // 目标行就是当前播放句，渲染时必加粗。
      bold: true,
    );
    final double target = rowOffset - (viewport / 2) + (rowExtent / 2);
    final double clamped =
        target.clamp(0.0, _scrollController.position.maxScrollExtent);
    final double distance = (clamped - _scrollController.position.pixels).abs();
    final bool farAway = distance > viewport * 3;
    if (farAway) {
      _scrollController.jumpTo(clamped);
    } else {
      _scrollController.animateTo(clamped, duration: duration, curve: curve);
    }
    // 粗滚后下一帧目标行多半已挂载，再精确居中一次。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final BuildContext? settled = _rowKeys[currentIndex]?.currentContext;
      if (settled != null) {
        HibikiFocusScroll.ensureVisible(settled, duration: duration);
      }
    });
  }

  void _toggleAutoScroll() {
    setState(() {
      _autoScroll = !_autoScroll;
      if (_autoScroll) _lastScrolledIndex = -1;
    });
    // TODO-613：通知页面层把新开关落 Drift preferences（null 时纯本地切换）。
    widget.onAutoScrollChanged?.call(_autoScroll);
    if (_autoScroll) {
      _scheduleScrollToCurrentCue();
    }
  }

  void _stepFont(int delta) {
    final int next =
        (_fontScaleIndex + delta).clamp(0, _kFontScaleSteps.length - 1);
    if (next == _fontScaleIndex) return;
    setState(() {
      _fontScaleIndex = next;
      _lastScrolledIndex = -1;
      // 字号变 → 行高变，旧 visibleIndex→key 映射作废（TODO-340）。
      _rowKeys.clear();
    });
    // BUG-878：通知页面层把新档位落 Drift preferences（null 时纯本地调整）。
    widget.onFontScaleIndexChanged?.call(next);
    _scheduleScrollToCurrentCue();
  }

  void _setFilter(Set<VideoSubtitleListFilter> next) {
    if (next.isEmpty) return;
    setState(() {
      _filter = next.single;
      _hoveredIndex = -1;
      _lastScrolledIndex = -1;
      // 过滤集变 → visibleIndex 重排，旧 visibleIndex→key 映射作废（TODO-340）。
      _rowKeys.clear();
      _clearCueCaches();
    });
    _scheduleScrollToCurrentCue();
  }

  bool _isCueSelectedForCard(AudioCue cue) =>
      widget.isCueSelectedForCard?.call(cue) ?? false;

  int _selectedCueCount(List<AudioCue> cues) {
    if (!_hasCueSelectionControls) return 0;
    if (identical(_cachedSelectedCues, cues) &&
        _cachedSelectedCuesLength == cues.length) {
      return _cachedSelectedCount;
    }
    // BUG-841：只数去重后的代表行，与 selected 档实际渲染的行一一对应。
    int count = 0;
    for (final int i in _dedupedRawIndexes(cues)) {
      if (_isCueSelectedForCard(_rowCue(cues, i))) count++;
    }
    _cachedSelectedCues = cues;
    _cachedSelectedCuesLength = cues.length;
    _cachedSelectedCount = count;
    return count;
  }

  /// 收藏档可见条目数（TODO-631）。与 [VideoSubtitleListFilter.favorites] 档实际渲染的
  /// 条目集合（[_visibleCueIndexes] 的 favorites 分支）一一对应——同一个 `isCueFavorited`
  /// 谓词，故数量与列表完全一致。这是已删的「本集收藏」面板顶部计数 header 的归宿：收藏
  /// 统计并入字幕列表收藏档。
  int _favoriteCueCount(List<AudioCue> cues) {
    // BUG-841：只数去重后的代表行，与 favorites 档实际渲染的行一一对应。
    int count = 0;
    for (final int i in _dedupedRawIndexes(cues)) {
      if (widget.isCueFavorited(_rowCue(cues, i))) count++;
    }
    return count;
  }

  /// BUG-841：按 `(startMs, 文本)` 折叠重复 cue，返回代表行 raw 下标（升序）并同步
  /// 刷新 [_cachedRepresentativeByRaw]（每个 raw → 其代表行 raw）。按 cues 身份 + 长度
  /// 记忆化（`setCues` 换列表即失效；[_clearCueCaches] 亦清）。特效叠加 / 多层同句拷贝
  /// 同 start 同文本 → 折叠成一行；双语文本不同 → 各自保留。
  List<int> _dedupedRawIndexes(List<AudioCue> cues) {
    if (identical(_cachedDedupCues, cues) &&
        _cachedDedupCuesLength == cues.length) {
      return _cachedDedupIndexes;
    }
    final List<int> reps = <int>[];
    final Map<String, int> firstByKey = <String, int>{};
    final Map<int, int> repByRaw = <int, int>{};
    // TODO-1384：先把 ASS 逐字卡拉OK 事件合并成整句组（判据见
    // [mergePerCharacterCueGroups]）。组内非组首成员直接映射到组首、不进 reps——它与
    // 下面按 `(startMs, 文本)` 的重复折叠是**同一个代表行机制**的两种成因，故共用一张
    // repByRaw 表：当前播放句落在任一单字事件上，都能定位回那唯一渲染的整句行。
    final ({Map<int, AudioCue> byRep, Map<int, int> repByRaw}) mergedGroups =
        mergePerCharacterCueGroups(cues);
    for (int i = 0; i < cues.length; i++) {
      final int? mergedRep = mergedGroups.repByRaw[i];
      if (mergedRep != null) {
        repByRaw[i] = mergedRep;
        if (mergedRep == i) reps.add(i);
        continue;
      }
      final AudioCue cue = cues[i];
      final String key = '${cue.startMs}\u0000${cue.text}';
      final int? rep = firstByKey[key];
      if (rep == null) {
        firstByKey[key] = i;
        repByRaw[i] = i;
        reps.add(i);
      } else {
        repByRaw[i] = rep;
      }
    }
    _cachedDedupCues = cues;
    _cachedDedupCuesLength = cues.length;
    _cachedDedupIndexes = reps;
    _cachedRepresentativeByRaw = repByRaw;
    _cachedMergedByRep = mergedGroups.byRep;
    return reps;
  }

  /// 某个**代表行**在列表里实际呈现/交互所用的 cue（TODO-1384）。逐字卡拉OK 组返回
  /// 合成的整句 cue，其余行返回原 cue（既有行为逐像素不变）。
  ///
  /// 列表内一切「这一行是什么」的读取都必须经此单一入口——行文本、行高测量、点击跳转、
  /// 逐字查词、收藏 toggle、制卡选择全部同源，才不会出现「列表显示整句、制卡只拿到一个
  /// 字」的割裂。
  AudioCue _rowCue(List<AudioCue> cues, int rawIndex) {
    _dedupedRawIndexes(cues);
    return _cachedMergedByRep[rawIndex] ?? cues[rawIndex];
  }

  /// 把任意 raw 下标（可能是被折叠的重复项）映射到其代表行 raw 下标（BUG-841）。当前
  /// 播放句落在重复拷贝上时，用它把高亮 / 自动滚动定位到唯一渲染的代表行。
  int _representativeRaw(int rawIndex) {
    if (rawIndex < 0) return rawIndex;
    _dedupedRawIndexes(widget.controller.cues);
    return _cachedRepresentativeByRaw[rawIndex] ?? rawIndex;
  }

  List<int> _visibleCueIndexes(List<AudioCue> cues) {
    // 收藏档（[VideoSubtitleListFilter.favorites]）的成员集由 *实时* [isCueFavorited]
    // 谓词决定，而该谓词可在 panel widget 身份不变（如页面层用稳定的 `_isCueFavorited`
    // 方法 tear-off）的情况下变化——收藏 toggle 不触发 [didUpdateWidget] 的兜底
    // `_clearCueCaches()`。若把收藏档也按 `(cues 身份, 长度, filter)` 缓存，收藏状态变
    // 后这三者都没变 → 命中陈旧成员集 → 列表延迟（计数 chip 走未缓存的
    // [_favoriteCueCount] 即时更新，列表却落后，TODO-632/BUG-359）。故收藏档**不缓存**：
    // 每次重算（收藏档条目通常不多，成本可接受）。`all` / `selected` 仍按结构键缓存
    // （`all` 纯结构；`selected` 经 onToggleCueSelection→页面 setState 触发 didUpdateWidget
    // 清缓存，保留其缓存性能）。
    final bool cacheable = _filter != VideoSubtitleListFilter.favorites;
    if (cacheable &&
        identical(_cachedCues, cues) &&
        _cachedCuesLength == cues.length &&
        _cachedFilter == _filter) {
      return _cachedVisibleIndexes;
    }
    // BUG-841：三档都以**去重后**的代表行为基（特效叠加同句拷贝只出一行）；收藏 / 已选
    // 再在代表行上过滤，计数 chip 走同一去重集合（[_favoriteCueCount] / [_selectedCueCount]）
    // 故数量与列表一致。
    final List<int> base = _dedupedRawIndexes(cues);
    late final List<int> indexes;
    switch (_filter) {
      case VideoSubtitleListFilter.all:
        indexes = base;
        break;
      case VideoSubtitleListFilter.favorites:
        indexes = <int>[
          for (final int i in base)
            if (widget.isCueFavorited(_rowCue(cues, i))) i,
        ];
        break;
      case VideoSubtitleListFilter.selected:
        indexes = <int>[
          for (final int i in base)
            if (_isCueSelectedForCard(_rowCue(cues, i))) i,
        ];
        break;
    }
    // [_visibleIndexForRawIndex] 非 all 档读 [_cachedVisibleIndexByRawIndex]，故收藏档
    // 即便不走 visibleIndexes 缓存，也必须每次同步刷新该 raw→visible 映射（用本次重算
    // 的 indexes）；否则收藏档自动滚动定位会按陈旧映射。`_cachedCues` / `_cachedFilter`
    // 仍记为收藏档，使任何后续非收藏档命中前都因 filter 不等而重算。
    _cachedCues = cues;
    _cachedCuesLength = cues.length;
    _cachedFilter = _filter;
    _cachedVisibleIndexes = indexes;
    _cachedVisibleIndexByRawIndex = <int, int>{
      for (int i = 0; i < indexes.length; i++) indexes[i]: i,
    };
    return indexes;
  }

  int _visibleIndexForRawIndex(int rawIndex, List<int> visibleIndexes) {
    // BUG-841：去重后 `all` 档不再是恒等映射（重复项被折叠、raw 下标有跳空），三档统一走
    // raw→代表行→可见位置映射；当前句落在被折叠的重复项时，定位到其代表行。
    final int rep = _cachedRepresentativeByRaw[rawIndex] ?? rawIndex;
    return _cachedVisibleIndexByRawIndex[rep] ?? -1;
  }

  bool _isCurrentCueVisible(int rawIndex) {
    final List<AudioCue> cues = widget.controller.cues;
    if (rawIndex < 0 || rawIndex >= cues.length) return false;
    final List<int> visibleIndexes = _visibleCueIndexes(cues);
    return _visibleIndexForRawIndex(rawIndex, visibleIndexes) >= 0;
  }

  double _initialScrollOffsetForCurrentCue() {
    final int currentIndex = widget.controller.currentCueIndex;
    final List<AudioCue> cues = widget.controller.cues;
    if (currentIndex < 0 || currentIndex >= cues.length) return 0;
    final List<int> visibleIndexes = _visibleCueIndexes(cues);
    final int visibleIndex =
        _visibleIndexForRawIndex(currentIndex, visibleIndexes);
    if (visibleIndex < 0) return 0;
    final int contextIndex =
        (visibleIndex - 3).clamp(0, visibleIndexes.length - 1).toInt();
    return _estimatedScrollOffsetForVisibleIndex(
      contextIndex,
      visibleIndexes,
      cues,
      widget.width,
    );
  }

  void _clearCueCaches() {
    _cachedCues = null;
    _cachedCuesLength = -1;
    _cachedFilter = null;
    _cachedVisibleIndexes = const <int>[];
    _cachedVisibleIndexByRawIndex = const <int, int>{};
    _cachedSelectedCues = null;
    _cachedSelectedCuesLength = -1;
    _cachedSelectedCount = 0;
    _cachedDedupCues = null;
    _cachedDedupCuesLength = -1;
    _cachedDedupIndexes = const <int>[];
    _cachedRepresentativeByRaw = const <int, int>{};
    // 与 dedup 表同生命周期（同一次遍历产出）：漏清会让换轨/换片后的列表拿到上一份
    // 字幕的合成整句（TODO-1384）。
    _cachedMergedByRep = const <int, AudioCue>{};
  }

  void _retainRowKeyFor(int? rawIndex) {
    _rowKeys.removeWhere((int key, _) => key != rawIndex);
  }

  String _filterLabel(VideoSubtitleListFilter filter) {
    switch (filter) {
      case VideoSubtitleListFilter.all:
        return t.video_subtitle_filter_all;
      case VideoSubtitleListFilter.favorites:
        return t.video_subtitle_filter_favorites;
      case VideoSubtitleListFilter.selected:
        return t.video_subtitle_filter_selected;
    }
  }

  @override
  Widget build(BuildContext context) {
    // BUG-874：把当前可见行的命中实现绑给查词浮层 dismiss barrier；每帧重置行 cue 登记表，
    // 仅本帧真正构建（itemBuilder 调用）的行回填，避免读到上一帧的旧 cue。
    widget.hitTester?.bindHitTest(_hitTestRows);
    _rowHitCues.clear();
    // BUG-1034：行高测量必须用与渲染一致的排版环境（文字缩放 / 书写方向）。
    _textDirection = Directionality.of(context);
    _textScaler = MediaQuery.textScalerOf(context);
    final ColorScheme cs = widget.colorScheme;
    final List<AudioCue> cues = widget.controller.cues;
    final List<int> visibleIndexes = _visibleCueIndexes(cues);
    // BUG-841：当前句可能是被折叠的重复项——映射到其代表行 raw（列表渲染的唯一行）供高亮
    // 与 rowKey 保留，否则当前句落在重复拷贝时整行都不高亮。
    final int currentIndex =
        _representativeRaw(widget.controller.currentCueIndex);
    _retainRowKeyFor(currentIndex >= 0 ? currentIndex : _scrollTargetRawIndex);
    final bool showLoading =
        cues.isEmpty && widget.controller.isSubtitleCuesLoading;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: widget.width,
        color: cs.surface.withValues(alpha: 0.92),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildHeader(cs, cues),
            const Divider(height: 1),
            Expanded(
              // BUG-878：Ctrl / ⌘ + 滚轮缩字号（浏览器式）。Listener 不消费滚轮信号，
              // 裸滚轮照常下探给 ListView 滚动；Ctrl 按住时 ListView 已切禁滚物理，故只缩
              // 字号不滚动。translucent 覆盖含空态 / 加载态整块，任意处 Ctrl+滚轮均可缩放。
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerSignal: _handleZoomWheel,
                // BUG-879：面板级 Shift-悬停查词（复用 RenderParagraph 反查，轻量）。
                onPointerHover: _handleListShiftHover,
                child: showLoading
                    ? _buildLoading(cs)
                    : cues.isEmpty || visibleIndexes.isEmpty
                        ? _buildEmpty(cs, cuesLoaded: cues.isNotEmpty)
                        // 行高按真实文本布局测量（[_rowExtentForCue]，BUG-1034），与
                        // itemExtentBuilder 的硬约束一致，长句换行不会被裁掉末行。每行包
                        // 一个 GlobalKey（存 _rowKeys，按 rawIndex）供 ensureVisible 自动滚动。
                        : ListView.builder(
                            controller: _scrollController,
                            // BUG-878：Ctrl / ⌘ 按住时禁列表滚动，让 Ctrl+滚轮只缩字号
                            // （[_handleZoomWheel]）；松开恢复默认滚动物理。
                            physics: _zoomModifierHeld
                                ? const NeverScrollableScrollPhysics()
                                : null,
                            itemExtentBuilder:
                                (int i, SliverLayoutDimensions dimensions) {
                              if (i < 0 || i >= visibleIndexes.length) {
                                return null;
                              }
                              final int rawIndex = visibleIndexes[i];
                              final AudioCue cue = _rowCue(cues, rawIndex);
                              return _rowExtentForCue(
                                cue,
                                dimensions.crossAxisExtent,
                                bold: _isRowBold(rawIndex, cue),
                              );
                            },
                            itemCount: visibleIndexes.length,
                            itemBuilder: (BuildContext _, int i) {
                              final int rawIndex = visibleIndexes[i];
                              final AudioCue cue = _rowCue(cues, rawIndex);
                              final bool selected = rawIndex == currentIndex;
                              final bool trackKey =
                                  selected || rawIndex == _scrollTargetRawIndex;
                              final Key rowKey = trackKey
                                  ? _rowKeys.putIfAbsent(
                                      rawIndex, GlobalKey.new)
                                  : ValueKey<int>(rawIndex);
                              return KeyedSubtree(
                                key: rowKey,
                                child: _buildRow(
                                  cs,
                                  cue,
                                  i,
                                  selected,
                                ),
                              );
                            },
                          ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme cs, List<AudioCue> cues) {
    final double iconSize = widget.fontSize + 4;
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 4, top: 4, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: widget.fontSize + 1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: t.video_subtitle_list_font_smaller,
                icon: Icon(Icons.text_decrease, size: iconSize),
                color: _fontScaleIndex > 0 ? cs.onSurfaceVariant : cs.outline,
                onPressed: _fontScaleIndex > 0 ? () => _stepFont(-1) : null,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: t.video_subtitle_list_font_larger,
                icon: Icon(Icons.text_increase, size: iconSize),
                color: _fontScaleIndex < _kFontScaleSteps.length - 1
                    ? cs.onSurfaceVariant
                    : cs.outline,
                onPressed: _fontScaleIndex < _kFontScaleSteps.length - 1
                    ? () => _stepFont(1)
                    : null,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: t.video_subtitle_list_auto_scroll,
                icon: Icon(
                  _autoScroll
                      ? Icons.vertical_align_center
                      : Icons.pause_circle_outline,
                  size: iconSize,
                ),
                color: _autoScroll ? cs.primary : cs.onSurfaceVariant,
                onPressed: _toggleAutoScroll,
                visualDensity: VisualDensity.compact,
              ),
              // TODO-637：字幕列表是「带 × 的非阻塞侧栏」——头部带回右上角 × 关闭
              // 按钮（BUG-254 当初移除 ×、改点画面 barrier 关闭，但该 barrier 罩在画面
              // 字幕查词手势上致画面查不了词，TODO-636）。× 调 onClose（页面层清挖词
              // 选择 + 隐藏列表），与 Esc / 控制条字幕按钮三路关闭等价。锁定按钮（原
              // TODO-611，唯一作用是门控已删的 barrier）随 barrier 一并移除（TODO-634）。
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                icon: Icon(Icons.close, size: iconSize),
                color: cs.onSurfaceVariant,
                onPressed: widget.onClose,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: HorizontalDragScrollable(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<VideoSubtitleListFilter>(
                      showSelectedIcon: false,
                      segments: VideoSubtitleListFilter.values
                          .map(
                            (VideoSubtitleListFilter filter) =>
                                ButtonSegment<VideoSubtitleListFilter>(
                              value: filter,
                              label: Text(_filterLabel(filter)),
                            ),
                          )
                          .toList(growable: false),
                      selected: <VideoSubtitleListFilter>{_filter},
                      onSelectionChanged: _setFilter,
                      style: SegmentedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        textStyle: TextStyle(fontSize: widget.fontSize - 1),
                      ),
                    ),
                  ),
                ),
              ),
              // TODO-631：收藏档收藏数。删了独立「本集收藏」面板后，其顶部「收藏 N」计数
              // 并入字幕列表收藏档——只在 favorites 档显示，让用户切到收藏档时一眼看到本
              // 视频已收藏多少句（与列表条目数一致，复用同一 isCueFavorited 谓词）。
              if (_filter == VideoSubtitleListFilter.favorites)
                Padding(
                  padding: const EdgeInsets.only(left: 8, right: 4),
                  child: Text(
                    t.video_favorite_count(count: _favoriteCueCount(cues)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.primary,
                      fontSize: widget.fontSize - 1,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (_hasCueSelectionControls && _selectedCueCount(cues) > 0)
                Tooltip(
                  message: t.video_subtitle_list_clear_selection,
                  child: IconButton(
                    icon: Icon(Icons.clear_all, size: iconSize),
                    color: cs.onSurfaceVariant,
                    onPressed: widget.onClearCueSelection,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 空态文案（TODO-631 / BUG-795）。必须区分两种「无行可显示」：
  ///   1. `cuesLoaded == false`：字幕本体一条都没有（真未加载）→ [widget.emptyHint]
  ///      （"未加载字幕"）。
  ///   2. `cuesLoaded == true` 但当前过滤档（收藏 / 已选）筛出 0 条：字幕已加载，只是
  ///      本档为空 → 给**过滤档专属**文案，别再误报"未加载字幕"（用户报的核心症状：
  ///      收藏 0 句时切到收藏档，明明有字幕却显示未加载）。「全部」档筛出 0 条只可能因
  ///      cues 本身为空（[VideoSubtitleListFilter.all] 全量映射），故落回 [widget.emptyHint]。
  Widget _buildEmpty(ColorScheme cs, {required bool cuesLoaded}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _emptyHintForFilter(cuesLoaded: cuesLoaded),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: cs.onSurfaceVariant,
            fontSize: _effectiveFontSize,
          ),
        ),
      ),
    );
  }

  String _emptyHintForFilter({required bool cuesLoaded}) {
    if (!cuesLoaded) return widget.emptyHint;
    switch (_filter) {
      case VideoSubtitleListFilter.favorites:
        return t.video_subtitle_filter_favorites_empty;
      case VideoSubtitleListFilter.selected:
        return t.video_subtitle_filter_selected_empty;
      case VideoSubtitleListFilter.all:
        return widget.emptyHint;
    }
  }

  Widget _buildLoading(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              widget.loadingHint ?? widget.emptyHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: _effectiveFontSize,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(ColorScheme cs, AudioCue cue, int index, bool selected) {
    // BUG-874：可查词时给本行文本一个稳定 [GlobalKey]（按 builder 下标）并登记所属 cue，供
    // [_hitTestRows] 反查。不可查词（onLookupCue==null）时不登记，行为与历史一致。
    final GlobalKey? textKey = widget.onLookupCue == null
        ? null
        : _rowTextKeys.putIfAbsent(index, GlobalKey.new);
    if (textKey != null) _rowHitCues[index] = cue;
    final bool hovered = index == _hoveredIndex;
    final bool selectedForCard = _isCueSelectedForCard(cue);
    // 收藏（[favorited]）是持久属性，不抢「正在播 / 挖词选中 / hover」的背景色：用左侧
    // 竖色条 + 行内实心星标记，与三种瞬态背景正交叠加（BUG-264）。背景优先级仍为
    // current > selectedForCard > hover。
    final bool favorited = widget.isCueFavorited(cue);
    final Color bg = selected
        ? cs.primaryContainer
        : selectedForCard
            ? cs.secondaryContainer.withValues(alpha: 0.72)
            : favorited
                ? cs.tertiaryContainer.withValues(alpha: 0.32)
                : (hovered
                    ? cs.onSurface.withValues(alpha: 0.06)
                    : Colors.transparent);
    final Color tsColor = selected
        ? cs.onPrimaryContainer
        : selectedForCard
            ? cs.onSecondaryContainer
            : cs.onSurfaceVariant;
    final Color textColor = selected
        ? cs.onPrimaryContainer
        : selectedForCard
            ? cs.onSecondaryContainer
            : cs.onSurface;
    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredIndex = index),
      onExit: (_) {
        if (_hoveredIndex == index) setState(() => _hoveredIndex = -1);
      },
      child: InkWell(
        // 行点击 = seek 到该句（与 asbplayer transcript 一致）。文本字符查词由文本区
        // 叠加的 translucent hit-test 层承载（[onLookupCue] 非 null 时），它赢手势竞技场、
        // 截断本 InkWell，故点字查词、点空白 / 时间戳 seek，两不冲突（BUG-263）。
        onTap: () => widget.onTapCue(cue),
        child: Container(
          // 左侧 3px 竖色条标记已收藏行（BUG-264）：未收藏时无边框、像素级不变。背景色
          // 统一走 [decoration]（不能同时传 color 与 decoration）。
          //
          // BUG-1034：色条占的 3px 从**左内缩里扣**（5 + 3 = 8），使内容起点与文本列宽
          // 恒定，不随收藏状态漂移——否则收藏行文本列凭空窄 3px，行高测量（按无边框宽度
          // 算）就会偏小、末行被裁；顺带消除收藏时整行文字右移 3px 的抖动。
          padding: EdgeInsets.only(
            left: favorited
                ? kSubtitleRowPaddingLeft - kSubtitleRowFavoriteBarWidth
                : kSubtitleRowPaddingLeft,
            right: kSubtitleRowPaddingRight,
            top: kSubtitleRowPaddingVertical / 2,
            bottom: kSubtitleRowPaddingVertical / 2,
          ),
          decoration: BoxDecoration(
            color: bg,
            border: favorited
                ? Border(
                    left: BorderSide(
                      color: cs.tertiary,
                      width: kSubtitleRowFavoriteBarWidth,
                    ),
                  )
                : null,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (_hasCueSelectionControls) ...<Widget>[
                _buildSelectionCheckbox(cs, cue, selectedForCard),
                const SizedBox(width: kSubtitleRowSelectionGap),
              ],
              SizedBox(
                // TODO-567：列宽随字号缩放（[_timestampColumnWidth]），且时间戳单行
                // 不换行、超宽省略，绝不溢出到右侧字幕文本列（修「时间被下一条字幕
                // 挡住 / 溢出」）。
                width: _timestampColumnWidth,
                child: Text(
                  formatCueTimestamp(cue.startMs),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tsColor,
                    fontSize: _effectiveFontSize - 1,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: kSubtitleRowTimestampGap),
              Expanded(
                  child: _buildRowText(
                      cue, textColor, selected, selectedForCard, textKey)),
              // 操作按钮（跳转 / 复制 / 收藏）常驻，不再仅 hover / 选中可见（BUG-265）：
              // 长文本由上面单行省略让出空间，按钮不会挤坏布局。
              _buildRowActions(cs, cue, selected, favorited),
            ],
          ),
        ),
      ),
    );
  }

  /// 行的字幕文本。**允许换行显示完整字幕**（TODO-340：放开 BUG-266 的单行省略，固定
  /// [_itemExtent] 也随之放弃改自适应行高）。[VideoSubtitleJumpPanel.onLookupCue] 非 null
  /// 时仍只渲染单个 [RichText]，点击命中由同源 [TextPainter] 按 UTF-16 offset 反查
  /// grapheme，避免长字幕为每个字符创建独立 widget。
  Widget _buildRowText(
    AudioCue cue,
    Color textColor,
    bool selected,
    bool selectedForCard,
    GlobalKey? textKey,
  ) {
    // BUG-1034：与行高测量（[_measureRowExtent]）共用同一样式，断行结果一致，末行不被裁。
    final TextStyle textStyle = _rowTextStyle(
      bold: selected || selectedForCard,
      color: textColor,
    );
    final void Function(AudioCue, int, Rect)? onLookup = widget.onLookupCue;
    if (onLookup == null) {
      // 无查词能力：整段文本（换行），不叠 tap 层，外层 InkWell 行点击仍 seek。
      return Text(cue.text, style: textStyle);
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final TextSpan textSpan = TextSpan(text: cue.text, style: textStyle);
        final TextDirection textDirection = Directionality.of(context);
        final TextScaler textScaler = MediaQuery.textScalerOf(context);
        final double maxWidth = constraints.maxWidth;

        SubtitleListCharHit? hitAt({
          required Offset localPosition,
          required Offset globalPosition,
        }) {
          // BUG-874：grapheme 偏移表用顶层纯 helper（与 barrier 反查
          // [subtitleListCharHitFromParagraph] 同源）。
          final List<int> starts = subtitleGraphemeStartOffsets(cue.text);
          final List<int> ends = subtitleGraphemeEndOffsets(cue.text);
          if (starts.isEmpty) return null;
          final TextPainter painter = TextPainter(
            text: textSpan,
            textAlign: TextAlign.start,
            textDirection: textDirection,
            textScaler: textScaler,
            maxLines: null,
            ellipsis: null,
          );
          try {
            painter.layout(maxWidth: maxWidth);
            // BUG-916：与 barrier / hover 反查同款——对每个 grapheme 的真实渲染盒做几何命中，
            // 不再走 getPositionForOffset 的 caret 边界（会把某字左右半格塌陷到同一边界、
            // 系统性偏左一格）。BUG-879：BoxHeightStyle.max 覆盖整行视觉格，点在行距里也命中。
            final List<Rect> rects = <Rect>[
              for (int i = 0; i < starts.length; i++)
                _subtitleUnionBoxes(
                  painter.getBoxesForSelection(
                    TextSelection(baseOffset: starts[i], extentOffset: ends[i]),
                    boxHeightStyle: BoxHeightStyle.max,
                  ),
                ),
            ];
            final int graphemeIndex =
                resolveSubtitleListGraphemeHit(rects, localPosition);
            if (graphemeIndex < 0) return null;
            Rect localRect = rects[graphemeIndex];
            if (!localRect.contains(localPosition)) {
              // 字缝 / 行距兜底命中：扩盒含点，保证 charRect 始终含指针。
              localRect = localRect.expandToInclude(
                Rect.fromCenter(center: localPosition, width: 1, height: 1),
              );
            }
            final Offset globalOrigin = globalPosition - localPosition;
            return (
              graphemeIndex: graphemeIndex,
              charRect: localRect.shift(globalOrigin),
            );
          } finally {
            painter.dispose();
          }
        }

        return GestureDetector(
          // translucent：tap 赢手势竞技场截断外层 InkWell（点文本 = 查词、非 seek），
          // 但空白处手动回落到行 seek，保留“点字查词、点空白 seek”的语义。
          // BUG-879：Shift-悬停查词不再挂逐行 MouseRegion（会为每次 hover 新建 TextPainter
          // 重排整行、比画面字幕重），改由面板级单一 Listener [_handleListShiftHover] 复用
          // [_hitTestRows] 的 RenderParagraph 反查（不重排、与画面字幕几何反查一样轻）。
          behavior: HitTestBehavior.translucent,
          onTapUp: (TapUpDetails details) {
            final SubtitleListCharHit? hit = hitAt(
              localPosition: details.localPosition,
              globalPosition: details.globalPosition,
            );
            // BUG-879：点在字符上（含字缝 / 行距 leading 容差，见 hitAt）即查词；命中即
            // 用返回的 charRect 定位，不再额外 `contains` 二次收窄（那会把容差内命中又判成
            // 空白误退 seek，正是「点了不出词」的一半病因）。
            if (hit != null) {
              onLookup(cue, hit.graphemeIndex, hit.charRect);
              return;
            }
            widget.onTapCue(cue);
          },
          child: RichText(
            // BUG-872：稳定 key 让 [_hitTestRows] 能按 builder 下标取到本行 RenderParagraph
            // 反查字符命中（供查词浮层 dismiss barrier 切换查词 + 列表 Shift-悬停 / keydown）。
            key: textKey,
            text: textSpan,
            softWrap: true,
            overflow: TextOverflow.clip,
            maxLines: null,
            textAlign: TextAlign.start,
            textDirection: textDirection,
            textScaler: textScaler,
          ),
        );
      },
    );
  }

  Widget _buildSelectionCheckbox(
    ColorScheme cs,
    AudioCue cue,
    bool selectedForCard,
  ) {
    // BUG-1034：勾选框列宽 / 高锁死为 [kSubtitleRowSelectionSize]（即 compact + shrinkWrap
    // 下 Checkbox 的实际 36×36），让行高测量用的几何常量不被主题里的 visualDensity 改动带偏。
    return SizedBox.square(
      dimension: kSubtitleRowSelectionSize,
      child: Tooltip(
        message: selectedForCard
            ? t.video_subtitle_list_remove_from_card
            : t.video_subtitle_list_select_for_card,
        child: Checkbox(
          value: selectedForCard,
          onChanged: (_) => widget.onToggleCueSelection?.call(cue),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          activeColor: cs.secondary,
          checkColor: cs.onSecondary,
        ),
      ),
    );
  }

  Widget _buildRowActions(
    ColorScheme cs,
    AudioCue cue,
    bool selected,
    bool favorited,
  ) {
    final Color iconColor =
        selected ? cs.onPrimaryContainer : cs.onSurfaceVariant;
    final double iconSize = _effectiveFontSize + 2;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _RowActionButton(
          icon: Icons.play_arrow,
          tooltip: t.video_subtitle_list_jump,
          color: iconColor,
          size: iconSize,
          onPressed: () => widget.onTapCue(cue),
        ),
        _RowActionButton(
          icon: Icons.content_copy_outlined,
          tooltip: t.copy,
          color: iconColor,
          size: iconSize,
          onPressed: () => widget.onCopyCue(cue),
        ),
        _RowActionButton(
          icon: favorited ? Icons.star : Icons.star_border,
          tooltip: t.collection_sentence,
          color: favorited ? cs.primary : iconColor,
          size: iconSize,
          onPressed: () => widget.onFavoriteCue(cue),
        ),
      ],
    );
  }
}

class _RowActionButton extends StatelessWidget {
  const _RowActionButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.size,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final double size;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: size,
        // TODO-1200：内缩从 4 压到 2，收窄常驻 3 个操作图标的动作列，把行宽还给中间的
        // 字幕文本列（窄面板上文本不再被挤成 3-4 字硬折行）。图标仍常驻可见（不改 BUG-265
        // 的常显语义），只是更紧凑。
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(icon, size: size, color: color),
        ),
      ),
    );
  }
}

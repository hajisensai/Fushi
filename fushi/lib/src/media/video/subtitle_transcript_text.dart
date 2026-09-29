import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

/// 字幕列表行的**固定几何**（BUG-1034）。行高由 `itemExtentBuilder` 事先给出，若与真实
/// 渲染几何有一丝偏差，`SliverVariedExtentList` 就按给定 extent 裁掉超出的文本（用户报的
/// 「ら 只露半个」）。所以文本列宽必须由**同一组常量**同时喂给测量与渲染，不能各算各的。
///
/// 行内水平结构（见 `_buildRow`）：
/// `padding.left(8) | 时间戳列 | 间隙 8 | 文本(Expanded) | 动作列 | padding.right(4+gutter)`
const double kSubtitleRowPaddingLeft = 8;
const double kSubtitleRowPaddingRight = 4;

/// 行右侧再让出的滚动条通道（BUG-1997）。
///
/// 桌面端 `MaterialScrollBehavior` 给这个 ListView 自动包了一层常驻 `Scrollbar`，
/// 它是**覆盖式**的（不占布局），而本行右内缩被压到 4px 以把宽度还给文本列——星标
/// 按钮的图标盒右缘离面板右缘只有 6px，滚动条盖住它并吞掉点击。
///
/// 这里让出通道，而不是靠「滚动条恰好够细」：宽度取自 [kFushiScrollbarGutter]，跟着
/// 主题的粗细走。用行 padding 而不是 `ListView(padding:)`——后者会让行背景/选中高亮
/// 不铺满、右侧露一条底色，还会改变 `itemExtentBuilder` 拿到的 crossAxisExtent。
const double kSubtitleRowScrollbarGutter = kFushiScrollbarGutter;

/// 行垂直内缩（上 8 + 下 8）。
const double kSubtitleRowPaddingVertical = 16;

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
}) {
  final double width =
      rowWidth -
      kSubtitleRowPaddingLeft -
      kSubtitleRowPaddingRight -
      kSubtitleRowScrollbarGutter -
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

/// 字幕列表行内点击命中的字符：被点 grapheme 下标 + 该字符的全局屏幕矩形 +
/// 查词浮层锚点矩形。供 [VideoSubtitleJumpPanel.onLookupCue] 精确查词（TODO-340）。
///
/// [charRect] 是被点字符本身的盒（命中语义、去重与调试用）；[anchorRect] 是喂给
/// 查词浮层定位的锚（BUG-2367，见 [subtitleListLookupAnchorRect]）。两者只在
/// 被查词跨行时不同。
typedef SubtitleListCharHit = ({
  int graphemeIndex,
  Rect charRect,
  Rect anchorRect,
});

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

/// 查词浮层的锚点矩形（BUG-2367）：被点字位 [graphemeIndex] 起、直到句末的所有字形盒
/// 并集（[rects] 是本行每个 grapheme 的渲染盒，行内坐标）。
///
/// 浮层定位的不变式是「绝不盖住被查词」（BUG-098，`calcPopupPosition` 只按锚点的
/// top/bottom 往上或往下贴）。而**被查词的长度在推浮层时还不知道**——查询串恒是
/// 「被点字位 → 句末」，引擎回报的最长匹配（`matchedRunes`）要等查完才有。若拿被点
/// 的**单个字**当锚，词被换行拆开时第二排就不在锚里，浮层贴在第一排下方正好压住它
/// （列表面板窄、行文本满宽，长句常年换行，这是常态不是边角）。
///
/// 取「被点字位到句末」的并集即可让锚**必然包含**被查词——匹配串恒是这段的前缀，
/// 不需要知道它到底多长，也不需要查完再挪浮层（挪＝肉眼可见的跳）。纵向只会多让出
/// 被点字位之后的那几行，横向不影响（横排避让只读 top/bottom）。
///
/// 拉丁词点在词中间时起点会回退到词首（`subtitleLookupSpan`），但 Flutter 软换行不
/// 在单词内部断行，词首与被点字母恒在同一视觉行，锚的上边界因此不会漏。
@visibleForTesting
Rect subtitleListLookupAnchorRect(List<Rect> rects, int graphemeIndex) {
  if (graphemeIndex < 0 || graphemeIndex >= rects.length) return Rect.zero;
  Rect anchor = rects[graphemeIndex];
  for (int i = graphemeIndex + 1; i < rects.length; i++) {
    final Rect r = rects[i];
    if (r.isEmpty) continue;
    anchor = anchor.expandToInclude(r);
  }
  return anchor;
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
  final int graphemeIndex = resolveSubtitleListGraphemeHit(
    rects,
    localPosition,
  );
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
  // BUG-2367：浮层锚取「被点字位→句末」并集（含容差扩过的 localRect），保证被查词
  // 换行后的第二排也在锚里、不会被浮层压住。
  final Rect anchor = subtitleListLookupAnchorRect(
    rects,
    graphemeIndex,
  ).expandToInclude(localRect);
  return (
    graphemeIndex: graphemeIndex,
    charRect: localRect.shift(globalOrigin),
    anchorRect: anchor.shift(globalOrigin),
  );
}

/// Shared typography for video subtitles and streamed game dialogue.
TextStyle subtitleTranscriptTextStyle({
  required double fontSize,
  required bool selected,
  Color? color,
  String? fontFamily,
}) => TextStyle(
  color: color,
  fontSize: fontSize,
  fontWeight: selected ? FontWeight.w600 : null,
  fontFamily: fontFamily,
  height: 1.25,
);

/// One wrapped paragraph with the video subtitle sidebar's character hit test.
/// Keyboard lookup is opt-in; arrows move by grapheme and Enter queries the
/// same character as a tap. The text stays a single paragraph in either mode.
class SubtitleTranscriptText extends StatefulWidget {
  const SubtitleTranscriptText({
    required this.text,
    required this.style,
    required this.onLookup,
    this.textKey,
    this.onBackgroundTap,
    this.keyboardLookup = false,
    super.key,
  });

  final String text;
  final TextStyle style;
  final void Function(int graphemeIndex, Rect anchor) onLookup;
  final Key? textKey;
  final VoidCallback? onBackgroundTap;
  final bool keyboardLookup;

  @override
  State<SubtitleTranscriptText> createState() => _SubtitleTranscriptTextState();
}

class _SubtitleTranscriptTextState extends State<SubtitleTranscriptText> {
  int _caret = 0;
  bool _focused = false;

  @override
  void didUpdateWidget(SubtitleTranscriptText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _caret = 0;
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final int count = widget.text.characters.length;
    if (count == 0) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;
    final bool activate =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space;
    final bool move =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end;
    if (!activate && !move) return KeyEventResult.ignored;
    if (event is KeyUpEvent) return KeyEventResult.handled;
    if (activate) {
      if (event is KeyDownEvent) widget.onLookup(_caret, Rect.zero);
    } else {
      setState(() {
        if (key == LogicalKeyboardKey.home) {
          _caret = 0;
        } else if (key == LogicalKeyboardKey.end) {
          _caret = count - 1;
        } else {
          _caret = (_caret + (key == LogicalKeyboardKey.arrowRight ? 1 : -1))
              .clamp(0, count - 1);
        }
      });
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final Widget paragraph = _buildParagraph(context);
    if (!widget.keyboardLookup) return paragraph;
    return Focus(
      onFocusChange: (bool value) => setState(() => _focused = value),
      onKeyEvent: _handleKey,
      child: paragraph,
    );
  }

  Widget _buildParagraph(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final List<String> graphemes = _focused
            ? widget.text.characters.toList()
            : const <String>[];
        final TextSpan textSpan = _focused && graphemes.isNotEmpty
            ? TextSpan(
                style: widget.style,
                children: <TextSpan>[
                  TextSpan(text: graphemes.take(_caret).join()),
                  TextSpan(
                    text: graphemes[_caret],
                    style: TextStyle(
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.25),
                    ),
                  ),
                  TextSpan(text: graphemes.skip(_caret + 1).join()),
                ],
              )
            : TextSpan(text: widget.text, style: widget.style);
        final TextDirection textDirection = Directionality.of(context);
        final TextScaler textScaler = MediaQuery.textScalerOf(context);
        final double maxWidth = constraints.maxWidth;

        SubtitleListCharHit? hitAt({
          required Offset localPosition,
          required Offset globalPosition,
        }) {
          // BUG-874：grapheme 偏移表用顶层纯 helper（与 barrier 反查
          // [subtitleListCharHitFromParagraph] 同源）。
          final List<int> starts = subtitleGraphemeStartOffsets(widget.text);
          final List<int> ends = subtitleGraphemeEndOffsets(widget.text);
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
            final int graphemeIndex = resolveSubtitleListGraphemeHit(
              rects,
              localPosition,
            );
            if (graphemeIndex < 0) return null;
            Rect localRect = rects[graphemeIndex];
            if (!localRect.contains(localPosition)) {
              // 字缝 / 行距兜底命中：扩盒含点，保证 charRect 始终含指针。
              localRect = localRect.expandToInclude(
                Rect.fromCenter(center: localPosition, width: 1, height: 1),
              );
            }
            final Offset globalOrigin = globalPosition - localPosition;
            // BUG-2367：浮层锚 = 被点字位→句末的字形盒并集（见
            // [subtitleListLookupAnchorRect]），跨行词的第二排不再被浮层压住。
            final Rect anchor = subtitleListLookupAnchorRect(
              rects,
              graphemeIndex,
            ).expandToInclude(localRect);
            return (
              graphemeIndex: graphemeIndex,
              charRect: localRect.shift(globalOrigin),
              anchorRect: anchor.shift(globalOrigin),
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
              widget.onLookup(hit.graphemeIndex, hit.anchorRect);
              return;
            }
            widget.onBackgroundTap?.call();
          },
          child: RichText(
            // BUG-872：稳定 key 让 [_hitTestRows] 能按 builder 下标取到本行 RenderParagraph
            // 反查字符命中（供查词浮层 dismiss barrier 切换查词 + 列表 Shift-悬停 / keydown）。
            key: widget.textKey,
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
}

/// Shared sidebar row spacing, current-line color and optional action columns.
class SubtitleTranscriptRow extends StatelessWidget {
  const SubtitleTranscriptRow({
    required this.colorScheme,
    required this.text,
    this.leading,
    this.trailing,
    this.selected = false,
    this.hovered = false,
    this.favorited = false,
    super.key,
  });

  final ColorScheme colorScheme;
  final Widget text;
  final Widget? leading;
  final Widget? trailing;
  final bool selected;
  final bool hovered;
  final bool favorited;

  @override
  Widget build(BuildContext context) {
    final Color background = selected
        ? colorScheme.primaryContainer
        : favorited
        ? colorScheme.tertiaryContainer.withValues(alpha: 0.32)
        : hovered
        ? colorScheme.onSurface.withValues(alpha: 0.06)
        : Colors.transparent;
    return Container(
      padding: EdgeInsets.only(
        left: favorited
            ? kSubtitleRowPaddingLeft - kSubtitleRowFavoriteBarWidth
            : kSubtitleRowPaddingLeft,
        right: kSubtitleRowPaddingRight + kSubtitleRowScrollbarGutter,
        top: kSubtitleRowPaddingVertical / 2,
        bottom: kSubtitleRowPaddingVertical / 2,
      ),
      decoration: BoxDecoration(
        color: background,
        border: favorited
            ? Border(
                left: BorderSide(
                  color: colorScheme.tertiary,
                  width: kSubtitleRowFavoriteBarWidth,
                ),
              )
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (leading != null) ...<Widget>[
            leading!,
            const SizedBox(width: kSubtitleRowTimestampGap),
          ],
          Expanded(child: text),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class SubtitleTranscriptAction extends StatelessWidget {
  const SubtitleTranscriptAction({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.size,
    required this.onPressed,
    super.key,
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

/// 判定一个**字位簇**（grapheme cluster）是否属于「拉丁单词字符」：拉丁字母
/// （含 café 的 é、连字号外的重音字母）或 ASCII 数字。用字位簇的首个码点的
/// Unicode `Script=Latin` 属性判定，故 NFC/NFD 的重音字母都按基字母（拉丁）归类。
/// CJK（汉字 / 假名 / 谚文）不是拉丁脚本，恒返回 false → 逐字查词行为不变。
bool _isLatinWordGrapheme(String grapheme) {
  if (grapheme.isEmpty) return false;
  return _kLatinWordCharRegExp.hasMatch(grapheme);
}

final RegExp _kLatinWordCharRegExp = RegExp(
  r'^[\p{Script=Latin}0-9]',
  unicode: true,
);

/// 点字幕第 [graphemeIndex] 个字位起的查询串。
///
/// 查询串只由**起点**决定，终点恒为句尾——引擎按查询串做最长匹配并回报
/// `bestLength`（弹窗 / 字幕据此高亮整词跨度），多喂的后文超出 `scanLength`
/// （`FushiDicts.defaultScanLength` = 16 码点）自然丢弃。
///
/// 起点按脚本分：
/// - CJK / 标点 / 空白：就是被点字位本身（逐字查词，点「永」命中「永遠」、
///   点「遠」能单独查「遠」）。
/// - 拉丁单词字符：回退到该单词的**词首**，这样点 "hello" 的任意字母（含
///   'e' / 'o'）都从 "hello" 起查，而不是旧 `skip(index)` 的 "ello" 查不到
///   （TODO-916 症状③）。空格 / 标点 / 连字号 / CJK 都是词首边界。
///
/// BUG-1773：拉丁分支此前**同时**把终点钉死在词尾，于是查询串被截成单个单词，
/// `listen to` / `look forward to` 这类空格分词短语的词条永远匹配不到——点空格
/// 反而能查出短语（走了 CJK 的「到句尾」分支）就是这个特例的照妖镜。终点从来
/// 不该由脚本决定：C++ `scan_candidates` 明确禁止在空格分词语言的单词中间切
/// （native/fushidicts/fushidicts_src/scan/word_scan.cpp），候选恒是
/// `listen to music` / `listen to` / `listen`，单词自己仍在候选里，不会被短语挤掉。
/// 网页播放器页（web_video_fushi_page.dart）与本页共用同一取词规则，故为公开顶层函数。
String subtitleTranscriptLookupTerm(String sentence, int graphemeIndex) =>
    subtitleTranscriptLookupSpan(sentence, graphemeIndex).term;

/// [subtitleTranscriptLookupTerm] 的结构化形态：查询串 + 它在句中的 grapheme **起点**。
///
/// 起点是字幕高亮（BUG-2091）的锚：拉丁词回退到词首后，高亮必须从词首起算而不是
/// 从被点字母起算，否则点 "hello" 的 'o' 只会亮出 "o"。越界返回 `(start: -1, term: '')`。
({int start, String term}) subtitleTranscriptLookupSpan(
  String sentence,
  int graphemeIndex,
) {
  final List<String> graphemes = sentence.characters.toList();
  if (graphemeIndex < 0 || graphemeIndex >= graphemes.length) {
    return (start: -1, term: '');
  }
  int start = graphemeIndex;
  // 拉丁单词字符：只把起点回退到词首。其余脚本起点即命中字位。
  if (_isLatinWordGrapheme(graphemes[graphemeIndex])) {
    while (start > 0 && _isLatinWordGrapheme(graphemes[start - 1])) {
      start--;
    }
  }
  // **起点必须跳过前导空白**：查询串在 `pushNestedPopup` 里先 `trim()` 再送引擎，
  // 而引擎回报的匹配长度（matchedRunes）是相对 **trim 后**那个串数的。起点若停在
  // 空白上，[lookupHighlightGraphemeCount] 就把这个长度套回带前导空白的串——高亮
  // 整体左移一格、尾部少一个字符。
  //
  // 点中空格是常态而非边角：英文字幕逐字命中、`hoverAutoLookup` 扫过词间空隙都会
  // 落在空格上（`_isLatinWordGrapheme(' ')` 为假，起点不回退）。日文同理，
  // `String.trim()` 连 U+3000 全角空格一起吃。
  //
  // 弹窗查的词一字不变（引擎拿到的本来就是 trim 后的串），变的只有高亮锚点。
  while (start < graphemes.length && graphemes[start].trim().isEmpty) {
    start++;
  }
  // 整段都是空白：没有可查的词。此前会带着一串空格去查（引擎 trim 成空、返回 0），
  // 副作用是白暂停一次视频、弹一个空浮层。
  if (start >= graphemes.length) return (start: -1, term: '');
  return (start: start, term: graphemes.skip(start).join());
}

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderStack;
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/misc/lookup_input_limits.dart';

/// 查词弹窗 headword 的字号，单位逻辑像素。
///
/// BUG-175 / TODO-222 要求源文本条与弹窗 headword **同级**；那个 headword 不是
/// Flutter 排版角色，而是 WebView 里 `assets/popup/popup.css` 的
/// `.expression { font-size: 26px }`。所以这个数字是**跨边界对齐常量**，不是本地
/// 重新拍板的 MD3 字号——守卫用 `md3_design_system_static_test.dart` 的
/// 「source lookup strip headword size stays pinned to the popup CSS」把它与
/// popup.css 钉在一起，改哪边都会红。
///
/// BUG-1425：这里曾写成 `pageTitle.apply(fontSizeFactor: 26 / pageTitle.fontSize)`
/// —— 读一个设计令牌只为把它整除掉。那个写法有两宗罪：① 文件里一个 `fontSize:`
/// 都不剩，MD3 守卫的子串判据天然扫不到，等于绕过门禁；② 谁把 `pageTitle` 调大，
/// 因子会自动补偿回 26，改动零反馈、静默失效。现在明写字号、明说它对齐谁。
const double kPopupHeadwordFontSize = 26.0;

/// 源文本条上「当前被查中的那个词」的跨度，单位是**字素簇**（与本条逐字渲染同
/// 坐标系，见 [SourceLookupTextPanel] 的 `chars`）。
///
/// 与 Yomitan 扫描高亮同义：查词是从被点的那个字**到串尾**的一段后缀，引擎再对它
/// 做最长匹配；这个跨度就是引擎真正吃下去的那几个字，让用户看得见「这次查的是
/// 『と言い』还是『言い』」。UTF-16 → 字素簇的换算由
/// [resolveSourceLookupHighlight] 负责，本类只承载换算结果。
@immutable
class SourceLookupHighlight {
  const SourceLookupHighlight({required this.start, required this.length});

  /// 首个被高亮的字素簇下标。
  final int start;

  /// 被高亮的字素簇个数（恒 >= 1；引擎零命中时退化成「只框住被点的那个字」）。
  final int length;

  @override
  bool operator ==(Object other) =>
      other is SourceLookupHighlight &&
      other.start == start &&
      other.length == length;

  @override
  int get hashCode => Object.hash(start, length);

  @override
  String toString() => 'SourceLookupHighlight(start: $start, length: $length)';
}

/// 把引擎回报的匹配长度换算成源文本条的字素簇跨度。
///
/// 三个坐标系必须对齐，少一个都会画歪：
///   1. [tappedGraphemeIndex] 是**本条渲染的字素簇**下标（用户点的那个字）；
///   2. [matchedUnits]（`lookupHighlightCharCount` / `bestLength`）是 **UTF-16 code
///      unit** 数，且以 `normalizeSearchTerm` **剥掉句首标点之后**的串为坐标系；
///   3. [leadingStripUnits]（`AppModel.lookupLeadingStripUnits`）就是那段被剥掉的
///      句首长度——不右移它，高亮会左吞进句首括号、右缺词尾（BUG-773 同一个坑）。
///
/// 逐字素簇累加 UTF-16 长度来定位，而不是 `substring(strip, strip + matched)` 再数
/// 字素簇：匹配长度落在代理对 / 组合字中间时 `substring` 会劈出孤立代理项，数出来的
/// 长度不是用户看到的字数。这里改成「取足以覆盖该 code unit 区间的最少字素簇」，
/// 宁可整字多框一个，也绝不把一个字劈成两半。
///
/// [matchedUnits] <= 0（无词条）时退化成只框被点的那个字：查不到东西也得让用户看见
/// 自己点在哪，而不是整条没有任何反馈。
SourceLookupHighlight resolveSourceLookupHighlight({
  required String query,
  required int tappedGraphemeIndex,
  required int matchedUnits,
  required int leadingStripUnits,
}) {
  final int base = tappedGraphemeIndex < 0 ? 0 : tappedGraphemeIndex;
  if (query.isEmpty) {
    return SourceLookupHighlight(start: base, length: 1);
  }
  final int strip = leadingStripUnits < 0 ? 0 : leadingStripUnits;
  final int endUnits = strip + (matchedUnits > 0 ? matchedUnits : 1);

  int consumedUnits = 0;
  int consumedGraphemes = 0;
  int? startGrapheme;
  for (final String grapheme in query.characters) {
    if (startGrapheme == null && consumedUnits >= strip) {
      startGrapheme = consumedGraphemes;
    }
    if (startGrapheme != null && consumedUnits >= endUnits) break;
    consumedUnits += grapheme.length;
    consumedGraphemes += 1;
  }
  // strip 覆盖整串（整段都是标点）时循环走完仍未定起点，退化到串尾。
  startGrapheme ??= consumedGraphemes;
  final int length = consumedGraphemes - startGrapheme;
  return SourceLookupHighlight(
    start: base + startGrapheme,
    length: length < 1 ? 1 : length,
  );
}

class SourceLookupTextPanel extends StatefulWidget {
  const SourceLookupTextPanel({
    required this.text,
    required this.onLookup,
    super.key,
    this.coordinateSpaceKey,
    this.dictionaryHeadwordScale = 1.0,
    this.globalCoordinates = false,
    this.highlight,
  });

  final String text;

  /// 点中（或 Shift 悬停）某个字：回报「从该字到串尾」的查询串、该字的矩形，以及
  /// 该字在本条渲染序列里的**字素簇下标**。
  ///
  /// 下标是宿主定位命中高亮的锚（[resolveSourceLookupHighlight] 的
  /// `tappedGraphemeIndex`）。它由本条显式回报而不是让宿主拿 query 长度反推：反推
  /// 依赖「query 恒为 text 的后缀」这条本条内部约定（还叠着 [kMaxLookupInputChars]
  /// 截断），约定一改宿主就静默画歪；而且异步查词回来时用户可能已经点了别的字，
  /// 宿主必须能把回报的长度绑回**发起那一次**的下标，不能读本条的当前态。
  final void Function(String query, Rect localRect, int charIndex) onLookup;
  final GlobalKey? coordinateSpaceKey;
  final double dictionaryHeadwordScale;

  /// 当前被查中的那个词在本条上的跨度（Yomitan 式扫描高亮）；null 时不画框。
  ///
  /// 由宿主持有而非本条自持：跨度长度要等引擎回报匹配长度才知道，是一次**异步**
  /// 结果；本条只知道用户点了哪个字。宿主把「哪次点击 → 哪个长度」配对好再传下来，
  /// 迟到的结果就不会盖到用户后来点的那个字上。
  final SourceLookupHighlight? highlight;

  /// TODO-617: [onLookup] reports the tapped char rect in **screen (global)**
  /// coordinates instead of [coordinateSpaceKey]-local. The home dictionary tab
  /// lifts its popup stack into the root Overlay (full window, net scale = 1), so
  /// the source-text panel must feed selection rects in that same screen space or
  /// the popup is offset by the result sub-area origin. Defaults to false to keep
  /// the old panel-local semantics (the Android standalone lookup window
  /// popup_dictionary_page keeps positioning via coordinateSpaceKey, unchanged).
  final bool globalCoordinates;

  @override
  State<SourceLookupTextPanel> createState() => _SourceLookupTextPanelState();
}

class _SourceLookupTextPanelState extends State<SourceLookupTextPanel> {
  int? _lastShiftHoverIndex;

  @override
  Widget build(BuildContext context) {
    final String trimmed = widget.text.trim();
    if (trimmed.isEmpty) return const SizedBox.shrink();

    final ThemeData theme = Theme.of(context);
    // BUG-442：逐字符建一个可点 widget 塞进 Wrap，节点数 = 码点数。超长剪贴板
    // 文本（成千上万码点）会在构建期产出巨量 widget → 主 isolate OOM / 引擎崩溃。
    // 硬兜底：只渲染前 kMaxLookupInputChars 个可点字符（上游通常已截断，这里是
    // 即便上游漏截断也永不爆的最后防线）。截断后的文本同时作为 _lookupAt 的后缀真值。
    final List<String> allChars = trimmed.characters.toList(growable: false);
    final List<String> chars = allChars.length > kMaxLookupInputChars
        ? allChars.sublist(0, kMaxLookupInputChars)
        : allChars;
    // 每个字符是独立可点 span，逐字保持原有点击/Shift 悬停查词行为。
    final TextStyle charStyle = _dictionaryHeadwordTextStyle(context).copyWith(
      color: theme.colorScheme.onSurface,
      height: 1.5,
    );
    // 命中高亮底色与弹窗 WebView 内的 `--fushi-primary-highlight` 同一口径
    // （`popup_theme_css.dart` 的 `cssRgba035(scheme.primary)`）。源文本条与弹窗
    // 卡片是同一次查词的两个可见面，底色不同会让用户以为是两种不同的标记。
    final Color highlightColor =
        theme.colorScheme.primary.withValues(alpha: 0.35);
    final Radius highlightCorner =
        FushiDesignTokens.of(context).radii.chipCorner;
    // 逐字给底框而不是一个整块 Rect：本条是 Wrap，命中段跨行时整块 Rect 画不出来，
    // 逐字底框天然在换行处断开、各行各自贴合。spacing:0 使同一行内的相邻底框严丝
    // 合缝，视觉上仍是一个连续的框。
    final SourceLookupHighlight? highlight = widget.highlight;
    final int highlightStart = highlight?.start ?? -1;
    final int highlightEnd =
        highlight == null ? -1 : highlight.start + highlight.length;
    // 左对齐并占满可用宽度：剪贴板文本条挂在 home_dictionary_page 的 Column 下，
    // Column 默认 crossAxisAlignment.center 会把收缩到内容宽度的本条居中。
    // Align(topLeft) 在父级宽度有界时撑满该宽度并把内容钉左上角，宽度无界时
    // （如直接放进只给 left/top 的 Positioned）安全回退到内容宽度，不强行要求
    // 无限宽度。对齐由本组件决定，不依赖父级的 crossAxisAlignment。
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Wrap(
          alignment: WrapAlignment.start,
          spacing: 0,
          runSpacing: 2,
          children: <Widget>[
            for (int i = 0; i < chars.length; i++)
              Builder(
                builder: (BuildContext charContext) {
                  final bool lit = i >= highlightStart && i < highlightEnd;
                  final Widget glyph = Text(chars[i], style: charStyle);
                  return MouseRegion(
                    cursor: SystemMouseCursors.click,
                    onHover: (_) => _handleShiftHover(
                      i,
                      context,
                      charContext,
                    ),
                    onExit: (_) {
                      if (_lastShiftHoverIndex == i) {
                        _lastShiftHoverIndex = null;
                      }
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _lookupAt(i, context, charContext),
                      child: lit
                          ? DecoratedBox(
                              decoration: BoxDecoration(
                                color: highlightColor,
                                // 只有命中段的两端收圆角，中间各字保持直角，拼起来
                                // 才是一个整词框而不是一串独立药丸。
                                borderRadius: BorderRadius.horizontal(
                                  left: i == highlightStart
                                      ? highlightCorner
                                      : Radius.zero,
                                  right: i == highlightEnd - 1
                                      ? highlightCorner
                                      : Radius.zero,
                                ),
                              ),
                              child: glyph,
                            )
                          : glyph,
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 字体族 / 字重 / 颜色仍取 MD3 的 [FushiTypeRoles.pageTitle] 标题角色；
  /// 只有**字号**按 [kPopupHeadwordFontSize] 与弹窗 headword 对齐，再乘用户的
  /// 词典字号比例。
  TextStyle _dictionaryHeadwordTextStyle(BuildContext context) {
    final TextStyle base = FushiDesignTokens.of(context).type.pageTitle;
    final double requestedScale = widget.dictionaryHeadwordScale;
    final double safeScale =
        requestedScale.isFinite && requestedScale > 0 ? requestedScale : 1.0;
    return base.copyWith(fontSize: kPopupHeadwordFontSize * safeScale);
  }

  void _handleShiftHover(
    int index,
    BuildContext panelContext,
    BuildContext charContext,
  ) {
    if (!HardwareKeyboard.instance.isShiftPressed) {
      _lastShiftHoverIndex = null;
      return;
    }
    if (_lastShiftHoverIndex == index) return;
    _lastShiftHoverIndex = index;
    _lookupAt(index, panelContext, charContext);
  }

  void _lookupAt(
    int index,
    BuildContext panelContext,
    BuildContext charContext,
  ) {
    final String trimmed = widget.text.trim();
    // BUG-442：与 build 同一上限——查词后缀从截断后的字符序列取，避免对超长串
    // 重新展开整个 characters（也与渲染出来的可点字符一一对应）。
    final Iterable<String> capped =
        trimmed.characters.take(kMaxLookupInputChars);
    widget.onLookup(
      capped.skip(index).join(),
      _localRectOf(panelContext, charContext),
      index,
    );
  }

  Rect _localRectOf(BuildContext panelContext, BuildContext charContext) {
    final RenderObject? child = charContext.findRenderObject();
    if (child is! RenderBox || !child.hasSize) return Rect.zero;
    // TODO-617：globalCoordinates 时回报**屏幕（global）坐标**——两角各过 localToGlobal
    // （位置与尺寸同被祖先变换缩放，等同 focus_geometry.globalRectOfBox），供首页根 Overlay
    // 弹窗按真实屏幕空间定位。两角法而非 `localToGlobal(zero) & size`：缩放下后者把缩放后的
    // 位置配未缩放局部尺寸会错。
    if (widget.globalCoordinates) {
      return Rect.fromPoints(
        child.localToGlobal(Offset.zero),
        child.localToGlobal(child.size.bottomRight(Offset.zero)),
      );
    }
    final RenderObject? panel =
        widget.coordinateSpaceKey?.currentContext?.findRenderObject() ??
            charContext.findAncestorRenderObjectOfType<RenderStack>() ??
            panelContext.findRenderObject();
    if (panel is! RenderBox) return Rect.zero;
    final Offset global = child.localToGlobal(Offset.zero);
    return panel.globalToLocal(global) & child.size;
  }
}

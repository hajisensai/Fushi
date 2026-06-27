import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderStack;
import 'package:flutter/services.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/misc/lookup_input_limits.dart';

const double _dictionaryHeadwordBaseFontSize = 26.0;

class SourceLookupTextPanel extends StatefulWidget {
  const SourceLookupTextPanel({
    required this.text,
    required this.onLookup,
    super.key,
    this.coordinateSpaceKey,
    this.dictionaryHeadwordScale = 1.0,
    this.globalCoordinates = false,
  });

  final String text;
  final void Function(String query, Rect localRect) onLookup;
  final GlobalKey? coordinateSpaceKey;
  final double dictionaryHeadwordScale;

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

class ClipboardLookupTextPanel extends SourceLookupTextPanel {
  const ClipboardLookupTextPanel({
    required super.text,
    required super.onLookup,
    super.key,
    super.coordinateSpaceKey,
    super.dictionaryHeadwordScale,
  });
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
                      child: Text(chars[i], style: charStyle),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  TextStyle _dictionaryHeadwordTextStyle(BuildContext context) {
    final TextStyle base = HibikiDesignTokens.of(context).type.pageTitle;
    final double baseSize = base.fontSize ?? _dictionaryHeadwordBaseFontSize;
    final double safeBaseSize = baseSize.isFinite && baseSize > 0
        ? baseSize
        : _dictionaryHeadwordBaseFontSize;
    final double requestedScale = widget.dictionaryHeadwordScale;
    final double safeScale =
        requestedScale.isFinite && requestedScale > 0 ? requestedScale : 1.0;
    return base.apply(
      fontSizeFactor:
          (_dictionaryHeadwordBaseFontSize / safeBaseSize) * safeScale,
    );
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

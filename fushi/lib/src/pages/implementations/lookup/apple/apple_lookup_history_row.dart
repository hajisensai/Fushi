import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/lookup_history_row.dart';
import 'package:fushi/src/utils/components/fushi_apple_glyph_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show showFushiMenu;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 查词历史 Apple 行（iOS 27「词典」/ 聚焦搜索结果、macOS 27 侧栏搜索结果列表口径）。
///
/// 放在 inset grouped 分组里的一格（[FushiGroupedListItem]，与上方「最近搜索」同一
/// 种外壳：行间 separator 细线左端对齐文字、悬停 tertiaryFill / 按下 fill 的 Apple
/// 行高亮、键盘焦点环 + Enter 打开）。行内：
/// - 不画颜色标签（用户 2026-11-24「那个颜色去掉」）：M3E 色条行照旧用
///   [LookupHistoryRowData.hue]，Apple 行只留文字；
/// - 标题 label 色正文字号、最多两行省略；副标题 secondaryLabel 一行；
/// - 行尾命中词典数是 secondaryLabel 的「字形 + 数字」纯文字，不铺 tonal 胶囊；
/// - 行尾「⋯」是裸字形按钮（悬停 / 焦点时露出，触屏长按、桌面右键同样弹这张
///   Apple 菜单），菜单里是全部动作（收藏 / 移出历史）。
///
/// 选中（宽屏右栏正显示这条）铺不透明 fill 底，不画 M3E 的描边。
class AppleLookupHistoryRow extends StatefulWidget {
  const AppleLookupHistoryRow({
    required this.data,
    required this.index,
    required this.count,
    required this.margin,
    super.key,
  });

  final LookupHistoryRowData data;

  /// 本行在分组里的位置与分组总行数（圆角 / 分隔线）。
  final int index;
  final int count;

  /// 分组外边距（左右页边距）。
  final EdgeInsetsGeometry margin;

  /// 分隔线左端：行内边距，对齐文字左缘。
  static double separatorIndent(BuildContext context) =>
      FushiAppleMetrics.of(context).rowHorizontal;

  @override
  State<AppleLookupHistoryRow> createState() => _AppleLookupHistoryRowState();
}

enum _HistoryAction { favorite, remove }

class _AppleLookupHistoryRowState extends State<AppleLookupHistoryRow> {
  bool _hovered = false;
  bool _focused = false;
  Offset? _lastPointer;

  /// 菜单开着时「⋯」保持露出（菜单关掉前不能因悬停离开而淡掉）。
  bool _menuOpen = false;

  Future<void> _openMenu(BuildContext anchorContext, {Offset? at}) async {
    final RenderObject? box = anchorContext.findRenderObject();
    final RenderObject? overlayBox = Navigator.of(
      anchorContext,
    ).overlay?.context.findRenderObject();
    if (box is! RenderBox || overlayBox is! RenderBox) return;
    final Rect anchor = at != null
        ? Rect.fromLTWH(
            overlayBox.globalToLocal(at).dx,
            overlayBox.globalToLocal(at).dy,
            0,
            0,
          )
        : Rect.fromPoints(
            box.localToGlobal(Offset.zero, ancestor: overlayBox),
            box.localToGlobal(
              box.size.bottomRight(Offset.zero),
              ancestor: overlayBox,
            ),
          );
    final FushiAppleColors apple = appleColorsOf(anchorContext);
    setState(() => _menuOpen = true);
    final _HistoryAction? picked = await showFushiMenu<_HistoryAction>(
      context: anchorContext,
      position: RelativeRect.fromRect(anchor, Offset.zero & overlayBox.size),
      items: <PopupMenuEntry<_HistoryAction>>[
        FushiPopupMenuItem<_HistoryAction>(
          key: const ValueKey<String>('lookup_history_apple_menu_favorite'),
          value: _HistoryAction.favorite,
          label: t.lookup_history_favorite,
          icon: FushiIcons.star,
        ),
        FushiPopupMenuItem<_HistoryAction>(
          key: const ValueKey<String>('lookup_history_apple_menu_remove'),
          value: _HistoryAction.remove,
          label: t.lookup_history_remove,
          icon: FushiIcons.delete,
          color: apple.destructive,
        ),
      ],
    );
    if (!mounted) return;
    setState(() => _menuOpen = false);
    switch (picked) {
      case _HistoryAction.favorite:
        widget.data.onFavorite();
      case _HistoryAction.remove:
        widget.data.onRemove();
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final LookupHistoryRowData data = widget.data;
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final TextStyle titleStyle = metrics.titleStyle(context);
    final TextStyle subtitleStyle = metrics.subtitleStyle(context);
    final String? subtitle = data.subtitle('・');
    final bool reveal = _hovered || _focused || _menuOpen;
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);

    final Widget count = Semantics(
      label: t.lookup_history_dictionary_count(count: data.dictionaryCount),
      excludeSemantics: true,
      child: Row(
        key: const ValueKey<String>('lookup_history_apple_count'),
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(
            FushiIcons.dictionary,
            size: subtitleStyle.fontSize,
            color: apple.secondaryLabel,
          ),
          const SizedBox(width: 3),
          Text(
            '${data.dictionaryCount}',
            style: subtitleStyle.copyWith(
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );

    // 「⋯」始终挂在树里、可 Tab 到（焦点进来即显形），只按悬停 / 焦点换透明度。
    final Widget more = Builder(
      builder: (BuildContext anchorContext) => AnimatedOpacity(
        duration: duration,
        curve: FushiMotion.standard,
        opacity: reveal ? 1 : 0,
        child: FushiAppleGlyphButton(
          key: const ValueKey<String>('lookup_history_apple_more'),
          icon: FushiIcons.moreHoriz,
          tooltip: t.lookup_history_more,
          onPressed: () => _openMenu(anchorContext),
        ),
      ),
    );

    final Widget content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: metrics.rowMinHeight),
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          start: metrics.rowHorizontal,
          end: metrics.rowHorizontal / 2,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: metrics.rowVertical),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      data.term,
                      key: const ValueKey<String>('lookup_history_row_term'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        key: const ValueKey<String>(
                          'lookup_history_row_subtitle',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: subtitleStyle,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            count,
            more,
          ],
        ),
      ),
    );

    return Builder(
      builder: (BuildContext rowContext) => Listener(
        onPointerDown: (PointerDownEvent e) => _lastPointer = e.position,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (bool focused) {
              if (focused != _focused) setState(() => _focused = focused);
            },
            child: Semantics(
              selected: data.selected,
              child: FushiGroupedListItem(
                index: widget.index,
                count: widget.count,
                margin: widget.margin,
                separatorIndent: AppleLookupHistoryRow.separatorIndent(context),
                // 选中 = 不透明 fill 底（iOS 列表选中灰），不走 FushiCard 的描边。
                color: data.selected
                    ? Color.alphaBlend(
                        apple.fill,
                        apple.secondaryGroupedBackground,
                      )
                    : null,
                onTap: data.onOpen,
                onLongPress: () => _openMenu(rowContext, at: _lastPointer),
                onSecondaryTap: () => _openMenu(rowContext, at: _lastPointer),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockColors;
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_poster_block.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 一条查词历史行要显示的内容与动作（业务只在查词页算一次，M3E 色条行
/// [LookupHistoryCollageRow]、M3E 分段行与 Apple 行
/// `AppleLookupHistoryRow` 都只消费它）。
@immutable
class LookupHistoryRowData {
  const LookupHistoryRowData({
    required this.term,
    required this.subtitleParts,
    required this.dictionaryCount,
    required this.selected,
    required this.onOpen,
    required this.onFavorite,
    required this.onRemove,
  });

  /// 查过的词（换行已压成空格）。
  final String term;

  /// 历史结果首条的写法 / 读音（与 [term] 不同才有）；空 = 不画第二行。
  final List<String> subtitleParts;

  /// 这条结果命中的词典数。
  final int dictionaryCount;

  /// 是否是宽屏右栏当前显示的那条。
  final bool selected;

  /// 回看这条（把词填回搜索框并显示缓存结果）。
  final VoidCallback onOpen;
  final VoidCallback onFavorite;
  final VoidCallback onRemove;

  /// 第二行文字：[subtitleParts] 用 [separator] 连起来；没有则 null。
  String? subtitle(String separator) =>
      subtitleParts.isEmpty ? null : subtitleParts.join(separator);

  /// 颜色标签的色相：与 M3E 色条 / 拼贴色块同一套 [fushiPosterHue]，两套设计
  /// 系统下同一个词是同一种颜色。
  double get hue => fushiPosterHue(term);
}

/// 色条尺寸（设计稿查词页 `.hrow .dot`：8×28、圆角 4）。
const double _kStripWidth = 8;
const double _kStripHeight = 28;

/// M3E 重设计外壳（墨水屏除外）的查词历史行（设计稿 #lookup L1）。Apple 设计系统
/// 不用它，走 `AppleLookupHistoryRow`（查词页在根上按设计系统分派）。
///
/// 旧版窄栏里放 2 列大色块，词形被截成「やめ…」，读音大字水印压在底边，信息
/// 几乎读不出来。改成列表行：
/// - 左侧一根按词取色的色条（与拼贴色块同一套 [fushiPosterColors]），无水印；
/// - 正文是**完整**词形（不设 maxLines、不省略，长词自动换行），下面一行是历史
///   结果里本来就存的写法 / 读音（[subtitle]，来自词典结果，不做任何推断注音）；
/// - 行尾是命中词典数胶囊；悬停 / 聚焦时露出「⋯」（收藏 / 移出历史）。
///
/// 点按 = 回看这条（[onOpen]），当前右栏那条标为选中；悬停 [FushiHoverLift]、
/// 按压 [FushiPressScale]，时长只取 [FushiMotion]。
class LookupHistoryCollageRow extends StatefulWidget {
  const LookupHistoryCollageRow({
    required this.term,
    required this.subtitle,
    required this.dictionaryCount,
    required this.selected,
    required this.onOpen,
    required this.onFavorite,
    required this.onRemove,
    super.key,
  });

  /// 查过的词（完整显示）。
  final String term;

  /// 历史结果首条的写法 / 读音（与 [term] 不同时才有）；null = 不画第二行。
  final String? subtitle;

  /// 这条结果命中的词典数。
  final int dictionaryCount;

  /// 是否是宽屏右栏当前显示的那条。
  final bool selected;

  final VoidCallback onOpen;
  final VoidCallback onFavorite;
  final VoidCallback onRemove;

  @override
  State<LookupHistoryCollageRow> createState() =>
      _LookupHistoryCollageRowState();
}

class _LookupHistoryCollageRowState extends State<LookupHistoryCollageRow> {
  bool _focused = false;
  bool _menuFocused = false;

  void _setFocused(bool focused) {
    if (focused != _focused) setState(() => _focused = focused);
  }

  void _setMenuFocused(bool focused) {
    if (focused != _menuFocused) setState(() => _menuFocused = focused);
  }

  @override
  Widget build(BuildContext context) {
    return FushiHoverLift(
      scale: kFushiWideCardHoverLiftScale,
      builder: (BuildContext context, bool hovering) =>
          _buildRow(context, hovering),
    );
  }

  Widget _buildRow(BuildContext context, bool hovering) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final TextTheme tt = theme.textTheme;
    final bool dark = theme.brightness == Brightness.dark;
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    final FushiCoverBlockColors strip = fushiPosterColors(
      context,
      fushiPosterHue(widget.term),
    );
    final BorderRadius radius = BorderRadius.circular(12);
    final bool reveal = hovering || _focused || _menuFocused;

    final Color background = widget.selected
        ? cs.secondaryContainer
        : hovering
        ? cs.surfaceContainerHigh
        : Colors.transparent;
    final Color termColor = widget.selected
        ? cs.onSecondaryContainer
        : cs.onSurface;
    final Color metaColor = widget.selected
        ? cs.onSecondaryContainer.withValues(alpha: 0.8)
        : cs.onSurfaceVariant;

    final String? subtitle = widget.subtitle;
    final Widget content = Row(
      children: <Widget>[
        // 浅色主题取色块底色（粉彩），深色取强调色（深底上的亮粉彩）：两套主题
        // 下色条都与拼贴色块同调且在页面底上看得见。
        DecoratedBox(
          decoration: BoxDecoration(
            color: dark ? strip.accent : strip.container,
            borderRadius: BorderRadius.circular(_kStripWidth / 2),
          ),
          child: const SizedBox(width: _kStripWidth, height: _kStripHeight),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                widget.term,
                key: const ValueKey<String>('lookup_history_row_term'),
                softWrap: true,
                style: tt.titleMedium?.copyWith(
                  color: termColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle,
                    key: const ValueKey<String>('lookup_history_row_subtitle'),
                    softWrap: true,
                    style: tt.bodySmall?.copyWith(color: metaColor),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _buildCountPill(context, cs, tt),
        _buildMenu(duration, reveal),
      ],
    );

    return Semantics(
      selected: widget.selected,
      button: true,
      child: FushiPressScale(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onOpen,
            onFocusChange: _setFocused,
            borderRadius: radius,
            // 悬停 / 选中底色由下面的 AnimatedContainer 画，水波只留给按下态。
            overlayColor: WidgetStateProperty.resolveWith<Color?>((
              Set<WidgetState> states,
            ) {
              if (states.contains(WidgetState.pressed)) {
                return cs.onSurface.withValues(alpha: 0.1);
              }
              return Colors.transparent;
            }),
            child: AnimatedContainer(
              duration: duration,
              curve: FushiMotion.standard,
              padding: const EdgeInsetsDirectional.fromSTEB(10, 7, 2, 7),
              decoration: BoxDecoration(
                color: background,
                borderRadius: radius,
              ),
              foregroundDecoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(
                  color: _focused ? cs.primary : Colors.transparent,
                  width: 2,
                ),
              ),
              child: content,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCountPill(BuildContext context, ColorScheme cs, TextTheme tt) {
    final Color fill = widget.selected ? cs.surface : cs.surfaceContainerHigh;
    final Color fg = cs.onSurfaceVariant;
    // 读屏只念一个光秃秃的数字听不出含义：整枚胶囊换成一句「命中 N 本词典」。
    return Semantics(
      label: t.lookup_history_dictionary_count(count: widget.dictionaryCount),
      excludeSemantics: true,
      child: Container(
        key: const ValueKey<String>('lookup_history_row_count'),
        height: 20,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        decoration: ShapeDecoration(shape: const StadiumBorder(), color: fill),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiIcon(FushiIcons.dictionary, size: 12, color: fg),
            const SizedBox(width: 3),
            Text(
              '${widget.dictionaryCount}',
              style: tt.labelSmall?.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「⋯」始终挂在树里（菜单打开期间按钮不能被卸载，否则选中项会被
  /// PopupMenuButton 因 !mounted 丢弃），只按悬停 / 焦点换透明度；藏起来时仍可
  /// Tab 到，焦点进来即显形。
  Widget _buildMenu(Duration duration, bool reveal) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _setMenuFocused,
      child: AnimatedOpacity(
        duration: duration,
        curve: FushiMotion.standard,
        opacity: reveal ? 1 : 0,
        child: FushiOverflowMenu<String>(
          tooltip: t.lookup_history_more,
          icon: FushiIcons.moreHoriz,
          iconSize: 20,
          items: <PopupMenuEntry<String>>[
            PopupMenuItem<String>(
              value: 'favorite',
              child: Text(t.lookup_history_favorite),
            ),
            PopupMenuItem<String>(
              value: 'remove',
              child: Text(t.lookup_history_remove),
            ),
          ],
          onSelected: (String value) {
            if (value == 'favorite') {
              widget.onFavorite();
            } else if (value == 'remove') {
              widget.onRemove();
            }
          },
        ),
      ),
    );
  }
}

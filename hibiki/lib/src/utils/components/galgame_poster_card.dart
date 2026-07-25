import 'package:flutter/material.dart';

import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

/// galgame 竖版海报卡（对齐 ReinaManager 库页/首页的卡片观感，见
/// `docs/design/galgame-library-reina-visual-parity.md` §1）。
///
/// 共享设计系统组件：封面 3:4、圆角 [HibikiBorderRadius.poster]、hover 放大 1.05 +
/// 阴影加深、选中 2px 主色环、封面底部可选「排序信息」渐变浮层、封面下方居中单行标题。
///
/// 刻意**不做文件 IO**：[cover] 由调用方传入（`Image.file` / 占位图 / 网络图都行），
/// 这样卡片本身是纯 widget、可 widget-test，也不与封面来源耦合。
///
/// 圆角走 token、字号走 textTheme、颜色走 colorScheme 语义角色，是设计系统组件而非页面
/// chrome，故在 MD3 静态守卫的 allowlist 内（同 `hibiki_material_components.dart`）。
class GalgamePosterCard extends StatefulWidget {
  const GalgamePosterCard({
    super.key,
    required this.cover,
    required this.title,
    this.overlayText,
    this.selected = false,
    this.multiSelected = false,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.trailing,
    this.semanticLabel,
    this.focusId,
  });

  /// 封面 widget（3:4 会被外层裁剪；建议 `fit: BoxFit.cover`）。
  final Widget cover;

  /// 标题（封面下方居中，单行省略）。
  final String title;

  /// 封面底部「排序信息」浮层文本；null / 空则不显示浮层。
  final String? overlayText;

  /// 选中态（当前详情/焦点）：加 2px 主色环。
  final bool selected;

  /// 批量多选态：左上角方形勾标（预留，M1.5 暂不启用多选）。
  final bool multiSelected;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 右键（桌面）→ 一般用于打开详情菜单。
  final VoidCallback? onSecondaryTap;

  /// 右上角悬浮控件（如更多菜单按钮）。
  final Widget? trailing;

  final String? semanticLabel;

  /// 焦点站点 id（手柄/键盘导航）。传入时注册到 [HibikiFocusRoot]，`Enter`/A 键
  /// 触发 [onTap]。库页靠它保持 `game-card-<id>` 焦点站点可被 requestById 聚焦。
  final HibikiFocusId? focusId;

  @override
  State<GalgamePosterCard> createState() => _GalgamePosterCardState();
}

class _GalgamePosterCardState extends State<GalgamePosterCard> {
  bool _hovering = false;

  void _setHover(bool value) {
    if (_hovering != value) {
      setState(() => _hovering = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    final Widget cover = _buildCover(context, colors);

    final Widget titleText = Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 2),
      child: Text(
        widget.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: widget.selected ? colors.primary : colors.onSurface,
        ),
      ),
    );

    final Widget card = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Flexible(child: cover),
        titleText,
      ],
    );

    // hover 放大 + 阴影：AnimatedScale 做缩放，AnimatedContainer 做阴影过渡。
    final Widget interactive = MouseRegion(
      onEnter: (_) => _setHover(true),
      onExit: (_) => _setHover(false),
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onSecondaryTap: widget.onSecondaryTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: _hovering ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: card,
        ),
      ),
    );

    final Widget semantic = Semantics(
      label: widget.semanticLabel ?? widget.title,
      button: widget.onTap != null,
      selected: widget.selected,
      child: interactive,
    );

    // 焦点注册：与 HibikiCard 同款——有 onTap 且存在焦点根时，注册焦点站点并把
    // ActivateIntent（Enter / 手柄 A）接到 onTap。无焦点根（纯 widget-test）直接返回。
    if (widget.onTap == null ||
        HibikiFocusRoot.maybeControllerOf(context) == null) {
      return semantic;
    }
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: HibikiFocusTarget(
        id: widget.focusId ?? _fallbackFocusId,
        child: semantic,
      ),
    );
  }

  late final HibikiFocusId _fallbackFocusId =
      HibikiFocusId('galgame-poster-${identityHashCode(this)}');

  Widget _buildCover(BuildContext context, ColorScheme colors) {
    const BorderRadius radius = HibikiBorderRadius.poster;
    final bool elevated = _hovering || widget.selected;

    return AspectRatio(
      aspectRatio: 3 / 4,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: radius,
          border: widget.selected
              ? Border.all(color: colors.primary, width: 2)
              : null,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: colors.shadow.withValues(alpha: elevated ? 0.28 : 0.12),
              blurRadius: elevated ? 16 : 6,
              offset: Offset(0, elevated ? 8 : 3),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              widget.cover,
              if (widget.overlayText != null &&
                  widget.overlayText!.isNotEmpty)
                _buildSortOverlay(context),
              if (widget.multiSelected) _buildSelectBadge(colors),
              if (widget.trailing != null)
                Positioned(top: 4, right: 4, child: widget.trailing!),
            ],
          ),
        ),
      ),
    );
  }

  /// 封面底部的排序信息渐变浮层：白字、单行、左对齐，底部深色渐变蒙版托底。
  Widget _buildSortOverlay(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 24, 10, 6),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Color(0x00000000),
                Color(0x4D0F1720),
                Color(0xD90F1720),
              ],
              stops: <double>[0.0, 0.5, 1.0],
            ),
          ),
          child: Text(
            widget.overlayText!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.left,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  shadows: const <Shadow>[
                    Shadow(color: Color(0x99000000), blurRadius: 2),
                  ],
                ),
          ),
        ),
      ),
    );
  }

  /// 左上角方形多选勾标（20×20，主色底 + 勾）。
  Widget _buildSelectBadge(ColorScheme colors) {
    return Positioned(
      top: 6,
      left: 6,
      child: Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: colors.primary,
          borderRadius: HibikiBorderRadius.chip,
        ),
        child: Icon(Icons.check, size: 14, color: colors.onPrimary),
      ),
    );
  }
}

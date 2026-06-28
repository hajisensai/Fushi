import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

/// 单个键帽（TODO-612 阶段 1；TODO-942 立体键帽换皮）。
///
/// 纯展示 + 点击入口：渲染键面 label、按 [bound] 高亮（已绑键位 = primary 容器色），
/// [onTap] 非空时整键可点（InkWell）。`Key('keycap_<keyId>')` 由 [KeyboardLayoutView]
/// 注入，供 widget 行为测试 tap 定位。本 widget 不持有任何绑定状态，高亮与否完全由
/// 上层 [ReverseBindingIndex] 决定后传入。
///
/// 立体观感（TODO-942）：双层结构——底层「键帽侧壁」用更深的容器色 + 底部偏移，顶层
/// 「键面」上移露出侧壁台阶，顶面顶部一条淡高光。所有颜色/圆角/字号走 MD3 token
/// （`HibikiDesignTokens` + `colorScheme` 派生），不含任何裸圆角/裸字号/裸容器层级
/// 字面量（过 md3 静态守卫）。
class KeyCapWidget extends StatelessWidget {
  const KeyCapWidget({
    super.key,
    required this.logicalKey,
    required this.label,
    required this.bound,
    this.onTap,
    this.isModifier = false,
    this.width,
    this.height = 44,
  });

  /// 本键帽代表的逻辑键（用于上层判定高亮 / 路由点击；本 widget 不直接读绑定）。
  final LogicalKeyboardKey logicalKey;

  /// 键面显示文本（如 'A'、'Esc'、'Ctrl'）。
  final String label;

  /// 是否已绑（已绑高亮）。
  final bool bound;

  /// 点击回调；null 表示该键不可改（图上只读展示，改绑走列表 dialog 兜底）。
  final VoidCallback? onTap;

  /// 是否为修饰键（Ctrl/Shift/Alt/Win）：用 secondaryContainer 分区色区分，恒只读。
  final bool isModifier;

  /// 键帽宽度；null 时由父布局约束（如 Wrap 内按内容自适应）。
  final double? width;

  /// 键帽整体高度（含立体台阶）。
  final double height;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final BorderRadius radius = tokens.radii.chipRadius;
    final ColorScheme scheme = theme.colorScheme;

    // 立体台阶高度（侧壁露出量）。键面相对侧壁上移 stepHeight。
    const double stepHeight = 3;

    // 三态配色，全走 scheme 派生：
    // - bound：primaryContainer 顶面 / primary 侧壁 / onPrimaryContainer 字。
    // - modifier：secondaryContainer 顶面 / 更深侧壁分区。
    // - normal(unbound)：card 顶面 / group 侧壁。
    final Color faceColor;
    final Color sideColor;
    final Color fg;
    final Color borderColor;
    if (bound) {
      faceColor = scheme.primaryContainer;
      sideColor = scheme.primary;
      fg = scheme.onPrimaryContainer;
      borderColor = scheme.primary;
    } else if (isModifier) {
      faceColor = scheme.secondaryContainer;
      sideColor = scheme.outlineVariant;
      fg = scheme.onSecondaryContainer;
      borderColor = scheme.outlineVariant;
    } else {
      faceColor = tokens.surfaces.card;
      sideColor = tokens.surfaces.group;
      fg = scheme.onSurfaceVariant;
      borderColor = scheme.outlineVariant;
    }

    // 顶面顶部高光：一条极淡的表面渐变（scheme 派生，不硬编码颜色）。
    final Color highlightColor = scheme.surface.withValues(alpha: 0.35);

    final Widget face = Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(
          color: borderColor,
          width: bound ? 1.5 : 1,
        ),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color.alphaBlend(highlightColor, faceColor),
            faceColor,
          ],
          stops: const <double>[0.0, 0.5],
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: theme.textTheme.labelMedium?.copyWith(
          color: fg,
          fontWeight: bound ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    );

    // 双层立体键帽：底层侧壁（占满高，深色），顶层键面（上移露出底部台阶）。
    final Widget cap = SizedBox(
      width: width,
      height: height,
      child: Stack(
        children: <Widget>[
          // 侧壁（底层）：填满，底部露出 stepHeight 的深色台阶。
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: sideColor,
                borderRadius: radius,
              ),
            ),
          ),
          // 键面（顶层）：顶部对齐、底部留 stepHeight 露台阶。
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            bottom: stepHeight,
            child: face,
          ),
        ],
      ),
    );

    if (onTap == null) return cap;

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: cap,
      ),
    );
  }
}

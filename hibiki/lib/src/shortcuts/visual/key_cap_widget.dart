import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

/// 单个键帽（TODO-612 阶段 1）。
///
/// 纯展示 + 点击入口：渲染键面 label、按 [bound] 高亮（已绑键位 = primary 容器色），
/// [onTap] 非空时整键可点（InkWell）。`Key('keycap_<keyId>')` 由 [KeyboardLayoutView]
/// 注入，供 widget 行为测试 tap 定位。本 widget 不持有任何绑定状态，高亮与否完全由
/// 上层 [ReverseBindingIndex] 决定后传入。
class KeyCapWidget extends StatelessWidget {
  const KeyCapWidget({
    super.key,
    required this.logicalKey,
    required this.label,
    required this.bound,
    this.onTap,
    this.width,
    this.height = 40,
  });

  /// 本键帽代表的逻辑键（用于上层判定高亮 / 路由点击；本 widget 不直接读绑定）。
  final LogicalKeyboardKey logicalKey;

  /// 键面显示文本（如 'A'、'Esc'、'Ctrl'）。
  final String label;

  /// 是否已绑（已绑高亮）。
  final bool bound;

  /// 点击回调；null 表示该键不可改（图上只读展示，改绑走列表 dialog 兜底）。
  final VoidCallback? onTap;

  /// 键帽宽度；null 时由父布局约束（如 Wrap 内按内容自适应）。
  final double? width;

  /// 键帽高度。
  final double height;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final BorderRadius radius = tokens.radii.chipRadius;
    final ColorScheme scheme = theme.colorScheme;
    final Color bg = bound ? scheme.primaryContainer : scheme.surface;
    final Color fg =
        bound ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    final Color border = bound ? scheme.primary : scheme.outlineVariant;

    final Widget cap = Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: radius,
        border: Border.all(
          color: border,
          width: bound ? 1.5 : 1,
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: theme.textTheme.labelMedium?.copyWith(
          color: fg,
          fontWeight: bound ? FontWeight.w600 : FontWeight.w400,
        ),
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

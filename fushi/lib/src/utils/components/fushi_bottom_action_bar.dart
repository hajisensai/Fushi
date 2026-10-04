import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 页面底部的动作条：一段可选说明 [message] + 一行 [leading]（占满剩余宽）
/// 与靠尾的 [actions]（之间 8 的间隔）。
///
/// 外观：
/// - MD3：贴底整条 surfaceContainer 底（墨水屏多一条 outlineVariant 上边线），
///   内边距 16 / 12，自带底部安全区；
/// - Apple：离屏幕左右 12、离底 12 的悬浮液态玻璃面（iOS 26 工具条）——只有
///   一行时是全圆角胶囊，带说明文字的多行条是圆角 24 的玻璃面；系统「降低透明度」
///   下由 [fushiGlassSettings] 回落实色。
///
/// 结构恒定：两套设计系统都是 SafeArea → Padding → 背景 → 内容，只换背景槽。
class FushiBottomActionBar extends StatelessWidget {
  const FushiBottomActionBar({
    super.key,
    this.message,
    this.leading,
    this.actions = const <Widget>[],
    this.md3Surface = true,
  });

  /// MD3 下是否铺 surfaceContainer 底。限宽居中摆放的动作条（宽屏下底色只铺
  /// 一截会很怪）给 false，只留内边距与安全区。Apple 不读。
  final bool md3Surface;

  /// 动作行上方的说明（多为一两行 bodySmall 文字）。
  final Widget? message;

  /// 动作行起始端、占满剩余宽度的内容（例如「已选 N 项」）。
  final Widget? leading;

  /// 动作行尾部的按钮，按给出顺序排布。
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool apple = isGlassDesign(context);
    final List<Widget> trailing = <Widget>[];
    for (int i = 0; i < actions.length; i++) {
      if (i > 0) trailing.add(const SizedBox(width: 8));
      trailing.add(actions[i]);
    }
    final Widget row = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: <Widget>[
        if (leading != null) Expanded(child: leading!) else const Spacer(),
        ...trailing,
      ],
    );
    final Widget? note = message;
    Widget content = note == null
        ? row
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DefaultTextStyle.merge(
                style:
                    theme.textTheme.bodySmall ?? const TextStyle(fontSize: 12),
                child: note,
              ),
              const SizedBox(height: 10),
              row,
            ],
          );

    if (apple) {
      final FushiAppleColors colors = appleColorsOf(context);
      final bool compact = fushiAppleCompact(context);
      final double minHeight = compact ? 44 : 52;
      final double radius = note == null ? minHeight / 2 : 24;
      content = DefaultTextStyle.merge(
        style: TextStyle(color: colors.label),
        child: content,
      );
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: GlassContainer(
            useOwnLayer: true,
            quality: fushiGlassQuality(context, prominent: true),
            settings: fushiClearGlassSettings(context, bar: true),
            shape: LiquidRoundedSuperellipse(borderRadius: radius),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minHeight),
              child: Padding(
                padding: EdgeInsetsDirectional.only(
                  start: note == null ? 18 : 16,
                  end: 8,
                  top: note == null ? 4 : 12,
                  bottom: note == null ? 4 : 8,
                ),
                child: Center(widthFactor: 1, heightFactor: 1, child: content),
              ),
            ),
          ),
        ),
      );
    }
    final ColorScheme cs = theme.colorScheme;
    // 底色铺进底部安全区（手势条下面也是同一块底）。
    return DecoratedBox(
      decoration: BoxDecoration(
        color: md3Surface ? cs.surfaceContainer : null,
        border: md3Surface && isEinkTheme(context)
            ? Border(top: BorderSide(color: cs.outlineVariant))
            : null,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: content,
        ),
      ),
    );
  }
}

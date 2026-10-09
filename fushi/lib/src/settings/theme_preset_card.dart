import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 外观 › 主题 的色板网格卡（2026-10 M3E 预设精简）：种子色块 + primary /
/// secondary / tertiary 三色条 + 名称。
///
/// - 三色条取自 [scheme]——调用方按**当前明暗**（含「纯黑深色背景」）生成，与
///   生效主题同源；预设本身不带明暗。
/// - 选中：种子色块从圆弹簧变形成圆角方块并浮出对勾（M3E 形状语言）；Apple
///   设计系统恒为圆形颜色井，选中只加对勾。墨水屏 / 减弱动态效果下直接到位。
/// - 整卡是 [FushiCard]：Tab / 方向键 / 手柄可达，Enter / A 选中，长按走
///   [onLongPress]（自定义主题进编辑页）。
class FushiThemePresetCard extends StatelessWidget {
  const FushiThemePresetCard({
    required this.seed,
    required this.scheme,
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
    this.onLongPress,
    this.overlay,
  });

  /// 卡片宽度（设置行里 Wrap 排列）。
  static const double width = 96;

  final Color seed;
  final ColorScheme scheme;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// 未选中时叠在种子色块中央的小图标（「跟随系统取色」的 ✨、新建的 +）。
  final IconData? overlay;

  static const double _blockSize = 40;

  @override
  Widget build(BuildContext context) {
    final SettingsKitStyle style = SettingsKitStyle.of(context);
    final bool apple = style == SettingsKitStyle.apple;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color onSeed = seed.computeLuminance() > 0.5
        ? const Color(0xFF000000)
        : const Color(0xFFFFFFFF);
    final Widget block = SettingsSpringValue(
      value: selected ? 1 : 0,
      spring: fushiExpressiveFastSpatial,
      builder: (BuildContext context, double v, Widget? _) {
        final double settled = v.clamp(0.0, 1.0);
        final double radius = apple
            ? _blockSize / 2
            : (lerpDouble(_blockSize / 2, 12, v) ?? _blockSize / 2).clamp(
                4.0,
                _blockSize / 2,
              );
        return Container(
          width: _blockSize,
          height: _blockSize,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: seed,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              if (overlay != null)
                Opacity(
                  opacity: 1 - settled,
                  child: FushiIcon(overlay!, size: 18, color: onSeed),
                ),
              Opacity(
                opacity: settled,
                child: FushiIcon(FushiIcons.check, size: 22, color: onSeed),
              ),
            ],
          ),
        );
      },
    );
    final Widget stripes = ClipRRect(
      borderRadius: BorderRadius.circular(apple ? 4 : 6),
      child: SizedBox(
        height: 10,
        child: Row(
          children: <Widget>[
            for (final Color c in <Color>[
              scheme.primary,
              scheme.secondary,
              scheme.tertiary,
            ])
              Expanded(child: ColoredBox(color: c)),
          ],
        ),
      ),
    );
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      excludeSemantics: true,
      child: FushiCard(
        selected: selected,
        color: selected
            ? null
            : (apple
                  ? appleColorsOf(context).tertiaryFill
                  : cs.surfaceContainerHigh),
        borderRadius: BorderRadius.circular(SettingsKitRadii.card(style)),
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
        onTap: onTap,
        onLongPress: onLongPress,
        child: SizedBox(
          width: width - 16,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              block,
              const SizedBox(height: 8),
              stripes,
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: context.fushiType.labelMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Apple（Cupertino，iOS 27 / macOS 27）内容区的胶囊按钮：默认 systemFill 底、
/// 强调色字（段头「播放」「换一个」）；压在取色大卡上时由调用方给 [background] /
/// [foreground]（大卡主操作反白、次要操作半透明）。音乐推荐、游戏首页共用。
///
/// Apple 专用件：只在 `isGlassDesign` 为真时由 Apple 布局调用；M3E 对应物是
/// `FushiFilledButton.tonalIcon`，由页面层按设计系统分派，本件不再自带 M3E 分支。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/apple/apple_text_style.dart';
import 'package:fushi/src/utils/components/fushi_focusable.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 胶囊按钮（图标 + 文字，高 30pt × macOS 档缩放）。按压缩放（[FushiPressScale]），
/// 键盘 / 手柄可聚焦、Enter 激活（[FushiFocusable]，焦点环画在胶囊上面）。
/// [icon] 为 null 时只有文字（如「详情」）。
class AppleCapsuleButton extends StatelessWidget {
  const AppleCapsuleButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.background,
    this.foreground,
  });

  final IconData? icon;
  final String label;
  final VoidCallback onTap;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors c = appleColorsOf(context);
    final double k = FushiAppleMetrics.of(context).scale;
    final Color bg = background ?? c.fill;
    final Color fg = foreground ?? c.accent;
    final double height = 30 * k;
    final BorderRadius radius = BorderRadius.circular(height / 2);
    final IconData? glyph = icon;
    return FushiPressScale(
      child: FushiFocusable(
        onTap: onTap,
        borderRadius: radius,
        ringPosition: DecorationPosition.foreground,
        child: Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: Container(
            height: height,
            padding: EdgeInsets.symmetric(horizontal: 12 * k),
            decoration: BoxDecoration(color: bg, borderRadius: radius),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (glyph != null) ...<Widget>[
                  FushiIcon(glyph, size: 13 * k, color: fg, fill: 1),
                  SizedBox(width: 5 * k),
                ],
                // 放不下（大字号 / 窄卡）时文字截断，胶囊不越出父级给的宽度；
                // 宽度无界（段头行尾等非弹性位）时 loose Flexible 按原宽排。
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: appleTextStyle(
                      context,
                      size: 13.5 * k,
                      weight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

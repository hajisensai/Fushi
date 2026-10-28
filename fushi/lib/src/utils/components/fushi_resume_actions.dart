import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart'
    show FushiButtonSize;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 各库页 / 首页「继续阅读 · 继续观看 · 继续游戏」hero 的统一动作行（2026-10-28
/// 重设计）：与详情页 [MediaDetailPrimaryButton] / [MediaDetailSecondaryButton]
/// 同一规格——主按钮 = M3E 尺寸档 M 填充胶囊（56 高、播放图标、「动词 · 目标」），
/// 次按钮 = 同高 tonal 胶囊（图标 + 文字），都带 0.96 按压回弹。此前书架合集 / 游戏 / 视频 / 书架四处
/// 各写一套（尺寸 M 与默认 40 混用、次按钮有的无图标、书架只有一枚装饰圆点），
/// 现一律走这里。
///
/// 主按钮文字是 Flexible：宽度不够按省略号收缩，不会把图标挤出按钮（BUG-3063）。
class FushiResumeActions extends StatelessWidget {
  const FushiResumeActions({
    required this.label,
    required this.onPressed,
    this.secondary,
    this.icon = FushiIcons.play,
    this.fill = false,
    this.overImage = false,
    this.primaryKey,
    super.key,
  });

  /// 主按钮文案（如「继续阅读 · 第 3 卷」）。
  final String label;
  final VoidCallback? onPressed;
  final IconData icon;

  /// 次按钮（「详情」/「编辑标签」等）；null = 只有主按钮。
  final FushiResumeSecondaryAction? secondary;

  /// 窄屏：主按钮占满整行，次按钮换到下一行。
  final bool fill;

  /// 压在图片上（Apple 下主按钮白底黑字）。
  final bool overImage;
  final Key? primaryKey;

  @override
  Widget build(BuildContext context) {
    final Widget primary = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: fill ? double.infinity : 420,
        minWidth: fill ? double.infinity : 0,
      ),
      child: FushiPressScale(
        scale: 0.96,
        child: FushiFilledButton.icon(
          key: primaryKey,
          size: FushiButtonSize.m,
          overImage: overImage,
          onPressed: onPressed,
          icon: FushiIcon(icon),
          label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
    final FushiResumeSecondaryAction? second = secondary;
    if (second == null) return primary;
    return Wrap(
      spacing: 12,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        primary,
        FushiPressScale(
          scale: 0.96,
          child: FushiFilledButton.tonalIcon(
            key: second.key,
            size: FushiButtonSize.m,
            onPressed: second.onPressed,
            icon: FushiIcon(second.icon),
            label: Text(second.label, maxLines: 1),
          ),
        ),
      ],
    );
  }
}

/// [FushiResumeActions] 的次按钮描述。
@immutable
class FushiResumeSecondaryAction {
  const FushiResumeSecondaryAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Key? key;
}

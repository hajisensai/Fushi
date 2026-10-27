import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 「循环当前句」开着时常驻画面的标记（Ix4j5SKUth：循环状态必须在 UI 上可见）。
///
/// [active] 翻转时淡入 / 缩放出现、淡出消失（时长取 [FushiMotion.short]，墨水屏与
/// 「减弱动态效果」下归零）；点它等价于再按一次开关（关闭循环），按压有
/// [FushiPressScale] 反馈。关闭态不占位、不拦指针。
class VideoLoopCueBadge extends StatelessWidget {
  const VideoLoopCueBadge({
    super.key,
    required this.active,
    required this.label,
    required this.tooltip,
    required this.onTap,
    required this.surfaceColor,
    required this.textColor,
  });

  final bool active;

  /// 徽章文字（「循环当前句」）。
  final String label;

  /// 悬停 / 无障碍提示（「点击停止循环」）。
  final String tooltip;

  final VoidCallback onTap;
  final Color surfaceColor;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      switchInCurve: FushiMotion.standard,
      switchOutCurve: FushiMotion.standard,
      transitionBuilder: (Widget child, Animation<double> animation) =>
          FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.85, end: 1).animate(animation),
              child: child,
            ),
          ),
      child: !active
          ? const SizedBox.shrink(key: ValueKey<String>('video-loop-cue-off'))
          : Tooltip(
              key: const ValueKey<String>('video-loop-cue-badge'),
              message: tooltip,
              child: Semantics(
                button: true,
                label: '$label · $tooltip',
                child: FushiPressScale(
                  child: Material(
                    color: surfaceColor,
                    shape: const StadiumBorder(),
                    child: InkWell(
                      customBorder: const StadiumBorder(),
                      canRequestFocus: false,
                      onTap: onTap,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            FushiIcon(
                              FushiIcons.repeat,
                              size: 16,
                              color: textColor,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              label,
                              style: TextStyle(color: textColor, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';

/// 媒体页「跳转回退」浮动胶囊：`← 返回 <位置>`｜`<位置> 前进 →`｜`×`。
///
/// 小说阅读器（含歌词模式）/ 漫画阅读器 / 视频播放器共用，历史栈见
/// [JumpHistory]。只在有可走的历史且 [visible] 时出现（没跳转过就不画，减少
/// 干扰）；显隐走 [FushiChromeReveal] 的 M3E 弹簧，按压走 [FushiPressScale]，
/// 墨水屏 / 减弱动态效果下瞬时。MD3 与 Apple 两套设计系统由 [FushiFloatingPill]
/// 分派。纯指针面：整块 [ExcludeFocus]，不进焦点遍历池。
///
/// [backLabel] / [forwardLabel] 是落点的位置文案（百分比 / 时间 / 页码）；null
/// 表示那一侧没有历史、按钮不画。两侧都为 null 时整颗胶囊不出现。
class FushiJumpHistoryPill extends StatelessWidget {
  const FushiJumpHistoryPill({
    super.key,
    required this.visible,
    required this.backLabel,
    required this.forwardLabel,
    required this.onBack,
    required this.onForward,
    required this.onClear,
    this.colors,
    this.from = AxisDirection.up,
  });

  final bool visible;
  final String? backLabel;
  final String? forwardLabel;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onClear;

  /// 胶囊底色 / 前景色；null 回落到 [fushiFloatingToolbarPalette]。
  final FushiFloatingToolbarColors? colors;

  /// 滑入来向（顶部胶囊 = up，底部 = down）。
  final AxisDirection from;

  @override
  Widget build(BuildContext context) {
    final String? back = backLabel;
    final String? forward = forwardLabel;
    final bool hasHistory = back != null || forward != null;
    final ({
      Color container,
      Color foreground,
      Color selectedContainer,
      Color selectedForeground,
    })
    palette = fushiFloatingToolbarPalette(context, colors: colors);
    final Color foreground = palette.foreground;
    return ExcludeFocus(
      child: FushiChromeReveal(
        visible: visible && hasHistory,
        from: from,
        child: Center(
          child: !hasHistory
              ? const SizedBox.shrink()
              : FushiFloatingPill(
                  color: palette.container,
                  child: IconTheme.merge(
                    data: IconThemeData(color: foreground, size: 20),
                    child: DefaultTextStyle.merge(
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: foreground,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (back != null)
                            _PillButton(
                              key: const ValueKey<String>('fushi_jump_back'),
                              icon: Icons.arrow_back_rounded,
                              label: back,
                              tooltip: t.media_jump_back(position: back),
                              iconFirst: true,
                              onPressed: onBack,
                            ),
                          if (forward != null)
                            _PillButton(
                              key: const ValueKey<String>('fushi_jump_forward'),
                              icon: Icons.arrow_forward_rounded,
                              label: forward,
                              tooltip: t.media_jump_forward(position: forward),
                              iconFirst: false,
                              onPressed: onForward,
                            ),
                          _PillButton(
                            key: const ValueKey<String>('fushi_jump_clear'),
                            icon: Icons.close_rounded,
                            label: null,
                            tooltip: t.media_jump_history_clear,
                            iconFirst: true,
                            onPressed: onClear,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.iconFirst,
    required this.onPressed,
  });

  final IconData icon;
  final String? label;
  final String tooltip;
  final bool iconFirst;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final String? text = label;
    final Widget iconWidget = Icon(icon);
    final Widget content = text == null
        ? iconWidget
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: iconFirst
                ? <Widget>[iconWidget, const SizedBox(width: 6), Text(text)]
                : <Widget>[Text(text), const SizedBox(width: 6), iconWidget],
          );
    return FushiTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        child: FushiPressScale(
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onPressed,
            child: ConstrainedBox(
              // 命中区 ≥ 48dp（M3 最小触控目标）。
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: text == null ? 12 : 16,
                ),
                child: Center(widthFactor: 1, child: content),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 媒体时间轴位置的胶囊文案：满一小时 `h:mm:ss`，否则 `m:ss`（有声书全书时间、
/// 视频播放位置共用）。
String formatJumpHistoryTime(int ms) {
  final Duration d = Duration(milliseconds: ms < 0 ? 0 : ms);
  final int h = d.inHours;
  final String m = (d.inMinutes % 60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final String s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

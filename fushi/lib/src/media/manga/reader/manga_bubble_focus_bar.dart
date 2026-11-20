import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// 逐格读（气泡聚焦）的底部浮条：`‹  序号 / 总数  ›  ✕`。
///
/// 只在触屏端出现（桌面用 ← → / 滚轮 / Tab / Esc / Z）。按钮纯图标，名称进 tooltip
/// 与语义，命中区 48dp。左右按钮按**屏幕方向**摆：RTL 书「下一个气泡」在左边，
/// 与左右滑换气泡的方向一致。
class MangaBubbleFocusBar extends StatelessWidget {
  const MangaBubbleFocusBar({
    super.key,
    required this.index,
    required this.total,
    required this.rtl,
    required this.onStep,
    required this.onExit,
  });

  /// 当前气泡在阅读顺序里的下标（0 起；-1 = 未知）。
  final int index;

  /// 本屏气泡总数。
  final int total;

  /// 本书是否右开（RTL）。
  final bool rtl;

  /// 换气泡：`+1` = 下一个、`-1` = 上一个（阅读顺序）。
  final ValueChanged<int> onStep;

  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int leftStep = rtl ? 1 : -1;
    Widget button({
      required Key key,
      required IconData icon,
      required String label,
      required VoidCallback? onPressed,
    }) => FushiPressScale(
      enabled: onPressed != null,
      child: IconButton(
        key: key,
        icon: Icon(icon),
        tooltip: label,
        onPressed: onPressed,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      ),
    );
    String labelFor(int step) =>
        step > 0 ? t.manga_bubble_focus_next : t.manga_bubble_focus_previous;
    // 跨页由脚本自动翻：两端的按钮也保持可点（到头就翻到相邻跨页）。
    VoidCallback stepper(int step) =>
        () => onStep(step);
    return Material(
      key: const ValueKey<String>('manga_bubble_focus_bar'),
      color: scheme.surfaceContainerHigh,
      elevation: 3,
      shape: const StadiumBorder(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            button(
              key: const ValueKey<String>('manga_bubble_focus_left'),
              icon: FushiIcons.chevronLeft,
              label: labelFor(leftStep),
              onPressed: stepper(leftStep),
            ),
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  total > 0 && index >= 0 ? '${index + 1} / $total' : '–',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ),
            button(
              key: const ValueKey<String>('manga_bubble_focus_right'),
              icon: FushiIcons.chevronRight,
              label: labelFor(-leftStep),
              onPressed: stepper(-leftStep),
            ),
            button(
              key: const ValueKey<String>('manga_bubble_focus_exit'),
              icon: FushiIcons.close,
              label: t.manga_bubble_focus_exit,
              onPressed: onExit,
            ),
          ],
        ),
      ),
    );
  }
}

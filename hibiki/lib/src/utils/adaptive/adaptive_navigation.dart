import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';

class AdaptiveNavItem {
  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  const AdaptiveNavItem({
    required this.icon,
    required this.label,
    this.selectedIcon,
  });
}

Widget adaptiveBottomBar({
  required BuildContext context,
  required int currentIndex,
  required ValueChanged<int> onTap,
  required List<AdaptiveNavItem> items,
}) {
  final Widget bar = isCupertinoPlatform(context)
      ? CupertinoTabBar(
          currentIndex: currentIndex,
          onTap: onTap,
          items: items
              .map((AdaptiveNavItem e) => BottomNavigationBarItem(
                    icon: Icon(e.icon),
                    label: e.label,
                  ))
              .toList(),
        )
      : NavigationBar(
          selectedIndex: currentIndex,
          onDestinationSelected: onTap,
          destinations: items
              .map((AdaptiveNavItem e) => NavigationDestination(
                    icon: Icon(e.icon),
                    selectedIcon: Icon(e.selectedIcon ?? e.icon),
                    label: e.label,
                  ))
              .toList(),
        );
  // Make the whole bar one gamepad focus stop (a horizontal selector): D-pad
  // Left/Right switches tabs in place, the ring follows the bar, and focus can
  // leave it upward — instead of leaking onto the bar's unregistered
  // destinations and losing the ring.
  return GamepadNavCluster(
    axis: Axis.horizontal,
    count: items.length,
    currentIndex: currentIndex,
    onSelect: onTap,
    child: bar,
  );
}

/// Wraps a stock NavigationBar / NavigationRail as a SINGLE gamepad/keyboard
/// focus stop. Directional focus can land on the navigation chrome (the app
/// focus ring follows it) and the along-axis D-pad switches tabs in place,
/// instead of focus leaking onto the bar's unregistered destinations and
/// dropping the ring. Mouse/touch still tap the underlying destinations
/// (ExcludeFocus only removes them from focus traversal). Passes [child]
/// straight through when there is no HibikiFocusRoot (plain widget tests).
class GamepadNavCluster extends StatefulWidget {
  const GamepadNavCluster({
    required this.axis,
    required this.count,
    required this.currentIndex,
    required this.onSelect,
    required this.child,
    super.key,
  });

  /// The cluster's main axis: [Axis.horizontal] (bottom bar) switches on D-pad
  /// Left/Right; [Axis.vertical] (side rail) switches on D-pad Up/Down.
  final Axis axis;
  final int count;
  final int currentIndex;

  /// Called with the new index when the D-pad steps to an adjacent tab. The
  /// index is in the same (possibly reversed) visual space as [currentIndex],
  /// so the caller's existing visual→logical mapping still applies.
  final ValueChanged<int> onSelect;
  final Widget child;

  @override
  State<GamepadNavCluster> createState() => _GamepadNavClusterState();
}

class _GamepadNavClusterState extends State<GamepadNavCluster> {
  late final HibikiFocusId _focusId =
      HibikiFocusId('nav-cluster-${identityHashCode(this)}');

  void _step(int delta) {
    if (widget.count <= 0) return;
    final int next = (widget.currentIndex + delta).clamp(0, widget.count - 1);
    if (next != widget.currentIndex) widget.onSelect(next);
  }

  @override
  Widget build(BuildContext context) {
    if (HibikiFocusRoot.maybeControllerOf(context) == null) {
      return widget.child;
    }
    final bool horizontal = widget.axis == Axis.horizontal;
    return Actions(
      actions: <Type, Action<Intent>>{
        // Only Left/Right (horizontal) or Up/Down (vertical) are ENABLED, so the
        // cross-axis press bubbles to leave the bar (Actions stops at the first
        // ENABLED action, not the first that returns true — same contract the
        // settings value rows rely on).
        GamepadButtonIntent: _GamepadNavStepAction(
          horizontal: horizontal,
          onPrev: () => _step(-1),
          onNext: () => _step(1),
        ),
      },
      child: Shortcuts(
        // Android delivers the D-pad as arrow keys; mirror the along-axis step.
        shortcuts: <ShortcutActivator, Intent>{
          SingleActivator(horizontal
              ? LogicalKeyboardKey.arrowLeft
              : LogicalKeyboardKey.arrowUp): const _NavStepIntent(-1),
          SingleActivator(horizontal
              ? LogicalKeyboardKey.arrowRight
              : LogicalKeyboardKey.arrowDown): const _NavStepIntent(1),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _NavStepIntent: CallbackAction<_NavStepIntent>(
              onInvoke: (_NavStepIntent intent) {
                _step(intent.delta);
                return null;
              },
            ),
          },
          child: HibikiFocusTarget(
            id: _focusId,
            child: ExcludeFocus(child: widget.child),
          ),
        ),
      ),
    );
  }
}

class _NavStepIntent extends Intent {
  const _NavStepIntent(this.delta);
  final int delta;
}

/// D-pad step action for [GamepadNavCluster], ENABLED only for the along-axis
/// pair (Left/Right horizontal, Up/Down vertical). Every other button reports
/// disabled so the press bubbles past the bar (cross-axis leaves it; A/B/LT/RT
/// reach the page), matching `_GamepadAdjustAction` in settings_shared.
class _GamepadNavStepAction extends Action<GamepadButtonIntent> {
  _GamepadNavStepAction({
    required this.horizontal,
    required this.onPrev,
    required this.onNext,
  });

  final bool horizontal;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  GamepadButton get _prev =>
      horizontal ? GamepadButton.dpadLeft : GamepadButton.dpadUp;
  GamepadButton get _next =>
      horizontal ? GamepadButton.dpadRight : GamepadButton.dpadDown;

  @override
  bool isEnabled(GamepadButtonIntent intent) =>
      intent.button == _prev || intent.button == _next;

  @override
  Object? invoke(GamepadButtonIntent intent) {
    if (intent.button == _next) {
      onNext();
    } else if (intent.button == _prev) {
      onPrev();
    }
    return true;
  }
}

PreferredSizeWidget adaptiveAppBar({
  required BuildContext context,
  Widget? leading,
  Widget? title,
  List<Widget>? actions,
  double? titleSpacing,
  PreferredSizeWidget? bottom,
}) {
  if (isCupertinoPlatform(context)) {
    final navBar = CupertinoNavigationBar(
      leading: leading,
      middle: title,
      trailing: actions != null && actions.isNotEmpty
          ? Row(mainAxisSize: MainAxisSize.min, children: actions)
          : null,
    );
    if (bottom == null) return navBar;
    return _CupertinoAppBarWithBottom(navBar: navBar, bottom: bottom);
  }
  return AppBar(
    leading: leading,
    title: title,
    actions: actions,
    titleSpacing: titleSpacing,
    bottom: bottom,
  );
}

class _CupertinoAppBarWithBottom extends StatelessWidget
    implements PreferredSizeWidget {
  final CupertinoNavigationBar navBar;
  final PreferredSizeWidget bottom;

  const _CupertinoAppBarWithBottom(
      {required this.navBar, required this.bottom});

  @override
  Size get preferredSize => Size.fromHeight(
      navBar.preferredSize.height + bottom.preferredSize.height);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [navBar, bottom],
    );
  }
}

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

class AdaptiveNavItem {
  final IconData icon;
  final IconData? selectedIcon;
  final String label;

  /// 在图标右上角叠加一个 MD3 小圆点徽标（无文字），标记该目的地为「实验性」。
  /// 底栏与侧栏共用同一渲染，徽标随之一致。
  final bool experimentalBadge;

  const AdaptiveNavItem({
    required this.icon,
    required this.label,
    this.selectedIcon,
    this.experimentalBadge = false,
  });
}

/// 当 [item] 标记为实验性时，给其图标 [child] 叠加一个 MD3 小圆点 [Badge]（无 label
/// 即默认小圆点，用 error 色吸引注意），否则原样返回。底栏（Material/Cupertino）与
/// 侧栏共用，保证徽标位置/样式一致。
Widget _maybeBadge({required AdaptiveNavItem item, required Widget child}) {
  if (!item.experimentalBadge) return child;
  return Badge(child: child);
}

/// Marks the root of the self-drawn Material navigation (bottom bar / side rail)
/// so integration tests can locate the top-level destinations without depending
/// on the private widget type or the stock NavigationBar/NavigationRail (which
/// this no longer uses on Material).
const Key hibikiMaterialNavKey = ValueKey<String>('hibiki-material-nav');

/// Marks the macOS-native (macos_ui) shell's content subtree so integration
/// tests can locate the top-level destinations without depending on the
/// MacosWindow/Sidebar internals. Mirrors [hibikiMaterialNavKey] for the macOS
/// design system.
const Key hibikiMacosNavKey = ValueKey<String>('hibiki-macos-nav');

/// TODO-973: pure decision for whether the global navigation chrome (bottom bar /
/// side rail) should be VISIBLE. The only input is whether gamepad auto-immersive
/// is currently active (the single source of truth on
/// [AppModel.gamepadImmersiveActive]). Kept standalone + pure so the truth table
/// "controller driving immersion ↔ nav hidden" is unit-testable without pumping a
/// whole HomePage. Inverse-trivial today, but a named seam keeps the gating rule
/// in one place if more immersion sources are added later.
bool navigationVisibleUnderGamepadImmersive(bool gamepadImmersiveActive) =>
    !gamepadImmersiveActive;

Widget adaptiveBottomBar({
  required BuildContext context,
  required int currentIndex,
  required ValueChanged<int> onTap,
  required List<AdaptiveNavItem> items,
  bool gamepadImmersiveActive = false,
}) {
  // TODO-973: when a controller is driving auto-immersive mode, collapse the
  // bottom bar entirely so it does not sit on top of an immersive surface. Opted-
  // out users never reach here with `true` (AppModel gates on the preference), so
  // default behaviour is unchanged (Never break userspace).
  if (!navigationVisibleUnderGamepadImmersive(gamepadImmersiveActive)) {
    return const SizedBox.shrink();
  }
  if (isCupertinoPlatform(context)) {
    // Cupertino keeps the stock tab bar as a single whole-bar gamepad stop. iOS
    // is touch-first and we don't self-draw its chrome; per-item focus is a
    // Material-only refinement (the rail/bottom bar the gamepad users hit).
    return GamepadNavCluster(
      axis: Axis.horizontal,
      count: items.length,
      currentIndex: currentIndex,
      onSelect: onTap,
      child: CupertinoTabBar(
        currentIndex: currentIndex,
        onTap: onTap,
        items: items
            .map((AdaptiveNavItem e) => BottomNavigationBarItem(
                  icon: _maybeBadge(item: e, child: Icon(e.icon)),
                  label: e.label,
                ))
            .toList(),
      ),
    );
  }
  // Material: each destination is its OWN gamepad/keyboard focus target, so the
  // app focus ring hugs the single selected item instead of wrapping the whole
  // bar. Directional D-pad steps between adjacent tiles through the normal
  // HibikiFocus geometry; A/Enter (or a tap) selects.
  return _MaterialNavCluster(
    axis: Axis.horizontal,
    currentIndex: currentIndex,
    onTap: onTap,
    items: items,
    idPrefix: 'nav-bar',
  );
}

/// Self-drawn Material navigation as a row (bottom bar) or column (side rail) of
/// per-item gamepad/keyboard focus targets. Reproduces the MD3 destination look
/// (indicator pill + icon swap + label) so the app focus ring can hug a single
/// destination — the stock [NavigationBar]/[NavigationRail] only expose the
/// whole bar as one focusable region.
class _MaterialNavCluster extends StatelessWidget {
  const _MaterialNavCluster({
    required this.axis,
    required this.currentIndex,
    required this.onTap,
    required this.items,
    required this.idPrefix,
    this.leading,
  });

  /// [Axis.horizontal] = bottom bar; [Axis.vertical] = side rail.
  final Axis axis;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<AdaptiveNavItem> items;

  /// Stable per-position focus id prefix; the bar and rail use distinct prefixes
  /// so their ids never collide (only one is mounted at a time anyway).
  final String idPrefix;

  /// Rail-only leading widget (the app logo). Ignored for the bottom bar.
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool horizontal = axis == Axis.horizontal;

    final List<Widget> tiles = <Widget>[
      for (int i = 0; i < items.length; i++)
        _NavFocusCell(
          id: HibikiFocusId('$idPrefix-$i'),
          item: items[i],
          selected: i == currentIndex,
          horizontal: horizontal,
          onSelect: () => onTap(i),
        ),
    ];

    if (horizontal) {
      return Material(
        key: hibikiMaterialNavKey,
        color: colors.surfaceContainer,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 80,
            child: Row(
              children: <Widget>[
                for (final Widget tile in tiles) Expanded(child: tile),
              ],
            ),
          ),
        ),
      );
    }

    return Material(
      key: hibikiMaterialNavKey,
      color: colors.surface,
      child: SizedBox(
        width: 80,
        child: SafeArea(
          right: false,
          child: Column(
            children: <Widget>[
              if (leading != null) leading!,
              // 矮窗口下所有 tile 的总高可能超过可用高度：直接放进 Column 会 RenderFlex
              // 溢出（左侧导航底部 overflow）。改用 SingleChildScrollView 让 tile 在窗口
              // 过矮时滚动；ConstrainedBox(minHeight: 视口高) + IntrinsicHeight 保证窗口
              // 够高时内容仍按 center 垂直居中（撑满视口才能 center），只有真的放不下才滚。
              Expanded(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    return SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(minHeight: constraints.maxHeight),
                        child: IntrinsicHeight(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              for (final Widget tile in tiles)
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 6),
                                  child: tile,
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One Material navigation destination wrapped as an independent gamepad/keyboard
/// focus target. The [HibikiFocusTarget] hugs the icon+label content so the app
/// focus ring frames just this item. A/Enter resolve to [ActivateIntent] (mapped
/// here to [onSelect]); a mouse/touch tap calls it directly. The [InkWell] does
/// not request focus — the focus node belongs to the [HibikiFocusTarget].
class _NavFocusCell extends StatelessWidget {
  const _NavFocusCell({
    required this.id,
    required this.item,
    required this.selected,
    required this.horizontal,
    required this.onSelect,
  });

  final HibikiFocusId id;
  final AdaptiveNavItem item;
  final bool selected;
  final bool horizontal;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final Widget tile = _HibikiNavTile(item: item, selected: selected);
    // ActivateIntent must sit ABOVE the focus node: the gamepad/keyboard path
    // dispatches it at the primary-focus context and walks UP the Actions chain.
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            onSelect();
            return null;
          },
        ),
      },
      child: InkWell(
        onTap: onSelect,
        canRequestFocus: false,
        borderRadius: HibikiDesignTokens.of(context).radii.controlRadius,
        child: Padding(
          padding: EdgeInsets.symmetric(
            vertical: horizontal ? 0 : 4,
            horizontal: horizontal ? 4 : 0,
          ),
          child: Center(
            child: HibikiFocusTarget(id: id, child: tile),
          ),
        ),
      ),
    );
  }
}

/// Pure MD3 destination visual: an indicator pill behind the icon (filled when
/// selected) over a label. Shared by the bottom bar and the side rail.
class _HibikiNavTile extends StatelessWidget {
  const _HibikiNavTile({required this.item, required this.selected});

  final AdaptiveNavItem item;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 64,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? colors.secondaryContainer : Colors.transparent,
            borderRadius: HibikiDesignTokens.of(context).radii.controlRadius,
          ),
          child: _maybeBadge(
            item: item,
            child: Icon(
              selected ? (item.selectedIcon ?? item.icon) : item.icon,
              size: 24,
              color: selected
                  ? colors.onSecondaryContainer
                  : colors.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          item.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.labelSmall?.copyWith(
            color: selected ? colors.onSurface : colors.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

/// Self-drawn Material navigation rail (per-item gamepad/keyboard focus). Mirrors
/// `NavigationRail(labelType: all)` with a leading logo and centered group, but
/// each destination is its own focus target so the ring hugs one item. [items]
/// and [currentIndex] are in visual order; [onTap] receives the visual index
/// (the caller keeps its visual→logical mapping, e.g. reversed rails).
Widget adaptiveNavRail({
  required BuildContext context,
  required int currentIndex,
  required ValueChanged<int> onTap,
  required List<AdaptiveNavItem> items,
  Widget? leading,
  bool gamepadImmersiveActive = false,
}) {
  // TODO-973: same gamepad-immersive collapse as the bottom bar — a controller
  // driving immersion hides the side rail too, so wide-window layouts go fully
  // immersive instead of keeping the rail beside an immersive surface.
  if (!navigationVisibleUnderGamepadImmersive(gamepadImmersiveActive)) {
    return const SizedBox.shrink();
  }
  return _MaterialNavCluster(
    axis: Axis.vertical,
    currentIndex: currentIndex,
    onTap: onTap,
    items: items,
    idPrefix: 'nav-rail',
    leading: leading,
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

/// 首页头像上的「首页显示」视图切换（首页视图开关开着时才挂）：右键 / 长按 / 键盘
/// （菜单键、Shift+F10）弹出视图菜单，以及第一次开启后在头像旁出现一次的提示。
///
/// 头像的主点击（打开排行榜 / 后台任务）不变；开关关着时首页根本不挂这里的任何东西。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, LogicalKeyboardKey, HardwareKeyboard;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/home_view.dart';
import 'package:fushi/src/models/home_views_host.dart';
import 'package:fushi/src/pages/implementations/home_views_page.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';

/// 菜单里「新建视图… / 编辑视图…」两项的值（视图 id 由 [newHomeViewId] 生成、恒以
/// `v` 开头，不会撞上）。
const String _kMenuNewView = '#new';
const String _kMenuEditViews = '#edit';

/// 在 [anchor]（头像）下方弹出「首页显示」菜单：全部 + 保存的视图（单选），新建视图…，
/// 编辑视图…。
Future<void> showHomeViewMenu({
  required BuildContext anchor,
  required HomeViewsHost appModel,
}) async {
  final List<HomeView> views = appModel.homeViews;
  final String activeId = appModel.activeHomeView?.id ?? kHomeViewEverythingId;
  final TextStyle? headerStyle = Theme.of(anchor).textTheme.labelMedium
      ?.copyWith(color: Theme.of(anchor).colorScheme.onSurfaceVariant);
  final String? choice = await showFushiMenu<String>(
    context: anchor,
    positionBuilder: fushiMenuAnchorPosition(anchor),
    semanticLabel: t.home_view_menu_title,
    initialValue: activeId,
    items: <PopupMenuEntry<String>>[
      PopupMenuItem<String>(
        enabled: false,
        height: 32,
        child: Text(t.home_view_menu_title, style: headerStyle),
      ),
      CheckedPopupMenuItem<String>(
        key: const ValueKey<String>('home-view-menu/everything'),
        value: kHomeViewEverythingId,
        checked: activeId == kHomeViewEverythingId,
        child: Text(t.home_view_everything),
      ),
      for (final HomeView v in views)
        CheckedPopupMenuItem<String>(
          key: ValueKey<String>('home-view-menu/${v.id}'),
          value: v.id,
          checked: activeId == v.id,
          child: Text(homeViewNameOf(v)),
        ),
      const PopupMenuDivider(),
      PopupMenuItem<String>(
        key: const ValueKey<String>('home-view-menu/new'),
        value: _kMenuNewView,
        child: Text(t.home_view_menu_new),
      ),
      PopupMenuItem<String>(
        key: const ValueKey<String>('home-view-menu/edit'),
        value: _kMenuEditViews,
        child: Text(t.home_view_menu_edit),
      ),
    ],
  );
  if (choice == null || !anchor.mounted) return;
  switch (choice) {
    case _kMenuNewView:
      await createHomeViewAndActivate(anchor, appModel);
    case _kMenuEditViews:
      await openHomeViewsPage(anchor, appModel);
    default:
      await appModel.setHomeViewActiveId(choice);
  }
}

/// 头像的视图菜单入口：右键（走绑定表，[ContextMenuTrigger]）、长按、键盘菜单键 /
/// Shift+F10（头像持有焦点时）。主点击由 [child] 自己处理，这里不碰。
class HomeViewAvatarControls extends StatelessWidget {
  const HomeViewAvatarControls({
    super.key,
    required this.onOpenMenu,
    required this.child,
  });

  final VoidCallback onOpenMenu;
  final Widget child;

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;
    final bool menuKey =
        key == LogicalKeyboardKey.contextMenu ||
        (key == LogicalKeyboardKey.f10 &&
            HardwareKeyboard.instance.isShiftPressed);
    if (!menuKey) return KeyEventResult.ignored;
    onOpenMenu();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => ContextMenuTrigger(
    onInvoke: contextMenuInvoker(onOpenMenu),
    child: GestureDetector(
      onLongPress: onOpenMenu,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: child,
      ),
    ),
  );
}

/// 第一次开启首页视图后在头像旁出现一次的提示（[show] 为真且首页此刻真被看着时）。
/// 「知道了」= [onGotIt]，「试试看」= [onShowMe]（调用方记下已显示并打开菜单）。
class HomeViewTipAnchor extends StatefulWidget {
  const HomeViewTipAnchor({
    super.key,
    required this.show,
    required this.onGotIt,
    required this.onShowMe,
    required this.child,
  });

  final bool show;
  final VoidCallback onGotIt;
  final VoidCallback onShowMe;
  final Widget child;

  @override
  State<HomeViewTipAnchor> createState() => _HomeViewTipAnchorState();
}

class _HomeViewTipAnchorState extends State<HomeViewTipAnchor> {
  final OverlayPortalController _portal = OverlayPortalController();

  /// 首页 tab 被藏起来 / 被别的页面盖住时 TickerMode 关掉；对话框之类不透明度不全的
  /// 路由盖上来时 TickerMode 不关，但首页路由不再是栈顶。两种情况提示都收起（它画在
  /// Overlay 里，不收会浮在别的页面 / 对话框上）。
  bool _visible(BuildContext context) =>
      widget.show &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.isCurrentOf(context) ?? true);

  void _sync(bool visible) {
    // 头像第一次布局完才知道往哪儿放：显示推迟到帧后。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      if (visible && !_portal.isShowing) _portal.show();
      if (!visible && _portal.isShowing) _portal.hide();
    });
  }

  @override
  Widget build(BuildContext context) {
    _sync(_visible(context));
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _buildTip,
      child: widget.child,
    );
  }

  Widget _buildTip(BuildContext _) {
    final RenderObject? box = context.findRenderObject();
    final RenderObject? overlay = Overlay.maybeOf(
      context,
    )?.context.findRenderObject();
    if (box is! RenderBox ||
        overlay is! RenderBox ||
        !box.hasSize ||
        !box.attached) {
      return const SizedBox.shrink();
    }
    final Rect anchor = MatrixUtils.transformRect(
      box.getTransformTo(overlay),
      Offset.zero & box.size,
    );
    return CustomSingleChildLayout(
      delegate: _TipLayout(anchor),
      child: _HomeViewTipCard(
        onGotIt: widget.onGotIt,
        onShowMe: widget.onShowMe,
      ),
    );
  }
}

/// 提示卡放在头像正下方（放不下就放上方），左右夹在屏幕内。
class _TipLayout extends SingleChildLayoutDelegate {
  const _TipLayout(this.anchor);

  final Rect anchor;

  static const double _margin = 16;
  static const double _gap = 8;
  static const double _maxWidth = 320;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.max(
          0,
          math.min(_maxWidth, constraints.maxWidth - _margin * 2),
        ),
        maxHeight: constraints.maxHeight,
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double maxX = math.max(
      _margin,
      size.width - _margin - childSize.width,
    );
    final double x = (anchor.center.dx - childSize.width / 2).clamp(
      _margin,
      maxX,
    );
    double y = anchor.bottom + _gap;
    if (y + childSize.height > size.height - _margin) {
      y = math.max(_margin, anchor.top - _gap - childSize.height);
    }
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_TipLayout oldDelegate) => oldDelegate.anchor != anchor;
}

class _HomeViewTipCard extends StatelessWidget {
  const _HomeViewTipCard({required this.onGotIt, required this.onShowMe});

  final VoidCallback onGotIt;
  final VoidCallback onShowMe;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget card = Material(
      key: const ValueKey<String>('home-view-tip'),
      color: tokens.surfaces.overlay,
      elevation: 3,
      shadowColor: scheme.shadow,
      shape: RoundedRectangleBorder(borderRadius: tokens.radii.menuRadius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Text(
                t.home_view_tip_body,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              children: <Widget>[
                FushiTextButton(
                  key: const ValueKey<String>('home-view-tip-got-it'),
                  onPressed: onGotIt,
                  child: Text(t.home_view_tip_got_it),
                ),
                FushiTextButton(
                  key: const ValueKey<String>('home-view-tip-show-me'),
                  onPressed: onShowMe,
                  child: Text(t.home_view_tip_show_me),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiMotion.enter,
      builder: (BuildContext context, double v, Widget? child) => Opacity(
        opacity: v.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - v) * -FushiMotion.enterOffset / 2),
          child: child,
        ),
      ),
      child: Semantics(container: true, liveRegion: true, child: card),
    );
  }
}

/// 打开菜单的便捷封装（首页头像用）：[unawaited] 掉异步结果。
void openHomeViewMenu({
  required BuildContext anchor,
  required HomeViewsHost appModel,
}) => unawaited(showHomeViewMenu(anchor: anchor, appModel: appModel));

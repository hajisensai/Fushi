import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/focus/hibiki_focus_target.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/hibiki_design_tokens.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 页头动作按钮「展开文字标签」的作用域开关。
///
/// BUG：`_labelExpanded` 原本只按**整窗**宽（[MediaQuery.sizeOf]）判定，与页头
/// 实际可用宽脱钩。桌面带导航栏 / 分栏时整窗 ≥840 但页头本地宽更窄，窗宽判定仍把
/// 4 个动作展开成药丸，[HibikiPageHeader] 里 [Expanded] 的标题被挤到贴着按钮甚至
/// 折成两行（用户反馈「已经重叠了还没降级成无字」）。
///
/// 修法：由 [HibikiPageHeader] 的行布局用 [LayoutBuilder] 拿到的**本地可用宽**
/// （经 UI 缩放还原真实宽）判定，仅 [WindowSizeClass.expanded]（真实 ≥840）才展开，
/// 结果经本作用域下发给后代 [HibikiIconButton]。域外（无此祖先，独立使用的带 label
/// 按钮）回退整窗判定，行为零变化。
class HibikiHeaderLabelScope extends InheritedWidget {
  const HibikiHeaderLabelScope({
    required this.expandLabels,
    required super.child,
    super.key,
  });

  /// 本作用域内的带 [HibikiIconButton.label] 按钮是否展开成图标+文字药丸。
  final bool expandLabels;

  /// 就近作用域的展开开关；无祖先返回 null（由调用方回退整窗判定）。
  static bool? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<HibikiHeaderLabelScope>()
      ?.expandLabels;

  @override
  bool updateShouldNotify(HibikiHeaderLabelScope oldWidget) =>
      expandLabels != oldWidget.expandLabels;
}

/// BUG-1033：纯图标按钮气泡的悬停延迟。
///
/// Material [Tooltip] 的 `waitDuration` 默认是 [Duration.zero]，而 Flutter 的
/// MouseTracker 每帧结束后会用**最后已知的光标位置**重新 hit-test。两者相乘的后果是：
/// 光标一动不动、只要有个带 tooltip 的按钮新出现在它下面，就会立刻冒出气泡——用户没有
/// 做过任何悬停动作。查词弹窗把这点放大成必现：嵌套查词的子弹窗锚成
/// `left = selectionRect.left` / `top = selectionRect.bottom + gap`（见
/// `dictionary_popup_layer.dart` 的 `calcPopupPosition`），左上角紧贴被查词，而顶栏最左端
/// 正是 A−/A+ ——子层一弹出，按钮必然落在用户刚点的那个词正下方，也就是光标停留处，于是
/// 「缩小查词字号」气泡自动盖住父层正文。
///
/// 根因在「零延迟」而非某一个调用点，故修在本组件这唯一出口：给一段悬停延迟，让气泡只对
/// **真实的悬停意图**作出反应。长按触发路径（移动端 [TooltipTriggerMode.longPress]）不看
/// 此值，行为不变。
const Duration kIconButtonTooltipHoverDelay = Duration(milliseconds: 500);

/// A button that can be set as busy. When busy, the icon is faded out when its
/// [onTap] action is on-going and processing, which can be used to
/// indicate when a button cannot be pressed once its click action has been
/// executed and is busy.
class HibikiIconButton extends StatefulWidget {
  /// Creates a busy icon button. Default values rely on [IconTheme].
  const HibikiIconButton({
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.onTapDown,
    this.busy = false,
    this.enabled = true,
    this.size,
    this.shapeBorder = const CircleBorder(),
    this.backgroundColor,
    this.enabledColor,
    this.disabledColor,
    this.constraints,
    this.padding,
    this.isWideTapArea = false,
    this.focusId,
    this.label,
    super.key,
  });

  /// The icon to display within the button.
  final IconData icon;

  /// 可展开文字标签：非空时渲染成「图标 + 文字」的描边药丸按钮（页头动作在宽窗展开
  /// 可读，对齐 Jellyfin 式工具栏），窄窗自动回落为纯图标圆钮，行为与 null 完全一致。
  /// 是否展开由 [_labelExpanded] 决定——[HibikiPageHeader] 内经 [HibikiHeaderLabelScope]
  /// 按**页头本地可用宽**判定（真实 ≥840 才展开，避免挤压标题）；域外独立使用回退整窗
  /// 宽（非 compact 即展开）。busy / enabled / 焦点注册在两种形态间共享同一路径。
  final String? label;

  /// The size of the icon. By default, this is 24.0.
  final double? size;

  /// Enforces all icons to have a tooltip that explains the purpose of this
  /// icon for accessibility and tutorial purposes.
  final String tooltip;

  /// Whether or not this icon should have busy behaviour, locking the icon
  /// out from being pressed when its [onTap] action is on-going.
  final bool busy;

  /// The action to execute and wait for. Use when the global position is
  /// needed.
  final FutureOr<void> Function(TapDownDetails)? onTapDown;

  /// The action to execute and wait for. While enabled,
  final FutureOr<void> Function()? onTap;

  /// For configuring a custom shaped button. By default, this is a circle.
  final ShapeBorder shapeBorder;

  /// Color of the shape around the icon.
  final Color? backgroundColor;

  /// What color to show for this icon when enabled. If null, this is the
  /// theme's default icon color.
  final Color? enabledColor;

  /// What color to show for this icon when disabled. If null, this is the
  /// theme's unselected widget color.
  final Color? disabledColor;

  /// Whether the icon is clickable upon build of this widget.
  final bool enabled;

  /// Allows overriding of the standard size of the [IconButton] constraints.
  final BoxConstraints? constraints;

  /// Allows overriding of the standard size of the [IconButton] padding.
  final EdgeInsets? padding;

  /// If this button needs to act like an [IconButton] with a wide area.
  final bool isWideTapArea;
  final HibikiFocusId? focusId;

  @override
  State<StatefulWidget> createState() => _HibikiIconButtonState();
}

class _HibikiIconButtonState extends State<HibikiIconButton> {
  late bool enabled;

  /// Stable fallback id so an icon button is a gamepad/keyboard focus target by
  /// default (no explicit [focusId] needed). Derived from this State's identity
  /// so it survives rebuilds and stays unique per instance — mirrors HibikiCard
  /// / HibikiListItem.
  late final HibikiFocusId _fallbackFocusId =
      HibikiFocusId('hibiki-icon-button-${identityHashCode(this)}');

  /// HBK-AUDIT-151: true while a busy [onTap] action is awaiting completion.
  /// Used so [didUpdateWidget] does not re-enable the button mid-action when
  /// the parent rebuilds during the await.
  bool _busyInFlight = false;

  @override
  void didUpdateWidget(HibikiIconButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // HBK-AUDIT-151: only sync enabled from widget.enabled when not currently
    // mid-busy; otherwise a parent rebuild during the await would clobber the
    // busy lock and re-enable the button before its action finished.
    if (!_busyInFlight) {
      enabled = widget.enabled;
    }
  }

  @override
  void initState() {
    super.initState();
    enabled = widget.enabled;
  }

  /// HBK-AUDIT-151: single busy-guard tap handler shared by both the
  /// [IconButton] (wide tap area) and [InkWell] branches, replacing the two
  /// previously byte-identical inline closures.
  Future<void> _handleTap() async {
    if (widget.busy) {
      if (enabled) {
        enabled = false;
        _busyInFlight = true;
        if (mounted) {
          setState(() {});
        }
        try {
          await widget.onTap?.call();
        } finally {
          enabled = true;
          _busyInFlight = false;
          if (mounted) {
            setState(() {});
          }
        }
      }
    } else {
      await widget.onTap?.call();
    }
  }

  Color get enabledColor =>
      widget.enabledColor ?? Theme.of(context).iconTheme.color!;
  Color get disabledColor =>
      widget.disabledColor ?? Theme.of(context).colorScheme.onSurfaceVariant;

  /// 是否展开文字标签。优先取 [HibikiHeaderLabelScope]（页头按**本地可用宽**下发的
  /// 权威判定）；域外独立使用时回退整窗宽判定（BUG-401，乘回 UI 缩放还原真实宽），
  /// 非 compact 即展开——保持独立按钮行为不变。
  bool _labelExpanded(BuildContext context) {
    final bool? scoped = HibikiHeaderLabelScope.maybeOf(context);
    if (scoped != null) return scoped;
    return windowSizeClassReal(
          MediaQuery.sizeOf(context).width,
          HibikiAppUiScale.of(context),
        ) !=
        WindowSizeClass.compact;
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final String? label = widget.label;
    if (label != null && _labelExpanded(context)) {
      final Color contentColor = enabled ? enabledColor : disabledColor;
      final Semantics pill = Semantics(
        label: widget.tooltip,
        button: true,
        child: InkWell(
          enableFeedback: enabled,
          customBorder: const StadiumBorder(),
          onTap: enabled ? _handleTap : null,
          onTapDown: widget.onTapDown,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.rowHorizontal - 2,
              vertical: tokens.spacing.gap - 1,
            ),
            decoration: ShapeDecoration(
              color: widget.backgroundColor ?? Colors.transparent,
              shape: StadiumBorder(
                side: BorderSide(color: tokens.surfaces.outline),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(widget.icon, size: widget.size ?? 18, color: contentColor),
                SizedBox(width: tokens.spacing.gap - 2),
                Text(
                  label,
                  style: tokens.type.controlLabel.copyWith(color: contentColor),
                ),
              ],
            ),
          ),
        ),
      );
      return _focusable(context, pill);
    }
    if (widget.isWideTapArea) {
      final Semantics button = Semantics(
        label: widget.tooltip,
        button: true,
        child: IconButton(
          constraints: BoxConstraints(
            maxWidth: tokens.spacing.gap * 6,
            maxHeight: tokens.spacing.gap * 6,
          ),
          icon: Icon(
            widget.icon,
            color: enabled ? enabledColor : disabledColor,
            size: widget.size,
          ),
          onPressed: enabled ? _handleTap : null,
        ),
      );
      return _focusable(context, _withTooltip(button));
    }

    Widget touchTarget = ColoredBox(
      color: widget.backgroundColor ?? Colors.transparent,
      child: Padding(
        padding: widget.padding ?? EdgeInsets.all(tokens.spacing.gap),
        child: Icon(
          widget.icon,
          size: widget.size,
          color: enabled ? enabledColor : disabledColor,
        ),
      ),
    );
    if (widget.constraints != null) {
      touchTarget = ConstrainedBox(
        constraints: widget.constraints!,
        child: Center(child: touchTarget),
      );
    }

    final Semantics button = Semantics(
      label: widget.tooltip,
      button: true,
      child: InkWell(
        enableFeedback: enabled,
        customBorder: widget.shapeBorder,
        onTap: enabled ? _handleTap : null,
        onTapDown: widget.onTapDown,
        child: touchTarget,
      ),
    );
    return _focusable(context, _withTooltip(button));
  }

  /// 纯图标按钮（无可见文字）用 Material [Tooltip] 包裹，让鼠标悬停 / 长按能弹出
  /// 用途说明——原先 [tooltip] 只喂给 [Semantics.label]（无障碍），屏幕上不可见，
  /// 导致批量操作栏等纯图标按钮「放上去没说明」。带可见文字的药丸形态无需再弹，
  /// 故不走此路径。空 [tooltip] 不包裹，避免弹出空浮层。
  Widget _withTooltip(Widget child) {
    if (widget.tooltip.isEmpty) return child;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: kIconButtonTooltipHoverDelay,
      child: child,
    );
  }

  Widget _focusable(BuildContext context, Widget button) {
    // A decorative icon (no onTap) must not pollute the focus traversal order —
    // same rule as HibikiCard / HibikiListItem with a null onTap.
    if (widget.onTap == null) return button;
    // Outside a HibikiFocusRoot (e.g. plain widget tests) stay a bare button —
    // zero overhead and no registration where there is no controller.
    if (HibikiFocusRoot.maybeControllerOf(context) == null) return button;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) async {
            if (enabled) await _handleTap();
            return null;
          },
        ),
      },
      child: HibikiFocusTarget(
        // Default to the stable derived id so every actionable icon button is
        // reachable by gamepad/keyboard; an explicit focusId overrides it.
        id: widget.focusId ?? _fallbackFocusId,
        enabled: enabled,
        child: button,
      ),
    );
  }
}

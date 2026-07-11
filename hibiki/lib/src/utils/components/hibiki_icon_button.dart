import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';

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

  /// 可展开文字标签：非空时，在非 compact 宽度（真实视口 ≥600，经
  /// [windowSizeClassReal] 判定）渲染成「图标 + 文字」的描边药丸按钮（页头动作在
  /// 宽窗展开可读，对齐 Jellyfin 式工具栏）；compact 窄窗自动回落为纯图标圆钮，
  /// 行为与 null 完全一致。busy / enabled / 焦点注册在两种形态间共享同一路径。
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

  /// 宽窗判定与 [HibikiPageHeader] 同源：真实视口宽（BUG-401，乘回 UI 缩放）
  /// 非 compact 才展开文字标签。
  bool _labelExpanded(BuildContext context) =>
      windowSizeClassReal(
        MediaQuery.sizeOf(context).width,
        HibikiAppUiScale.of(context),
      ) !=
      WindowSizeClass.compact;

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
      return _focusable(context, button);
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
    return _focusable(context, button);
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

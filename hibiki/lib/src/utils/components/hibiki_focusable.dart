import 'package:flutter/material.dart';

/// A focusable, gamepad/keyboard-activatable tap target for cases where a bare
/// [GestureDetector] would otherwise be unreachable by directional focus
/// navigation. Use ONLY for discrete buttons — not for swipe/drag/long-press
/// gesture surfaces. Standard Material widgets (InkWell, ListTile, IconButton)
/// are already focusable and should be preferred.
class HibikiFocusable extends StatelessWidget {
  const HibikiFocusable({
    super.key,
    required this.child,
    required this.onTap,
    this.focusNode,
    this.autofocus = false,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;
  final FocusNode? focusNode;
  final bool autofocus;
  final BorderRadius borderRadius;
  final HitTestBehavior behavior;

  @override
  Widget build(BuildContext context) {
    final Color focusColor = Theme.of(context).colorScheme.primary;
    return FocusableActionDetector(
      focusNode: focusNode,
      autofocus: autofocus,
      enabled: onTap != null,
      mouseCursor:
          onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onTap?.call();
            return null;
          },
        ),
      },
      child: Builder(builder: (BuildContext context) {
        final bool focused = Focus.of(context).hasPrimaryFocus;
        return GestureDetector(
          behavior: behavior,
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              border: focused
                  ? Border.all(color: focusColor, width: 2)
                  : Border.all(color: Colors.transparent, width: 2),
            ),
            child: child,
          ),
        );
      }),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';

/// A focusable, gamepad/keyboard-activatable tap target for cases where a bare
/// [GestureDetector] would otherwise be unreachable by directional focus
/// navigation. Use ONLY for discrete buttons — not for swipe/drag/long-press
/// gesture surfaces. Standard Material widgets (InkWell, ListTile, IconButton)
/// are already focusable and should be preferred.
class HibikiFocusable extends StatefulWidget {
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
  State<HibikiFocusable> createState() => _HibikiFocusableState();
}

class _HibikiFocusableState extends State<HibikiFocusable> {
  late final HibikiFocusId _fallbackId = HibikiFocusId(
    'focusable-${identityHashCode(this)}',
  );

  @override
  Widget build(BuildContext context) {
    final Color focusColor = Theme.of(context).colorScheme.primary;
    if (HibikiFocusRoot.maybeControllerOf(context) != null) {
      return MouseRegion(
        cursor: _mouseCursor,
        child: HibikiFocusTarget(
          id: _focusId,
          focusNode: widget.focusNode,
          enabled: widget.onTap != null,
          autofocus: widget.autofocus,
          child: _buildBody(context, focusColor),
        ),
      );
    }

    final Widget detector = FocusableActionDetector(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      enabled: widget.onTap != null,
      mouseCursor: _mouseCursor,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: _buildBody(context, focusColor),
    );
    return detector;
  }

  HibikiFocusId get _focusId {
    final Key? key = widget.key;
    final FocusNode? node = widget.focusNode;
    if (key != null) return HibikiFocusId('focusable-key-$key');
    if (node != null)
      return HibikiFocusId('focusable-node-${identityHashCode(node)}');
    return _fallbackId;
  }

  MouseCursor get _mouseCursor {
    return widget.onTap == null ? MouseCursor.defer : SystemMouseCursors.click;
  }

  Widget _buildBody(BuildContext context, Color focusColor) {
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: Builder(builder: (BuildContext context) {
        final bool focused = Focus.of(context).hasPrimaryFocus;
        return GestureDetector(
          behavior: widget.behavior,
          onTap: widget.onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: widget.borderRadius,
              border: focused
                  ? Border.all(color: focusColor, width: 2)
                  : Border.all(color: Colors.transparent, width: 2),
            ),
            child: widget.child,
          ),
        );
      }),
    );
  }
}

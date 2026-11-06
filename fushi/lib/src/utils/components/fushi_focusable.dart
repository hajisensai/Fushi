import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';

/// A focusable, gamepad/keyboard-activatable tap target for cases where a bare
/// [GestureDetector] would otherwise be unreachable by directional focus
/// navigation. Use ONLY for discrete buttons — not for swipe/drag/long-press
/// gesture surfaces. Standard Material widgets (InkWell, ListTile, IconButton)
/// are already focusable and should be preferred.
class FushiFocusable extends StatefulWidget {
  const FushiFocusable({
    super.key,
    required this.child,
    required this.onTap,
    this.focusNode,
    this.autofocus = false,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.behavior = HitTestBehavior.opaque,
    this.ringPosition = DecorationPosition.background,
  });

  final Widget child;
  final VoidCallback? onTap;
  final FocusNode? focusNode;
  final bool autofocus;
  final BorderRadius borderRadius;
  final HitTestBehavior behavior;

  /// 焦点环画在 [child] 下面（默认）还是上面。[child] 自带不透明底色（胶囊、色块）
  /// 时必须用 [DecorationPosition.foreground] 并让 [borderRadius] 与底色形状一致，
  /// 否则底色盖住环、只在圆角差处漏出几段残角（BUG-3440）。
  final DecorationPosition ringPosition;

  @override
  State<FushiFocusable> createState() => _FushiFocusableState();
}

class _FushiFocusableState extends State<FushiFocusable> {
  late final FushiFocusId _fallbackId = FushiFocusId(
    'focusable-${identityHashCode(this)}',
  );

  @override
  Widget build(BuildContext context) {
    final Color focusColor = Theme.of(context).colorScheme.primary;
    if (FushiFocusRoot.maybeControllerOf(context) != null) {
      return MouseRegion(
        cursor: _mouseCursor,
        child: FushiFocusTarget(
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

  FushiFocusId get _focusId {
    final Key? key = widget.key;
    final FocusNode? node = widget.focusNode;
    if (key != null) return FushiFocusId('focusable-key-$key');
    if (node != null) {
      return FushiFocusId('focusable-node-${identityHashCode(node)}');
    }
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
      child: Builder(
        builder: (BuildContext context) {
          final bool focused = Focus.of(context).hasPrimaryFocus;
          return GestureDetector(
            behavior: widget.behavior,
            onTap: widget.onTap,
            child: DecoratedBox(
              position: widget.ringPosition,
              decoration: BoxDecoration(
                borderRadius: widget.borderRadius,
                border: focused
                    ? Border.all(color: focusColor, width: 2)
                    : Border.all(color: Colors.transparent, width: 2),
              ),
              child: widget.child,
            ),
          );
        },
      ),
    );
  }
}

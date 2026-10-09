import 'package:flutter/widgets.dart';

/// Size animation that also accepts motion tokens reduced to [Duration.zero].
///
/// Flutter's zero-duration AnimatedSize can synchronously mark itself dirty
/// during layout. A disabled transition therefore uses ordinary layout. The
/// keyed child keeps its Element and State when the motion preference changes,
/// including while an animation is running.
class FushiAnimatedSize extends StatefulWidget {
  const FushiAnimatedSize({
    super.key,
    required this.duration,
    required this.curve,
    this.alignment = Alignment.center,
    this.clipBehavior = Clip.hardEdge,
    this.onEnd,
    required this.child,
  });

  final Duration duration;
  final Curve curve;
  final AlignmentGeometry alignment;
  final Clip clipBehavior;

  /// Called when an animated transition completes. Immediate layout while
  /// motion is disabled does not start an animation or invoke this callback.
  final VoidCallback? onEnd;
  final Widget child;

  @override
  State<FushiAnimatedSize> createState() => _FushiAnimatedSizeState();
}

class _FushiAnimatedSizeState extends State<FushiAnimatedSize> {
  final GlobalKey _childKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final Widget child = KeyedSubtree(key: _childKey, child: widget.child);
    if (widget.duration == Duration.zero) {
      // AnimatedSize forwards its incoming constraints unchanged. Returning
      // the child also preserves tight constraints; Align would loosen them.
      return child;
    }
    return AnimatedSize(
      duration: widget.duration,
      curve: widget.curve,
      alignment: widget.alignment,
      clipBehavior: widget.clipBehavior,
      onEnd: widget.onEnd,
      child: child,
    );
  }
}

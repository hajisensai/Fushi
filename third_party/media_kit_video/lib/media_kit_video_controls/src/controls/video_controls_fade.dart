/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Fushi patch (glass chrome fade): lets the host replace the controls'
/// show / hide fade. See third_party/media_kit_video/PATCHES.md.
// ignore_for_file: public_member_api_docs
import 'package:flutter/widgets.dart';

/// Fades the whole controls layer at [opacity] (0 = hidden, 1 = shown).
///
/// The upstream fade is one `AnimatedOpacity` over every control. A host whose
/// controls hold backdrop-filter glass cannot use that: a backdrop filter under
/// an `OpacityLayer` only sees the (empty) layer, not the video behind it, so
/// the glass turns into a grey blob while the icons fade and pops at the end.
/// With this builder set the fork pushes **no** opacity over the layer — the
/// host fades its own glass through the glass's shader uniforms and its own
/// non-glass content leaf by leaf — and the fork fades only its own leaves
/// (scrims, seek bar) through [VideoControlsLeafFade].
typedef VideoControlsFadeBuilder = Widget Function(
  BuildContext context,
  double opacity,
  Widget child,
);

/// The controls layer at [opacity]: upstream `Opacity` when [builder] is null,
/// otherwise [builder] plus the scope [VideoControlsLeafFade] reads.
class VideoControlsFade extends StatelessWidget {
  const VideoControlsFade({
    super.key,
    required this.opacity,
    required this.builder,
    required this.child,
  });

  final double opacity;
  final VideoControlsFadeBuilder? builder;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final VideoControlsFadeBuilder? b = builder;
    if (b == null) return Opacity(opacity: opacity, child: child);
    return _VideoControlsFadeScope(
      opacity: opacity,
      child: b(context, opacity, child),
    );
  }
}

class _VideoControlsFadeScope extends InheritedWidget {
  const _VideoControlsFadeScope({required this.opacity, required super.child});

  final double opacity;

  @override
  bool updateShouldNotify(_VideoControlsFadeScope oldWidget) =>
      opacity != oldWidget.opacity;
}

/// A fork-owned, glass-free leaf of the controls (scrim, seek bar): faded here
/// when a host [VideoControlsFadeBuilder] took over the layer fade, untouched
/// (the layer `Opacity` already covers it) otherwise.
class VideoControlsLeafFade extends StatelessWidget {
  const VideoControlsLeafFade({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final _VideoControlsFadeScope? scope =
        context.dependOnInheritedWidgetOfExactType<_VideoControlsFadeScope>();
    if (scope == null) return child;
    return Opacity(opacity: scope.opacity, child: child);
  }
}

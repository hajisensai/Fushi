// Fushi patch: hit-test marker for the controls chrome. See
// third_party/media_kit_video/PATCHES.md.
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Marks a controls-chrome surface (top bar, primary bar, seek bar, bottom bar)
/// so the host can tell from a real hit test whether a pointer landed on the
/// controls rather than on the picture.
///
/// [HitTestBehavior.translucent]: the marker joins the hit path whenever the
/// pointer is inside its bounds (including the gaps between buttons and the
/// bar margins) but returns its child's result, so hit testing of siblings
/// below — the tap router, the touch swipe layer — is unchanged.
class VideoControlsChromeRegion extends StatelessWidget {
  final Widget child;

  const VideoControlsChromeRegion({super.key, required this.child});

  static const Object _marker = _VideoControlsChromeMarker();

  /// Whether [target] (an entry of a [HitTestResult] path) is a chrome region.
  static bool isRegion(HitTestTarget target) =>
      target is RenderMetaData && identical(target.metaData, _marker);

  @override
  Widget build(BuildContext context) {
    return MetaData(
      metaData: _marker,
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }
}

class _VideoControlsChromeMarker {
  const _VideoControlsChromeMarker();
}

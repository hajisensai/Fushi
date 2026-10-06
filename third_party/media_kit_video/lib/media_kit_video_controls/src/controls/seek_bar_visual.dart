// Hibiki patch (M3 Expressive video chrome): a host-supplied seek-bar track
// visual. The fork keeps every gesture / seek / callback path of its seek bars
// and only hands the *painting* of the track to the host when the theme sets
// `seekBarTrackBuilder`. Null (upstream default) = the upstream track, pixel
// for pixel. See third_party/media_kit_video/PATCHES.md.

import 'package:flutter/widgets.dart';

/// Snapshot of a seek bar's visual state, handed to [VideoSeekBarTrackBuilder].
@immutable
class VideoSeekBarVisual {
  const VideoSeekBarVisual({
    required this.position,
    required this.buffer,
    required this.hover,
    required this.hovering,
    required this.dragging,
    required this.playing,
    required this.duration,
    required this.alignment,
  });

  /// Displayed position fraction `[0,1]` (follows the pointer while dragging).
  final double position;

  /// Buffered fraction `[0,1]`.
  final double buffer;

  /// Pointer fraction `[0,1]` while hovering / dragging, else null.
  final double? hover;

  /// Pointer is over the bar (desktop hover).
  final bool hovering;

  /// Pointer is pressed on the bar (scrubbing).
  final bool dragging;

  /// Player is playing.
  final bool playing;

  /// Media duration (for time labels).
  final Duration duration;

  /// Where the track sits inside the hit box (desktop: centre; mobile: the
  /// theme's `seekBarAlignment`, upstream bottom).
  final Alignment alignment;
}

/// Paints the seek-bar track; the returned widget fills the bar's hit box.
typedef VideoSeekBarTrackBuilder = Widget Function(
  BuildContext context,
  VideoSeekBarVisual visual,
);

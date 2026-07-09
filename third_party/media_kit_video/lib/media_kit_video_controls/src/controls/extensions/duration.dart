/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.

/// Hibiki patch (TODO-1243): the on-screen controls (seek bar fill + `mm:ss`
/// position clock) quantize the libmpv playback position to this step before
/// they rebuild.
///
/// Root cause of the integrated-GPU (`gpu0`) 100% load users hit when the
/// playback-controls overlay is shown: the vendored seek bar
/// (`MaterialSeekBarState` / `MaterialDesktopSeekBarState`) and the position
/// indicator (`MaterialPositionIndicatorState` / desktop twin) each subscribe to
/// `player.stream.position`, which libmpv emits at the *video frame rate*
/// (`time-pos` property change, ~60/s). Every emit calls `setState`, so while the
/// overlay is visible the seek bar re-rasters and the whole controls picture is
/// re-painted ~60x/s on top of the already-per-frame-composited video texture —
/// on an integrated GPU that pins the raster thread.
///
/// A 200 ms step (5 fps) is imperceptible for a scrubber fill and, because it
/// divides 1000 ms evenly, `floorTo` never changes the `mm:ss` clock text (the
/// flooring stays inside the same whole second). Seeking is unaffected: the drag
/// path uses the pointer-derived `slider`, not this quantized `position`.
const Duration kPositionUiThrottleStep = Duration(milliseconds: 200);

/// Extension methods for [Duration].
extension DurationExtension on Duration {
  /// Returns clamp of [Duration] between [min] and [max].
  Duration clamp(Duration min, Duration max) {
    if (this < min) return min;
    if (this > max) return max;
    return this;
  }

  /// Floors this [Duration] down to the nearest multiple of [step] (Hibiki patch,
  /// TODO-1243). Used to quantize the controls' displayed playback position so
  /// they rebuild at ~`1000/step.inMilliseconds` fps instead of the libmpv frame
  /// rate. Non-positive [step] returns `this` unchanged (no quantization).
  Duration floorTo(Duration step) {
    final int stepMs = step.inMilliseconds;
    if (stepMs <= 0) return this;
    return Duration(milliseconds: (inMilliseconds ~/ stepMs) * stepMs);
  }

  /// Returns a [String] representation of [Duration].
  String label({Duration? reference}) {
    reference ??= this;
    reference = reference.abs();

    if (isNegative) {
      return abs().label(reference: reference);
    }

    if (reference > const Duration(days: 1)) {
      final days = inDays.toString().padLeft(3, '0');
      final hours = (inHours - (inDays * 24)).toString().padLeft(2, '0');
      final minutes = (inMinutes - (inHours * 60)).toString().padLeft(2, '0');
      final seconds = (inSeconds - (inMinutes * 60)).toString().padLeft(2, '0');
      return '$days:$hours:$minutes:$seconds';
    } else if (reference > const Duration(hours: 1)) {
      final hours = inHours.toString().padLeft(2, '0');
      final minutes = (inMinutes - (inHours * 60)).toString().padLeft(2, '0');
      final seconds = (inSeconds - (inMinutes * 60)).toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    } else {
      final minutes = inMinutes.toString().padLeft(2, '0');
      final seconds = (inSeconds - (inMinutes * 60)).toString().padLeft(2, '0');
      return '$minutes:$seconds';
    }
  }
}

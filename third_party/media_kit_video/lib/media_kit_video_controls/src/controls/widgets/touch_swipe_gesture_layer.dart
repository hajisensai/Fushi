// Hibiki patch (touch on desktop, e.g. Microsoft Surface): the mobile controls'
// swipe gestures — horizontal drag to seek, left-half vertical drag for
// brightness, right-half vertical drag for volume — as a standalone layer the
// desktop controls mount for touch / stylus pointers only. See
// third_party/media_kit_video/PATCHES.md.
//
// The arithmetic is the mobile controls' (`material.dart`
// `onHorizontalDragUpdate` / `onHorizontalDragEnd` / `onVerticalDragUpdate`):
// the horizontal delta comes from the host's [HorizontalSeekResolver] measured
// from one base snapshotted at drag start (BUG-2731 follow-up), committed on
// release; vertical drags move a 0..1 level by `-dy / sensitivity`. Feedback is
// the host's: [seekIndicatorBuilder] while scrubbing, and the host's own HUD
// behind [onVolumeChanged] / [onBrightnessChanged].
//
// Restricted to [supportedDevices] (touch-like by default) so mouse drags never
// enter these recognizers — the desktop mouse behaviour stays untouched.

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit_video/media_kit_video_controls/src/controls/material.dart'
    show HorizontalSeekResolver;

/// Pointer kinds the swipe layer listens to by default.
const Set<PointerDeviceKind> kTouchSwipePointerKinds = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
};

/// Mobile-style swipe gestures over a video surface (see file comment).
class TouchSwipeGestureLayer extends StatefulWidget {
  const TouchSwipeGestureLayer({
    super.key,
    this.supportedDevices = kTouchSwipePointerKinds,
    required this.seekGesture,
    required this.horizontalSeekResolver,
    required this.duration,
    required this.seekBase,
    required this.onSeek,
    this.seekIndicatorBuilder,
    required this.volumeGesture,
    required this.currentVolume,
    this.onVolumeChanged,
    required this.brightnessGesture,
    required this.currentBrightness,
    this.onBrightnessChanged,
    this.verticalGestureSensitivity = 100.0,
  });

  final Set<PointerDeviceKind> supportedDevices;

  /// Horizontal drag scrubs (needs [horizontalSeekResolver]).
  final bool seekGesture;
  final HorizontalSeekResolver? horizontalSeekResolver;

  /// Media duration (read at every update).
  final Duration Function() duration;

  /// Position the drag measures from; read once when the drag starts.
  final Duration Function() seekBase;

  /// Commit the scrub on release (already clamped to `0..duration`).
  final ValueChanged<Duration> onSeek;

  /// Shown centred while scrubbing with the signed delta.
  final Widget Function(BuildContext context, Duration delta)?
      seekIndicatorBuilder;

  /// Right-half vertical drag adjusts the volume (0..1).
  final bool volumeGesture;
  final double Function() currentVolume;
  final ValueChanged<double>? onVolumeChanged;

  /// Left-half vertical drag adjusts the brightness (0..1).
  final bool brightnessGesture;
  final double Function() currentBrightness;
  final ValueChanged<double>? onBrightnessChanged;

  /// Pixels of vertical travel for a full 0→1 sweep (mobile default 100).
  final double verticalGestureSensitivity;

  @override
  State<TouchSwipeGestureLayer> createState() => _TouchSwipeGestureLayerState();
}

enum _VerticalTarget { none, volume, brightness }

class _TouchSwipeGestureLayerState extends State<TouchSwipeGestureLayer> {
  // Horizontal scrub state.
  Offset? _dragOrigin;
  Duration? _swipeBase;
  Duration _swipeDuration = Duration.zero;
  bool _showSwipeDuration = false;

  // Vertical level state.
  _VerticalTarget _verticalTarget = _VerticalTarget.none;
  double _level = 0.0;

  bool get _seekEnabled =>
      widget.seekGesture && widget.horizontalSeekResolver != null;

  bool get _verticalEnabled =>
      (widget.volumeGesture && widget.onVolumeChanged != null) ||
      (widget.brightnessGesture && widget.onBrightnessChanged != null);

  double _width() {
    final RenderObject? box = context.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size.width : 0.0;
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    if (!_seekEnabled) return;
    _dragOrigin = details.localPosition;
    _swipeBase = widget.seekBase();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    final Offset? origin = _dragOrigin;
    final Duration? base = _swipeBase;
    final HorizontalSeekResolver? resolver = widget.horizontalSeekResolver;
    if (origin == null || base == null || resolver == null) return;
    final Duration delta = resolver(
      dragDx: details.localPosition.dx - origin.dx,
      surfaceWidth: _width(),
      duration: widget.duration(),
      position: base,
    );
    setState(() {
      _swipeDuration = delta;
      _showSwipeDuration = true;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails _) {
    final Duration? base = _swipeBase;
    if (base != null && _swipeDuration != Duration.zero) {
      Duration target = base + _swipeDuration;
      final Duration duration = widget.duration();
      if (target < Duration.zero) target = Duration.zero;
      if (target > duration) target = duration;
      widget.onSeek(target);
    }
    _resetHorizontal();
  }

  void _resetHorizontal() {
    _dragOrigin = null;
    _swipeBase = null;
    if (!mounted) return;
    setState(() {
      _showSwipeDuration = false;
      _swipeDuration = Duration.zero;
    });
  }

  void _onVerticalDragStart(DragStartDetails details) {
    final bool leftHalf = details.localPosition.dx <= _width() / 2;
    if (leftHalf) {
      if (widget.brightnessGesture && widget.onBrightnessChanged != null) {
        _verticalTarget = _VerticalTarget.brightness;
        _level = widget.currentBrightness().clamp(0.0, 1.0).toDouble();
        return;
      }
    } else if (widget.volumeGesture && widget.onVolumeChanged != null) {
      _verticalTarget = _VerticalTarget.volume;
      _level = widget.currentVolume().clamp(0.0, 1.0).toDouble();
      return;
    }
    _verticalTarget = _VerticalTarget.none;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_verticalTarget == _VerticalTarget.none) return;
    _level = (_level - details.delta.dy / widget.verticalGestureSensitivity)
        .clamp(0.0, 1.0)
        .toDouble();
    if (_verticalTarget == _VerticalTarget.volume) {
      widget.onVolumeChanged?.call(_level);
    } else {
      widget.onBrightnessChanged?.call(_level);
    }
  }

  void _onVerticalDragEnd() {
    _verticalTarget = _VerticalTarget.none;
  }

  @override
  Widget build(BuildContext context) {
    final Widget Function(BuildContext, Duration)? indicator =
        widget.seekIndicatorBuilder;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          supportedDevices: widget.supportedDevices,
          onHorizontalDragStart: _seekEnabled ? _onHorizontalDragStart : null,
          onHorizontalDragUpdate: _seekEnabled ? _onHorizontalDragUpdate : null,
          onHorizontalDragEnd: _seekEnabled ? _onHorizontalDragEnd : null,
          onHorizontalDragCancel: _seekEnabled ? _resetHorizontal : null,
          onVerticalDragStart: _verticalEnabled ? _onVerticalDragStart : null,
          onVerticalDragUpdate: _verticalEnabled ? _onVerticalDragUpdate : null,
          onVerticalDragEnd: _verticalEnabled
              ? (DragEndDetails _) => _onVerticalDragEnd()
              : null,
          onVerticalDragCancel: _verticalEnabled ? _onVerticalDragEnd : null,
          child: const ColoredBox(color: Color(0x00000000)),
        ),
        if (_showSwipeDuration && indicator != null)
          IgnorePointer(
            child: Center(child: indicator(context, _swipeDuration)),
          ),
      ],
    );
  }
}

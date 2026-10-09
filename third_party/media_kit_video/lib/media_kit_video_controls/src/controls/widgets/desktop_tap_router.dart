// Hibiki patch (touch on desktop, e.g. Microsoft Surface): route a tap on the
// desktop controls surface by the pointer kind that produced it. See
// third_party/media_kit_video/PATCHES.md.
//
// The desktop controls are designed around a hovering mouse: hover reveals the
// bar, a click toggles play/pause. A finger never hovers (Flutter's
// MouseTracker ignores touch pointers), so on a Windows touch screen the bar
// could only be brought up by double-tapping into fullscreen (which remounts
// it), and every single tap paused the video. With
// [MaterialDesktopTapRouter.touchTapTogglesControls] a touch / stylus tap
// behaves like the mobile controls' `onTap` instead — toggle the bar — while a
// mouse click keeps the upstream / BUG-374 play-pause behaviour.

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// What a single tap on the desktop controls surface should do.
enum DesktopControlsTapAction {
  /// Nothing (tap feature disabled, or a mouse tap on the bottom bar strip).
  none,

  /// Toggle play / pause (mouse click, `playAndPauseOnTap`).
  playOrPause,

  /// Reveal the controls and arm the auto-hide timer (touch, bar hidden).
  showControls,

  /// Hide the controls now (touch, bar visible).
  hideControls,

  /// Keep the visible controls alive (touch on the bottom bar strip, i.e. in
  /// the gaps between buttons / around the seek bar): restart auto-hide.
  keepControlsAlive,
}

/// Whether [kind] is a direct-manipulation pointer that cannot hover-reveal the
/// controls (finger or pen tip). Mouse / trackpad keep the desktop semantics.
bool isTouchLikePointerKind(PointerDeviceKind? kind) =>
    kind == PointerDeviceKind.touch ||
    kind == PointerDeviceKind.stylus ||
    kind == PointerDeviceKind.invertedStylus;

/// Pure decision for one tap. [inPlayPauseRegion] is false when the tap landed
/// on the bottom bar strip while the bar is mounted (the upstream
/// "don't pause when clicking next to the seek bar" exclusion).
DesktopControlsTapAction resolveDesktopControlsTap({
  required PointerDeviceKind? kind,
  required bool inPlayPauseRegion,
  required bool controlsVisible,
  required bool playAndPauseOnTap,
  required bool touchTapTogglesControls,
}) {
  if (touchTapTogglesControls && isTouchLikePointerKind(kind)) {
    if (!inPlayPauseRegion) return DesktopControlsTapAction.keepControlsAlive;
    return controlsVisible
        ? DesktopControlsTapAction.hideControls
        : DesktopControlsTapAction.showControls;
  }
  if (playAndPauseOnTap && inPlayPauseRegion) {
    return DesktopControlsTapAction.playOrPause;
  }
  return DesktopControlsTapAction.none;
}

/// The tap layer of the desktop controls.
///
/// BUG-374 (kept): the action runs in `onTap`, which only fires when this
/// detector wins the gesture arena — a descendant button that claims the tap
/// suppresses it. `onTapDown` only records where / with what the tap started.
class MaterialDesktopTapRouter extends StatefulWidget {
  const MaterialDesktopTapRouter({
    super.key,
    required this.playAndPauseOnTap,
    required this.touchTapTogglesControls,
    required this.controlsVisible,
    required this.isInPlayPauseRegion,
    required this.onAction,
    this.onTapUp,
    required this.child,
  });

  /// Mouse click toggles play / pause (theme `playAndPauseOnTap`).
  final bool playAndPauseOnTap;

  /// Touch / stylus tap toggles the controls (theme `touchTapTogglesControls`).
  final bool touchTapTogglesControls;

  /// The controls' current (authoritative) visibility.
  final bool controlsVisible;

  /// Whether a tap starting at this global position is outside the bottom bar
  /// strip (see [resolveDesktopControlsTap]).
  final bool Function(Offset globalPosition) isInPlayPauseRegion;

  /// Called with the resolved action (never with [DesktopControlsTapAction.none]).
  final ValueChanged<DesktopControlsTapAction> onAction;

  /// Pass-through for the upstream double-press-fullscreen handler.
  final GestureTapUpCallback? onTapUp;

  final Widget child;

  @override
  State<MaterialDesktopTapRouter> createState() =>
      _MaterialDesktopTapRouterState();
}

class _MaterialDesktopTapRouterState extends State<MaterialDesktopTapRouter> {
  // BUG-374: recorded in onTapDown, consumed in onTap.
  bool _playPauseTapEligible = false;
  PointerDeviceKind? _tapKind;

  @override
  Widget build(BuildContext context) {
    final bool tapEnabled =
        widget.playAndPauseOnTap || widget.touchTapTogglesControls;
    return GestureDetector(
      onTapDown: !tapEnabled
          ? null
          : (TapDownDetails details) {
              _playPauseTapEligible =
                  widget.isInPlayPauseRegion(details.globalPosition);
              _tapKind = details.kind;
            },
      onTap: !tapEnabled
          ? null
          : () {
              final DesktopControlsTapAction action = resolveDesktopControlsTap(
                kind: _tapKind,
                inPlayPauseRegion: _playPauseTapEligible,
                controlsVisible: widget.controlsVisible,
                playAndPauseOnTap: widget.playAndPauseOnTap,
                touchTapTogglesControls: widget.touchTapTogglesControls,
              );
              _playPauseTapEligible = false;
              _tapKind = null;
              if (action != DesktopControlsTapAction.none) {
                widget.onAction(action);
              }
            },
      onTapUp: widget.onTapUp,
      child: widget.child,
    );
  }
}

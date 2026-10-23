import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// Holding Esc / gamepad B this long leaves the disc session directly.
const Duration kDiscExitHoldDuration = Duration(seconds: 1);

/// The session control bar hides after this long without input.
const Duration kDiscSessionBarIdleDuration = Duration(seconds: 3);

/// Fraction of the surface height that counts as "the top of the screen":
/// hovering there reveals the bar, and on BD-J discs (no button geometry) a
/// tap there summons it.
const double kDiscSessionTopBandFraction = 0.1;

bool isInDiscSessionTopBand(Offset position, Size viewport) =>
    viewport.height > 0 &&
    position.dy <= viewport.height * kDiscSessionTopBandFraction;

/// Where a tap on the disc surface goes. Layer rule (handoff decision):
/// an open overlay only closes; a disc button belongs to the disc; only true
/// blank space toggles the session bar.
enum DiscSurfaceTapRoute {
  /// An overlay of ours (the session bar, a track panel) is open: this tap
  /// only closes it.
  dismissOverlay,

  /// The tap is known to be blank before asking the disc.
  toggleBar,

  /// Ask the disc; its hit result decides (see
  /// [resolveUnconsumedDiscClick]).
  forwardToDisc,

  /// Nothing to do (outside the picture, or the menu is still starting).
  ignore,
}

/// Step-0 finding (2026-10-24, docs/specs/2026-10-24-disc-interaction-handoff.md):
/// an HDMV click on blank space is reported as "not consumed" by the shipped
/// `discnav mouse-click` command, a click on a button as consumed. BD-J titles
/// expose no button geometry, so a BD-J tap is never inferred to be blank; the
/// top band (and a two-finger tap) summon the bar there instead.
DiscSurfaceTapRoute resolveDiscSurfaceTap({
  required bool overlayOpen,
  required bool insideVideo,
  required bool menuInteractive,
  required bool bdj,
  required bool inTopBand,
  required bool menuStarting,
}) {
  if (overlayOpen) return DiscSurfaceTapRoute.dismissOverlay;
  if (menuStarting) return DiscSurfaceTapRoute.ignore;
  if (bdj && inTopBand) return DiscSurfaceTapRoute.toggleBar;
  if (!insideVideo) {
    // Letterbox bars are never disc buttons; on HDMV they are plain blank.
    return bdj ? DiscSurfaceTapRoute.ignore : DiscSurfaceTapRoute.toggleBar;
  }
  if (menuInteractive) return DiscSurfaceTapRoute.forwardToDisc;
  // No interactive graphics on screen (first-play clip, still frame without
  // buttons): nothing can be hit. BD-J draws its own planes, so ask it anyway.
  return bdj
      ? DiscSurfaceTapRoute.forwardToDisc
      : DiscSurfaceTapRoute.toggleBar;
}

/// What an HDMV click the disc did not consume means.
enum DiscUnconsumedClickRoute {
  /// The disc's own popup menu is open over a title: blank closes it first.
  closeDiscPopup,

  /// Blank space on a top-level menu: toggle the session bar.
  showBar,
}

/// [discTitle] is libbluray's navigation title: 0 = top menu, 65535 = first
/// play, 1..N = titles. An interactive menu over a title is the popup menu.
/// BD-J never infers blank (returns null).
DiscUnconsumedClickRoute? resolveUnconsumedDiscClick({
  required bool bdj,
  required int discTitle,
}) {
  if (bdj) return null;
  if (discTitle > 0 && discTitle < 65535) {
    return DiscUnconsumedClickRoute.closeDiscPopup;
  }
  return DiscUnconsumedClickRoute.showBar;
}

/// Short Esc / Android back / gamepad B / iOS back swipe, after page layers.
enum DiscSessionBackRoute { showBar, exitSession }

DiscSessionBackRoute resolveDiscSessionBack({required bool barVisible}) =>
    barVisible
    ? DiscSessionBackRoute.exitSession
    : DiscSessionBackRoute.showBar;

/// Press-and-hold exit for Esc / gamepad B. A release before
/// [kDiscExitHoldDuration] is a short press; reaching it fires [onExit]
/// once and swallows the later release.
class DiscExitHold {
  DiscExitHold({required this.onExit, this.duration = kDiscExitHoldDuration});

  final VoidCallback onExit;
  final Duration duration;

  /// True while a hold is in progress (drives the ring).
  final ValueNotifier<bool> holding = ValueNotifier<bool>(false);
  Timer? _timer;
  bool _fired = false;
  Object? _source;

  bool get active => _source != null;

  /// Starts a hold for [source] (a key or button). A repeated press of the
  /// same source while held is ignored (key auto-repeat).
  void press(Object source) {
    if (_source != null) return;
    _source = source;
    _fired = false;
    holding.value = true;
    _timer = Timer(duration, () {
      _fired = true;
      holding.value = false;
      onExit();
    });
  }

  /// Ends the hold. Returns true when it was a short press the caller should
  /// now handle; false when the hold already exited, or [source] is not the
  /// one being held.
  bool release(Object source) {
    if (_source != source) return false;
    _source = null;
    _timer?.cancel();
    _timer = null;
    holding.value = false;
    return !_fired;
  }

  void cancel() {
    _source = null;
    _timer?.cancel();
    _timer = null;
    holding.value = false;
  }

  void dispose() {
    _timer?.cancel();
    holding.dispose();
  }
}

/// Ring that fills while Esc / B is held, centred on the screen.
class DiscExitHoldRing extends StatelessWidget {
  const DiscExitHoldRing({
    required this.holding,
    required this.color,
    this.duration = kDiscExitHoldDuration,
    super.key,
  });

  final ValueListenable<bool> holding;
  final Color color;
  final Duration duration;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: holding,
    builder: (BuildContext context, bool held, Widget? _) {
      if (!held) return const SizedBox.shrink();
      return IgnorePointer(
        child: Center(
          child: TweenAnimationBuilder<double>(
            key: const ValueKey<String>('disc-exit-hold-ring'),
            // The fill is the hold timer made visible, not decoration: it
            // keeps its real duration under reduced motion.
            tween: Tween<double>(begin: 0, end: 1),
            duration: duration,
            builder: (BuildContext context, double value, Widget? _) =>
                CustomPaint(
                  size: const Size.square(72),
                  painter: _HoldRingPainter(progress: value, color: color),
                ),
          ),
        ),
      );
    },
  );
}

class _HoldRingPainter extends CustomPainter {
  const _HoldRingPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = (Offset.zero & size).deflate(6);
    final Paint track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..color = color.withValues(alpha: 0.25);
    final Paint fill = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(rect, 0, math.pi * 2, false, track);
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * progress, false, fill);
  }

  @override
  bool shouldRepaint(_HoldRingPainter old) =>
      old.progress != progress || old.color != color;
}

/// Launch animation: the cover grows from where it was tapped to fill the
/// screen, then fades into the disc's own picture. Total ≤ 0.8 s
/// ([FushiMotion.long] + [FushiMotion.medium]); zero under reduced motion /
/// e-ink, where it renders nothing.
class DiscLaunchCoverTransition extends StatefulWidget {
  const DiscLaunchCoverTransition({
    required this.cover,
    this.origin,
    super.key,
  });

  final ImageProvider cover;

  /// Global rect of the card the session was started from; null = a centred
  /// card-sized rect.
  final Rect? origin;

  @override
  State<DiscLaunchCoverTransition> createState() =>
      _DiscLaunchCoverTransitionState();
}

class _DiscLaunchCoverTransitionState extends State<DiscLaunchCoverTransition>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  bool _done = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null || _done) return;
    final Duration grow = fushiMotionDuration(context, FushiMotion.long);
    final Duration fade = fushiMotionDuration(context, FushiMotion.medium);
    final Duration total = grow + fade;
    if (total == Duration.zero) {
      _done = true;
      return;
    }
    _controller = AnimationController(vsync: this, duration: total)
      ..addStatusListener((AnimationStatus status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() => _done = true);
        }
      })
      ..forward();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AnimationController? controller = _controller;
    if (_done || controller == null) return const SizedBox.shrink();
    final int growMs = FushiMotion.long.inMilliseconds;
    final int totalMs = growMs + FushiMotion.medium.inMilliseconds;
    final double split = growMs / totalMs;
    final Animation<double> grow = CurvedAnimation(
      parent: controller,
      curve: Interval(0, split, curve: Curves.easeOutCubic),
    );
    final Animation<double> fade = CurvedAnimation(
      parent: controller,
      curve: Interval(split, 1, curve: Curves.easeIn),
    );
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size size = constraints.biggest;
          final Rect full = Offset.zero & size;
          // The player page is a full-window route, so its local space is the
          // window's: a global card rect needs no further mapping.
          final Rect begin =
              widget.origin ??
              Rect.fromCenter(
                center: full.center,
                width: size.width * 0.3,
                height: size.height * 0.3,
              );
          return AnimatedBuilder(
            animation: controller,
            builder: (BuildContext context, Widget? child) {
              final Rect rect = Rect.lerp(begin, full, grow.value)!;
              return Opacity(
                opacity: 1 - fade.value,
                child: Stack(
                  children: <Widget>[
                    Positioned.fromRect(rect: rect, child: child!),
                  ],
                ),
              );
            },
            child: Image(
              key: const ValueKey<String>('disc-launch-cover'),
              image: widget.cover,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          );
        },
      ),
    );
  }
}

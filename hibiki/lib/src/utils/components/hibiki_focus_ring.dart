import 'package:flutter/material.dart';

/// App-level overlay that paints a high-contrast ring around the widget that
/// currently holds primary focus — but ONLY in keyboard/gamepad highlight mode
/// ([FocusHighlightMode.traditional]). In touch mode it draws nothing. This is
/// a single app-wide observability aid for gamepad navigation and automated
/// screenshots; it does not require per-widget changes.
///
/// Because it is the single app-wide observer of focus, it also keeps the
/// focused control visible: when focus lands off-screen (window resize,
/// autofocus, programmatic/gamepad focus) it scrolls the nearest scrollable so
/// the control — and therefore the ring — is brought into view ("把视角转过去").
/// A deliberate manual scroll that leaves focus behind is NOT yanked back; the
/// ring simply tracks the control to its new (possibly off-screen) position.
class HibikiFocusRing extends StatefulWidget {
  const HibikiFocusRing({super.key, required this.child});

  final Widget child;

  @override
  State<HibikiFocusRing> createState() => _HibikiFocusRingState();
}

class _HibikiFocusRingState extends State<HibikiFocusRing>
    with WidgetsBindingObserver {
  final FocusManager _fm = FocusManager.instance;

  // Cached focus rectangle, recomputed in a post-frame callback only. NEVER
  // read render geometry during build: the focused node's element can be
  // *inactive* mid-build (e.g. a route swap at startup), and findRenderObject()
  // asserts on inactive elements ("Cannot get renderObject of inactive
  // element"). On desktop the keyboard highlight mode is on from launch, so
  // that path runs immediately — which is why this only ever crashed there.
  Rect? _rect;
  bool _recomputeScheduled = false;
  bool _ensureVisibleScheduled = false;

  // The node we last scrolled into view. Distinguishes a real primary-focus
  // change (worth scrolling to) from the many other FocusManager notifications
  // and from a manual scroll (which must never trigger a scroll-back).
  FocusNode? _lastFocused;

  @override
  void initState() {
    super.initState();
    _fm.addListener(_onFocusManagerChange);
    _fm.addHighlightModeListener(_onHighlight);
    WidgetsBinding.instance.addObserver(this);
    _lastFocused = _fm.primaryFocus;
    _scheduleRecompute();
  }

  @override
  void dispose() {
    _fm.removeListener(_onFocusManagerChange);
    _fm.removeHighlightModeListener(_onHighlight);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onHighlight(FocusHighlightMode _) => _scheduleRecompute();

  void _onFocusManagerChange() {
    final FocusNode? current = _fm.primaryFocus;
    if (!identical(current, _lastFocused)) {
      _lastFocused = current;
      // Focus moved: bring it on-screen if a non-traversal path left it hidden.
      _scheduleEnsureVisible();
    }
    _scheduleRecompute();
  }

  // Window resize / inset change can reflow the focused control off-screen
  // without any focus change. Bring it back and refresh the ring geometry.
  // _ensureVisibleIfHidden is gated on traditional (keyboard/gamepad) highlight
  // mode, so a soft-keyboard inset change on touch devices is a no-op here; it
  // only scrolls when a hardware keyboard/gamepad is actually driving focus.
  @override
  void didChangeMetrics() {
    _scheduleEnsureVisible();
    _scheduleRecompute();
  }

  void _scheduleRecompute() {
    if (_recomputeScheduled || !mounted) return;
    _recomputeScheduled = true;
    // By post-frame time the element tree is finalized: every element is either
    // active (safe to query) or unmounted/defunct (caught by ctx.mounted).
    // Inactive elements no longer exist, so the geometry read cannot assert.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _recomputeScheduled = false;
        return;
      }
      final Rect? next = _computeFocusRect();
      if (next != _rect) {
        setState(() => _rect = next);
      }
      // Clear at the end so the "scheduled" window spans the whole read, not
      // just up to entry — independent of when focus changes are delivered.
      _recomputeScheduled = false;
    });
  }

  void _scheduleEnsureVisible() {
    // Only keyboard/gamepad mode follows focus; skip the wasted post-frame in
    // touch mode. Dedupe so a burst of focus/resize notifications schedules at
    // most one scroll check per frame.
    if (_ensureVisibleScheduled ||
        _fm.highlightMode != FocusHighlightMode.traditional) {
      return;
    }
    _ensureVisibleScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureVisibleScheduled = false;
      if (!mounted) return;
      _ensureVisibleIfHidden();
    });
  }

  // Scroll the focused control into view ONLY when it is not already fully
  // visible inside its nearest scrollable. Skipping the already-visible case
  // avoids a second, differently-aligned scroll on ordinary Tab traversal
  // (which Flutter already reveals) while still covering the off-screen paths
  // (resize, autofocus, programmatic/gamepad focus).
  void _ensureVisibleIfHidden() {
    if (_fm.highlightMode != FocusHighlightMode.traditional) return;
    final BuildContext? ctx = _fm.primaryFocus?.context;
    if (ctx == null || !ctx.mounted) return;
    final RenderObject? ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize || !ro.attached) return;
    final ScrollableState? scrollable = Scrollable.maybeOf(ctx);
    if (scrollable == null) return;
    final RenderObject? vro = scrollable.context.findRenderObject();
    if (vro is! RenderBox || !vro.hasSize || !vro.attached) return;

    final Rect widgetRect = ro.localToGlobal(Offset.zero) & ro.size;
    final Rect viewRect = vro.localToGlobal(Offset.zero) & vro.size;
    const double tol = 0.5;
    final bool fullyVisible = widgetRect.top >= viewRect.top - tol &&
        widgetRect.bottom <= viewRect.bottom + tol &&
        widgetRect.left >= viewRect.left - tol &&
        widgetRect.right <= viewRect.right + tol;
    if (fullyVisible) return;

    // Short animation: long enough to read as "the view followed focus", short
    // enough that it rarely collides with a manual scroll started right after.
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
    );
  }

  Rect? _computeFocusRect() {
    if (_fm.highlightMode != FocusHighlightMode.traditional) return null;
    final BuildContext? ctx = _fm.primaryFocus?.context;
    if (ctx == null || !ctx.mounted) return null;
    final RenderObject? ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize || !ro.attached) return null;
    final Offset topLeft = ro.localToGlobal(Offset.zero);
    return topLeft & ro.size;
  }

  @override
  Widget build(BuildContext context) {
    final Rect? rect = _rect;
    final Color color = Theme.of(context).colorScheme.primary;
    return Stack(
      children: <Widget>[
        // Track the focused control while any scrollable moves it (mouse wheel,
        // ensureVisible animation, parent scroll) so the ring never lags behind.
        // In touch mode the ring is hidden, so skip the per-scroll bookkeeping.
        NotificationListener<ScrollNotification>(
          onNotification: (_) {
            if (_fm.highlightMode == FocusHighlightMode.traditional) {
              _scheduleRecompute();
            }
            return false;
          },
          child: widget.child,
        ),
        if (rect != null)
          Positioned.fromRect(
            rect: rect.inflate(2),
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: color, width: 2.5),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

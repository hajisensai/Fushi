import 'package:flutter/material.dart';
import 'package:hibiki/src/focus/hibiki_focus_scroll.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

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

  // The UI scale (folded into MediaQuery.textScaler by HibikiAppUiScale) seen at
  // the last didChangeDependencies. Used to tell a geometry-changing scale
  // reflow (must reveal + recompute) apart from a theme-only dependency change
  // (must only recompute the ring, never scroll).
  TextScaler? _lastTextScaler;

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

  // Fires on ANY inherited dependency read in build() changing — that is both
  // the in-app UI scale (HibikiAppUiScale folds it into MediaQuery.textScaler,
  // read below) AND the theme (Theme.of in build()). We must distinguish them:
  //
  //  - A scale change reflows the whole subtree, moving the focused control,
  //    without any window-metrics/focus/scroll/highlight change — invisible to
  //    every other recompute trigger here, so the ring would stay pinned to the
  //    control's old position ("焦点不跟着动"). Treat it like a resize: reveal
  //    the control and recompute the ring geometry.
  //  - A theme change does NOT move geometry. Calling _scheduleEnsureVisible()
  //    for it would yank a focused control the user deliberately scrolled out of
  //    view back to center, breaking this widget's "manual scroll is not pulled
  //    back" contract (see the class doc). So a theme-only change must ONLY
  //    recompute (cheap, no scroll; also refreshes the ring colour).
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Read (and thereby depend on) the scale-driven textScaler. Keep this read:
    // it registers the MediaQuery.textScaler aspect dependency that delivers
    // scale changes here. Removing it silently brings back the original bug.
    final TextScaler textScaler = MediaQuery.textScalerOf(context);
    final bool scaleChanged =
        _lastTextScaler != null && textScaler != _lastTextScaler;
    _lastTextScaler = textScaler;
    if (scaleChanged) _scheduleEnsureVisible();
    _scheduleRecompute();
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
    HibikiFocusScroll.ensureVisibleIfHidden(ctx);
  }

  Rect? _computeFocusRect() {
    if (_fm.highlightMode != FocusHighlightMode.traditional) return null;
    final BuildContext? ctx = _fm.primaryFocus?.context;
    if (ctx == null || !ctx.mounted) return null;
    final RenderObject? ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize || !ro.attached) return null;
    final Offset topLeft = ro.localToGlobal(Offset.zero);
    final Rect rect = topLeft & ro.size;
    // Don't ring a (near) full-screen focusable: the ring would sit at/beyond the
    // window edge — clipped, and occluded by any overlaid chrome (e.g. a reader
    // bottom bar). Such a node draws its own inset focus indicator instead.
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return rect; // no view to size against — keep the ring
    final view = views.first;
    final double sw = view.physicalSize.width / view.devicePixelRatio;
    final double sh = view.physicalSize.height / view.devicePixelRatio;
    if (rect.width >= sw * 0.92 && rect.height >= sh * 0.92) return null;
    return rect;
  }

  @override
  Widget build(BuildContext context) {
    final Rect? rect = _rect;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
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
                  borderRadius: tokens.radii.chipRadius,
                  border: Border.all(color: color, width: 2.5),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

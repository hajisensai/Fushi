import 'package:flutter/material.dart';

/// App-level overlay that paints a high-contrast ring around the widget that
/// currently holds primary focus — but ONLY in keyboard/gamepad highlight mode
/// ([FocusHighlightMode.traditional]). In touch mode it draws nothing. This is
/// a single app-wide observability aid for gamepad navigation and automated
/// screenshots; it does not require per-widget changes.
class HibikiFocusRing extends StatefulWidget {
  const HibikiFocusRing({super.key, required this.child});

  final Widget child;

  @override
  State<HibikiFocusRing> createState() => _HibikiFocusRingState();
}

class _HibikiFocusRingState extends State<HibikiFocusRing> {
  final FocusManager _fm = FocusManager.instance;

  // Cached focus rectangle, recomputed in a post-frame callback only. NEVER
  // read render geometry during build: the focused node's element can be
  // *inactive* mid-build (e.g. a route swap at startup), and findRenderObject()
  // asserts on inactive elements ("Cannot get renderObject of inactive
  // element"). On desktop the keyboard highlight mode is on from launch, so
  // that path runs immediately — which is why this only ever crashed there.
  Rect? _rect;
  bool _recomputeScheduled = false;

  @override
  void initState() {
    super.initState();
    _fm.addListener(_scheduleRecompute);
    _fm.addHighlightModeListener(_onHighlight);
    _scheduleRecompute();
  }

  @override
  void dispose() {
    _fm.removeListener(_scheduleRecompute);
    _fm.removeHighlightModeListener(_onHighlight);
    super.dispose();
  }

  void _onHighlight(FocusHighlightMode _) => _scheduleRecompute();

  void _scheduleRecompute() {
    if (_recomputeScheduled || !mounted) return;
    _recomputeScheduled = true;
    // By post-frame time the element tree is finalized: every element is either
    // active (safe to query) or unmounted/defunct (caught by ctx.mounted).
    // Inactive elements no longer exist, so the geometry read cannot assert.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recomputeScheduled = false;
      if (!mounted) return;
      final Rect? next = _computeFocusRect();
      if (next != _rect) {
        setState(() => _rect = next);
      }
    });
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
        widget.child,
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

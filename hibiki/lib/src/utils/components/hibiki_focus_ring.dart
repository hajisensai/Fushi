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

  @override
  void initState() {
    super.initState();
    _fm.addListener(_onChange);
    _fm.addHighlightModeListener(_onHighlight);
  }

  @override
  void dispose() {
    _fm.removeListener(_onChange);
    _fm.removeHighlightModeListener(_onHighlight);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _onHighlight(FocusHighlightMode _) {
    if (mounted) setState(() {});
  }

  Rect? _focusRect() {
    if (_fm.highlightMode != FocusHighlightMode.traditional) return null;
    final FocusNode? node = _fm.primaryFocus;
    final BuildContext? ctx = node?.context;
    if (ctx == null) return null;
    final RenderObject? ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize || !ro.attached) return null;
    final Offset topLeft = ro.localToGlobal(Offset.zero);
    return topLeft & ro.size;
  }

  @override
  Widget build(BuildContext context) {
    final Rect? rect = _focusRect();
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

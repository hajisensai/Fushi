import 'package:flutter/material.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/utils.dart';

@visibleForTesting
class BookDragTarget extends StatefulWidget {
  const BookDragTarget({
    required this.bookId,
    required this.onTagDropped,
    required this.child,
    super.key,
  });

  /// Drag-target identity marker (EPUB bookKey String, SRT srtBookId int, or
  /// video bookUid String). Only used to distinguish targets; the drop action is
  /// carried by [onTagDropped], so the concrete type is irrelevant here.
  final Object bookId;
  final void Function(BookTagRow tag) onTagDropped;
  final Widget child;

  @override
  State<BookDragTarget> createState() => _BookDragTargetState();
}

class _BookDragTargetState extends State<BookDragTarget> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color hoverColor = tokens.surfaces.primary;
    return DragTarget<BookTagRow>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (DragTargetDetails<BookTagRow> details) {
        setState(() => _isHovering = false);
        widget.onTagDropped(details.data);
      },
      onMove: (_) {
        if (!_isHovering) setState(() => _isHovering = true);
      },
      onLeave: (_) {
        if (_isHovering) setState(() => _isHovering = false);
      },
      builder: (
        BuildContext context,
        List<BookTagRow?> candidateData,
        List<dynamic> rejectedData,
      ) {
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            widget.child,
            if (_isHovering)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: hoverColor.withValues(alpha: 0.2),
                    borderRadius: tokens.radii.cardRadius,
                    border: Border.all(
                      color: hoverColor,
                      width: tokens.spacing.gap / 4,
                    ),
                  ),
                  child: Center(
                    child: Icon(
                      Icons.add_circle_outline,
                      color: hoverColor,
                      size: tokens.spacing.gap * 4,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

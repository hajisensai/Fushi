import 'package:flutter/widgets.dart';

/// Replaces the regular media controls' Focus host while a disc menu is shown.
/// Attachment, rather than a native menu event, determines when the page can
/// reclaim this node: the old controls must have finished detaching first.
class BlurayDiscMenuFocusHost extends StatefulWidget {
  const BlurayDiscMenuFocusHost({
    required this.focusNode,
    required this.onAttached,
    required this.child,
    super.key,
  });

  final FocusNode focusNode;
  final ValueChanged<BuildContext> onAttached;
  final Widget child;

  @override
  State<BlurayDiscMenuFocusHost> createState() =>
      _BlurayDiscMenuFocusHostState();
}

class _BlurayDiscMenuFocusHostState extends State<BlurayDiscMenuFocusHost> {
  @override
  void initState() {
    super.initState();
    _notifyAfterAttachment();
  }

  @override
  void didUpdateWidget(covariant BlurayDiscMenuFocusHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.focusNode, oldWidget.focusNode)) {
      _notifyAfterAttachment();
    }
  }

  void _notifyAfterAttachment() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.focusNode.context != null) {
        widget.onAttached(context);
      }
    });
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    // The attachment callback applies PageFocusOwnership and current-route
    // policy. Framework autofocus would be a second, ungated owner that can
    // focus this underlying scope while a modal route is active.
    child: widget.child,
  );
}

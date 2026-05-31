import 'package:flutter/material.dart';

class HibikiFocusScroll {
  const HibikiFocusScroll._();

  static void ensureVisible(BuildContext context) {
    if (!context.mounted) return;
    final ScrollableState? scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return;
    Scrollable.ensureVisible(
      context,
      alignment: 0.5,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
    );
  }
}

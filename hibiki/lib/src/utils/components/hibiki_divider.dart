import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';

/// A standard theme divider for use across the applicaton.
class HibikiDivider extends StatelessWidget {
  /// Build a standard themed divider.
  const HibikiDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Divider(
        height: 1,
        thickness: isCupertinoPlatform(context) ? 0.33 : 0.5,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    );
  }
}

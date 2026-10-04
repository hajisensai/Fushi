import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';

/// A standard theme divider for use across the applicaton.
class FushiDivider extends StatelessWidget {
  /// Build a standard themed divider.
  const FushiDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: FushiDividerControl(
        height: 1,
        thickness: isCupertinoPlatform(context) ? 0.33 : 0.5,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    );
  }
}

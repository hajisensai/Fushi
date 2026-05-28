import 'package:flutter/material.dart';
import 'package:hibiki/src/pages/base_source_page.dart';
import 'package:hibiki/utils.dart';

/// The media page used for unimplemented sources.
class PlaceholderSourcePage extends BaseSourcePage {
  /// Create an instance of this page.
  const PlaceholderSourcePage({
    super.item,
    super.key,
  });

  @override
  BaseSourcePageState createState() => _PlaceholderSourcePage();
}

class _PlaceholderSourcePage extends BaseSourcePageState {
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) {
          final bool shouldPop = await onWillPop();
          if (shouldPop && context.mounted) {
            Navigator.of(context).pop();
          }
        }
      },
      child: Scaffold(
        body: Center(
          child: buildPlaceholder(),
        ),
      ),
    );
  }

  Widget buildPlaceholder() {
    return HibikiPlaceholderMessage(
      icon: Icons.construction_outlined,
      message: t.unimplemented_source,
    );
  }
}

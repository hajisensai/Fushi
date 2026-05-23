import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';


/// An option to show in a bottom sheet.
class HibikiBottomSheetOption {
  /// Defines an option in a bottom sheet.
  HibikiBottomSheetOption({
    required this.label,
    required this.icon,
    required this.action,
    this.active = false,
  });

  /// Label to display in the option.
  String label;

  /// Icon to display left of the label.
  IconData icon;

  /// Whether or not the option is available.
  bool active;

  /// Action to perform upon selecting the option.
  FutureOr<void> Function() action;
}

///
class HibikiBottomSheet extends ConsumerWidget {
  /// Initialise a bottom sheet.
  const HibikiBottomSheet({
    required this.options,
    this.scrollToExtent = true,
    super.key,
  });

  /// Options to show in the bottom sheet.
  final List<HibikiBottomSheetOption> options;

  /// Whether or not to scroll to bottom.
  final bool scrollToExtent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ScrollController scrollController = ScrollController();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients && scrollToExtent) {
        scrollController.jumpTo(
          scrollController.position.maxScrollExtent,
        );
      }
    });

    final cs = Theme.of(context).colorScheme;

    return ListView.builder(
      controller: scrollController,
      shrinkWrap: true,
      itemCount: options.length,
      itemBuilder: (context, i) {
        HibikiBottomSheetOption option = options[i];

        return ListTile(
          tileColor: cs.surface,
          dense: true,
          leading: Icon(
            option.icon,
            size: 20,
            color: option.active ? cs.error : cs.onSurfaceVariant,
          ),
          title: Text(
            option.label,
            maxLines: 1,
            style: TextStyle(
              color: option.active ? cs.error : cs.onSurface,
            ),
          ),
          onTap: () async {
            Navigator.of(context).pop();
            await option.action();
          },
        );
      },
    );
  }
}

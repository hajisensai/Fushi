import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

/// An option to show in a bottom sheet.
class HibikiBottomSheetOption {
  HibikiBottomSheetOption({
    required this.label,
    required this.icon,
    required this.action,
    this.active = false,
  });

  String label;
  IconData icon;
  bool active;
  FutureOr<void> Function() action;
}

class HibikiBottomSheet extends StatefulWidget {
  const HibikiBottomSheet({
    required this.options,
    this.scrollToExtent = true,
    super.key,
  });

  final List<HibikiBottomSheetOption> options;
  final bool scrollToExtent;

  @override
  State<HibikiBottomSheet> createState() => _HibikiBottomSheetState();
}

class _HibikiBottomSheetState extends State<HibikiBottomSheet> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    if (widget.scrollToExtent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(
            _scrollController.position.maxScrollExtent,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ListView.builder(
      controller: _scrollController,
      shrinkWrap: true,
      itemCount: widget.options.length,
      itemBuilder: (context, i) {
        final HibikiBottomSheetOption option = widget.options[i];

        return HibikiListItem(
          leading: Icon(
            option.icon,
            size: 20,
            color: option.active ? cs.error : cs.onSurfaceVariant,
          ),
          title: Text(
            option.label,
            maxLines: 1,
            style: TextStyle(color: option.active ? cs.error : cs.onSurface),
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

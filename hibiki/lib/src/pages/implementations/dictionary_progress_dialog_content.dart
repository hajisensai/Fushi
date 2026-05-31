import 'package:flutter/material.dart';
import 'package:hibiki/utils.dart';

class DictionaryProgressDialogContent extends StatelessWidget {
  const DictionaryProgressDialogContent({
    required this.header,
    required this.message,
    required this.progressColor,
    super.key,
  });

  final String header;
  final String message;
  final Color progressColor;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 156),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox.square(
            dimension: 36,
            child: Padding(
              padding: EdgeInsets.all(tokens.spacing.gap / 2),
              child: adaptiveIndicator(
                context: context,
                color: progressColor,
              ),
            ),
          ),
          SizedBox(width: tokens.spacing.gap / 2),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    header,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.metadata,
                  ),
                  SizedBox(height: tokens.spacing.gap / 4),
                  Text(
                    message,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

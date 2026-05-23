import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_widgets.dart';
import 'package:spaces/spaces.dart';

class DictionaryProgressDialogContent extends StatelessWidget {
  const DictionaryProgressDialogContent({
    required this.header,
    required this.message,
    required this.progressColor,
    this.headerStyle,
    super.key,
  });

  final String header;
  final String message;
  final Color progressColor;
  final TextStyle? headerStyle;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 156),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox.square(
            dimension: 36,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: adaptiveIndicator(
                context: context,
                color: progressColor,
              ),
            ),
          ),
          const Space.small(),
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
                    style: headerStyle,
                  ),
                  const Space.extraSmall(),
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

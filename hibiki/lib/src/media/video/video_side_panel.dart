import 'package:flutter/material.dart';

class VideoTranslucentSidePanel extends StatelessWidget {
  const VideoTranslucentSidePanel({
    required this.title,
    required this.child,
    this.onClose,
    this.alignment = Alignment.centerRight,
    this.width = 400,
    super.key,
  });

  final String title;
  final Widget child;
  final VoidCallback? onClose;
  final Alignment alignment;
  final double width;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final Size screen = MediaQuery.sizeOf(context);
    final double panelWidth =
        width.clamp(280.0, screen.width * 0.88).toDouble();

    return Align(
      alignment: alignment,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: SizedBox(
            width: panelWidth,
            child: Material(
              color: colorScheme.surface.withValues(alpha: 0.78),
              elevation: 8,
              clipBehavior: Clip.antiAlias,
              borderRadius: const BorderRadiusDirectional.horizontal(
                start: Radius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (onClose != null)
                          IconButton(
                            tooltip: MaterialLocalizations.of(context)
                                .closeButtonTooltip,
                            icon: const Icon(Icons.close),
                            onPressed: onClose,
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(child: child),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

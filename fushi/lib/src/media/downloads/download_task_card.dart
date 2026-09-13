import 'package:flutter/material.dart';
import 'package:fushi/utils.dart';

/// Shared compact summary and explicit disclosure for every download source.
class DownloadTaskCard extends StatefulWidget {
  const DownloadTaskCard({
    required this.taskId,
    required this.title,
    required this.status,
    required this.details,
    this.subtitle,
    this.progress,
    this.leading,
    super.key,
  });

  final String taskId;
  final String title;
  final String status;
  final String? subtitle;
  final double? progress;
  final Widget? leading;
  final Widget details;

  @override
  State<DownloadTaskCard> createState() => _DownloadTaskCardState();
}

class _DownloadTaskCardState extends State<DownloadTaskCard> {
  bool _expanded = false;
  bool _restored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_restored) {
      _expanded =
          PageStorage.maybeOf(context)?.readState(
                context,
                identifier: 'download-expanded-${widget.taskId}',
              )
              as bool? ??
          false;
      _restored = true;
    }
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    PageStorage.maybeOf(context)?.writeState(
      context,
      _expanded,
      identifier: 'download-expanded-${widget.taskId}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double? progress = widget.progress?.clamp(0, 1).toDouble();
    return FushiCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiListItem(
            key: ValueKey<String>('download-task-toggle-${widget.taskId}'),
            onTap: _toggle,
            leading: widget.leading,
            title: Text(widget.title),
            titleMaxLines: 2,
            subtitleMaxLines: 2,
            subtitle: Text(
              <String>[
                widget.status,
                if (progress != null) '${(progress * 100).round()}%',
                if (widget.subtitle?.isNotEmpty ?? false) widget.subtitle!,
              ].join(' · '),
            ),
            trailing: Semantics(
              expanded: _expanded,
              child: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
            ),
          ),
          if (progress != null && progress < 1)
            LinearProgressIndicator(value: progress, minHeight: 2),
          if (_expanded)
            Padding(
              padding: EdgeInsets.all(
                FushiDesignTokens.of(context).spacing.gap,
              ),
              child: DefaultTextStyle(
                style: theme.textTheme.bodySmall!,
                child: widget.details,
              ),
            ),
        ],
      ),
    );
  }
}

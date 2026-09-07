import 'package:flutter/material.dart';

/// Presentation metadata only. The source service remains the owner of actions.
enum DownloadTaskKind { video, novel, audiobook, game, manga }

enum DownloadTaskStatus {
  attention,
  active,
  queued,
  paused,
  completed,
  cancelled,
}

class DownloadTaskEntry {
  const DownloadTaskEntry({
    required this.id,
    required this.title,
    required this.kind,
    required this.status,
    required this.builder,
    this.onRetry,
    this.onClear,
    this.createdAt,
    this.progress,
    this.collectionKey,
    this.collectionTitle,
    this.searchTerms = const <String>[],
  });

  final VoidCallback? onRetry;
  final VoidCallback? onClear;

  final String id;
  final String title;
  final DownloadTaskKind kind;
  final DownloadTaskStatus status;
  final int? createdAt;
  final double? progress;
  final String? collectionKey;
  final String? collectionTitle;
  final List<String> searchTerms;
  final WidgetBuilder builder;
}

typedef DownloadTasksBuilder =
    Widget Function(BuildContext context, List<DownloadTaskEntry> tasks);

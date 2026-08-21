import 'package:flutter/material.dart';

import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart'
    show VideoDownloadSubtitlePolicy;
import 'package:fushi/src/pages/implementations/video_download_subscriptions_panel.dart'
    show videoDownloadSubscriptionFilterSummary;
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart'
    show MediaSourceRow, VideoDownloadSubscriptionRow;

/// 编辑订阅的**窄面**结果：只允许改这四样。来源身份（resourceProvider /
/// fingerprint / backend*）与版本规则（filterJson）刻意不可编辑——改它们会让
/// 服务的 job 复用判据失配（同一集再派一份新任务），要换版本请重新订阅
/// （身份稳定的 subscriptionId 会覆盖同一行，items 历史保留，参照
/// RSS-Subtitle-Manager 的「窄合并」纪律）。
class VideoDownloadSubscriptionEdit {
  const VideoDownloadSubscriptionEdit({
    required this.searchQuery,
    required this.startAfterEpisode,
    required this.subtitlePolicy,
    required this.targetSourceId,
  });

  final String searchQuery;
  final int? startAfterEpisode;
  final VideoDownloadSubtitlePolicy subtitlePolicy;
  final int targetSourceId;
}

/// 编辑订阅对话框（纯 UI：返回编辑结果，写库由宿主执行）。取消返回 null。
Future<VideoDownloadSubscriptionEdit?> showVideoDownloadSubscriptionEditDialog({
  required BuildContext context,
  required VideoDownloadSubscriptionRow subscription,
  required List<MediaSourceRow> sources,
}) =>
    showAppDialog<VideoDownloadSubscriptionEdit>(
      context: context,
      builder: (BuildContext _) => _SubscriptionEditDialog(
        subscription: subscription,
        sources: sources,
      ),
    );

class _SubscriptionEditDialog extends StatefulWidget {
  const _SubscriptionEditDialog({
    required this.subscription,
    required this.sources,
  });

  final VideoDownloadSubscriptionRow subscription;
  final List<MediaSourceRow> sources;

  @override
  State<_SubscriptionEditDialog> createState() =>
      _SubscriptionEditDialogState();
}

class _SubscriptionEditDialogState extends State<_SubscriptionEditDialog> {
  late final TextEditingController _queryController =
      TextEditingController(text: widget.subscription.searchQuery);
  late final TextEditingController _startAfterController =
      TextEditingController(
    text: widget.subscription.startAfterEpisode?.toString() ?? '',
  );
  late VideoDownloadSubtitlePolicy _subtitlePolicy = VideoDownloadSubtitlePolicy
          .values
          .asNameMap()[widget.subscription.subtitlePolicy] ??
      VideoDownloadSubtitlePolicy.bestEffort;
  late int? _sourceId = widget.sources.any(
    (MediaSourceRow source) => source.id == widget.subscription.targetSourceId,
  )
      ? widget.subscription.targetSourceId
      : widget.sources.firstOrNull?.id;

  @override
  void dispose() {
    _queryController.dispose();
    _startAfterController.dispose();
    super.dispose();
  }

  bool get _canSave =>
      _queryController.text.trim().isNotEmpty && _sourceId != null;

  void _save() {
    if (!_canSave) return;
    Navigator.of(context).pop(
      VideoDownloadSubscriptionEdit(
        searchQuery: _queryController.text.trim(),
        startAfterEpisode: int.tryParse(_startAfterController.text.trim()),
        subtitlePolicy: _subtitlePolicy,
        targetSourceId: _sourceId!,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<String> ruleParts = videoDownloadSubscriptionFilterSummary(
      widget.subscription.filterJson,
    );
    return AlertDialog(
      title: Text(t.subscription_edit_title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                widget.subscription.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              if (ruleParts.isNotEmpty) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final String part in ruleParts)
                      FushiTagChip(
                        label: part,
                        tone: FushiTagChipTone.surface,
                      ),
                  ],
                ),
              ],
              SizedBox(height: tokens.spacing.gap / 2),
              Text(
                t.subscription_edit_rule_hint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              SizedBox(height: tokens.spacing.card),
              TextField(
                key: const ValueKey<String>('subscription-edit-query'),
                controller: _queryController,
                decoration: InputDecoration(
                  labelText: t.video_jimaku_query,
                ),
                maxLines: 1,
                onChanged: (_) => setState(() {}),
              ),
              SizedBox(height: tokens.spacing.gap),
              TextField(
                key: const ValueKey<String>('subscription-edit-start-after'),
                controller: _startAfterController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t.video_jimaku_episode,
                  helperText: t.download_subscription_start_episode(
                    episode: _startAfterController.text.trim().isEmpty
                        ? '1'
                        : _startAfterController.text.trim(),
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              SizedBox(height: tokens.spacing.gap),
              DropdownButtonFormField<VideoDownloadSubtitlePolicy>(
                key: const ValueKey<String>('subscription-edit-subtitle'),
                initialValue: _subtitlePolicy,
                decoration: InputDecoration(
                  labelText: t.anime_download_include_subs,
                ),
                items: <DropdownMenuItem<VideoDownloadSubtitlePolicy>>[
                  DropdownMenuItem<VideoDownloadSubtitlePolicy>(
                    value: VideoDownloadSubtitlePolicy.none,
                    child: Text(t.anime_download_no_subs),
                  ),
                  DropdownMenuItem<VideoDownloadSubtitlePolicy>(
                    value: VideoDownloadSubtitlePolicy.bestEffort,
                    child: Text(t.anime_download_include_subs),
                  ),
                  DropdownMenuItem<VideoDownloadSubtitlePolicy>(
                    value: VideoDownloadSubtitlePolicy.required,
                    child: Text(
                      '${t.anime_download_include_subs} · '
                      '${t.video_control_reject_required}',
                    ),
                  ),
                ],
                onChanged: (VideoDownloadSubtitlePolicy? value) {
                  if (value != null) setState(() => _subtitlePolicy = value);
                },
              ),
              SizedBox(height: tokens.spacing.gap),
              DropdownButtonFormField<int>(
                key: const ValueKey<String>('subscription-edit-source'),
                initialValue: _sourceId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: t.video_download_target_source_title,
                ),
                items: <DropdownMenuItem<int>>[
                  for (final MediaSourceRow source in widget.sources)
                    DropdownMenuItem<int>(
                      value: source.id,
                      child: Text(
                        source.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (int? value) => setState(() => _sourceId = value),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_cancel),
        ),
        FilledButton(
          key: const ValueKey<String>('subscription-edit-save'),
          onPressed: _canSave ? _save : null,
          child: Text(t.dialog_done),
        ),
      ],
    );
  }
}

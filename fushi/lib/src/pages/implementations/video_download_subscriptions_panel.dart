import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        FushiDatabase,
        VideoDownloadSubscriptionRow,
        VideoDownloadSubscriptionsCompanion;

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/utils.dart';

typedef VideoDownloadSubscriptionAction = Future<void> Function(
  VideoDownloadSubscriptionRow subscription,
);

typedef VideoDownloadSubscriptionToggle = Future<void> Function(
  VideoDownloadSubscriptionRow subscription,
  bool enabled,
);

/// Schema-v78 订阅真相源的管理面板。旧 JSON 只由一次性 importer 读取，页面不再
/// 直接管理它，避免用户在两套互不一致的订阅状态之间切换。
class VideoDownloadSubscriptionsPanel extends ConsumerStatefulWidget {
  const VideoDownloadSubscriptionsPanel({super.key});

  @override
  ConsumerState<VideoDownloadSubscriptionsPanel> createState() =>
      _VideoDownloadSubscriptionsPanelState();
}

class _VideoDownloadSubscriptionsPanelState
    extends ConsumerState<VideoDownloadSubscriptionsPanel> {
  bool _checkingAll = false;

  Future<void> _setEnabled(
    VideoDownloadSubscriptionRow subscription,
    bool enabled,
  ) async {
    final AppModel appModel = ref.read(appProvider);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await appModel.database.updateVideoDownloadSubscription(
      subscription.subscriptionId,
      VideoDownloadSubscriptionsCompanion(
        enabled: Value<bool>(enabled),
        nextCheckAt: enabled ? Value<int?>(now) : const Value<int?>.absent(),
        updatedAt: Value<int>(now),
      ),
    );
    if (enabled) {
      await appModel.videoDownloadSubscriptionService?.checkNow();
    }
  }

  Future<void> _checkOne(
    VideoDownloadSubscriptionRow subscription,
  ) async {
    if (!subscription.enabled) return;
    final AppModel appModel = ref.read(appProvider);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await appModel.database.updateVideoDownloadSubscription(
      subscription.subscriptionId,
      VideoDownloadSubscriptionsCompanion(
        nextCheckAt: Value<int?>(now),
        updatedAt: Value<int>(now),
      ),
    );
    await appModel.videoDownloadSubscriptionService?.checkNow();
  }

  Future<void> _checkAll(
    List<VideoDownloadSubscriptionRow> subscriptions,
  ) async {
    if (_checkingAll) return;
    setState(() => _checkingAll = true);
    try {
      final AppModel appModel = ref.read(appProvider);
      final int now = DateTime.now().millisecondsSinceEpoch;
      for (final VideoDownloadSubscriptionRow subscription
          in subscriptions.where(
        (VideoDownloadSubscriptionRow row) => row.enabled,
      )) {
        await appModel.database.updateVideoDownloadSubscription(
          subscription.subscriptionId,
          VideoDownloadSubscriptionsCompanion(
            nextCheckAt: Value<int?>(now),
            updatedAt: Value<int>(now),
          ),
        );
      }
      await appModel.videoDownloadSubscriptionService?.checkNow();
    } finally {
      if (mounted) setState(() => _checkingAll = false);
    }
  }

  Future<void> _delete(
    VideoDownloadSubscriptionRow subscription,
  ) async {
    final bool confirmed = await showAppDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog(
            title: Text(t.download_subscription_delete),
            content: Text(
              t.download_subscription_delete_confirm(
                title: subscription.title,
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(t.dialog_cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(t.dialog_delete),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await ref
        .read(appProvider)
        .database
        .deleteVideoDownloadSubscription(subscription.subscriptionId);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDatabase database = ref.read(appProvider).database;
    return StreamBuilder<List<VideoDownloadSubscriptionRow>>(
      stream: database.watchVideoDownloadSubscriptions(),
      builder: (
        BuildContext context,
        AsyncSnapshot<List<VideoDownloadSubscriptionRow>> snapshot,
      ) {
        if (snapshot.hasError) {
          return _VideoDownloadSubscriptionMessage(
            icon: Icons.error_outline,
            title: t.error_load_failed,
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final List<VideoDownloadSubscriptionRow> subscriptions = snapshot.data!;
        return VideoDownloadSubscriptionsView(
          subscriptions: subscriptions,
          checkingAll: _checkingAll,
          onCheckAll: () => _checkAll(subscriptions),
          onToggle: _setEnabled,
          onCheck: _checkOne,
          onDelete: _delete,
        );
      },
    );
  }
}

/// 可注入动作的纯 UI，方便窄屏和交互测试不依赖完整 [AppModel]。
class VideoDownloadSubscriptionsView extends StatefulWidget {
  const VideoDownloadSubscriptionsView({
    required this.subscriptions,
    required this.checkingAll,
    required this.onCheckAll,
    required this.onToggle,
    required this.onCheck,
    required this.onDelete,
    super.key,
  });

  final List<VideoDownloadSubscriptionRow> subscriptions;
  final bool checkingAll;
  final Future<void> Function() onCheckAll;
  final VideoDownloadSubscriptionToggle onToggle;
  final VideoDownloadSubscriptionAction onCheck;
  final VideoDownloadSubscriptionAction onDelete;

  @override
  State<VideoDownloadSubscriptionsView> createState() =>
      _VideoDownloadSubscriptionsViewState();
}

class _VideoDownloadSubscriptionsViewState
    extends State<VideoDownloadSubscriptionsView> {
  final Set<String> _busy = <String>{};

  Future<void> _run(
    VideoDownloadSubscriptionRow subscription,
    Future<void> Function() action,
  ) async {
    if (_busy.contains(subscription.subscriptionId)) return;
    setState(() => _busy.add(subscription.subscriptionId));
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy.remove(subscription.subscriptionId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: FushiCard(
            key: const ValueKey<String>('video-subscriptions-header'),
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: <Widget>[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Text(
                    t.download_subscription_running_hint,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                FilledButton.tonalIcon(
                  key: const ValueKey<String>(
                    'video-subscription-check-all',
                  ),
                  onPressed: widget.checkingAll ||
                          !widget.subscriptions.any(
                            (VideoDownloadSubscriptionRow row) => row.enabled,
                          )
                      ? null
                      : widget.onCheckAll,
                  icon: widget.checkingAll
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  label: Text(t.download_subscription_check_all),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: widget.subscriptions.isEmpty
              ? _VideoDownloadSubscriptionMessage(
                  icon: Icons.subscriptions_outlined,
                  title: t.download_subscription_empty_title,
                  body: t.download_subscription_empty_body,
                )
              : RefreshIndicator(
                  onRefresh: widget.onCheckAll,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: widget.subscriptions.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (BuildContext context, int index) {
                      final VideoDownloadSubscriptionRow subscription =
                          widget.subscriptions[index];
                      final bool busy =
                          _busy.contains(subscription.subscriptionId);
                      return _VideoDownloadSubscriptionCard(
                        key: ValueKey<String>(
                          'video-subscription-card-${subscription.subscriptionId}',
                        ),
                        subscription: subscription,
                        busy: busy,
                        onToggle: (bool enabled) => _run(
                          subscription,
                          () => widget.onToggle(subscription, enabled),
                        ),
                        onCheck: subscription.enabled
                            ? () => _run(
                                  subscription,
                                  () => widget.onCheck(subscription),
                                )
                            : null,
                        onDelete: () => _run(
                          subscription,
                          () => widget.onDelete(subscription),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _VideoDownloadSubscriptionCard extends StatelessWidget {
  const _VideoDownloadSubscriptionCard({
    super.key,
    required this.subscription,
    required this.busy,
    required this.onToggle,
    required this.onCheck,
    required this.onDelete,
  });

  final VideoDownloadSubscriptionRow subscription;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final VoidCallback? onCheck;
  final VoidCallback onDelete;

  String _formatTime(int? milliseconds) {
    if (milliseconds == null) return t.download_subscription_never_checked;
    return FushiTimeFormat.dateHourMinute(
      DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<String> strictParts =
        videoDownloadSubscriptionFilterSummary(subscription.filterJson);
    final String mediaLabel = subscription.mediaKind == 'movie'
        ? t.collection_relation_movie
        : t.series;
    return FushiCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                subscription.enabled
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
                color: subscription.enabled
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      subscription.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      <String>[
                        mediaLabel,
                        subscription.resourceProvider,
                        subscription.mode,
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Switch.adaptive(
                key: ValueKey<String>(
                  'video-subscription-toggle-${subscription.subscriptionId}',
                ),
                value: subscription.enabled,
                onChanged: busy ? null : onToggle,
              ),
            ],
          ),
          if (strictParts.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: strictParts
                  .map(
                    (String part) => FushiTagChip(
                      label: part,
                      tone: FushiTagChipTone.surface,
                    ),
                  )
                  .toList(growable: false),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            t.download_subscription_last_checked(
              time: _formatTime(subscription.lastCheckedAt),
            ),
            style: theme.textTheme.bodySmall,
          ),
          if (subscription.startAfterEpisode != null)
            Text(
              t.download_subscription_start_episode(
                episode: subscription.startAfterEpisode!,
              ),
              style: theme.textTheme.bodySmall,
            ),
          if (subscription.lastError?.trim().isNotEmpty ?? false) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              subscription.lastError!.trim(),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: <Widget>[
                FushiIconButton(
                  key: ValueKey<String>(
                    'video-subscription-check-${subscription.subscriptionId}',
                  ),
                  tooltip: t.download_subscription_check_now,
                  icon: Icons.refresh,
                  onTap: busy ? null : onCheck,
                ),
                FushiIconButton(
                  key: ValueKey<String>(
                    'video-subscription-delete-${subscription.subscriptionId}',
                  ),
                  tooltip: t.download_subscription_delete,
                  icon: Icons.delete_outline,
                  onTap: busy ? null : onDelete,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoDownloadSubscriptionMessage extends StatelessWidget {
  const _VideoDownloadSubscriptionMessage({
    required this.icon,
    required this.title,
    this.body,
  });

  final IconData icon;
  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 44, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            if (body != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                body!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 将严格规则按稳定顺序转成紧凑摘要；未知字段不展示，避免未来凭据字段被误带入 UI。
List<String> videoDownloadSubscriptionFilterSummary(String rawJson) {
  try {
    final Object? decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, Object?>) return const <String>[];
    final List<String> result = <String>[];
    for (final String key in <String>[
      'releaseGroup',
      'resolution',
      'quality',
      'source',
      'codec',
      'language',
      'category',
    ]) {
      final Object? value = decoded[key];
      if (value is String && value.trim().isNotEmpty) {
        result.add(value.trim());
      }
    }
    final Object? languages = decoded['languages'];
    if (languages is List<Object?>) {
      result.addAll(
        languages.whereType<String>().map((String value) => value.trim()).where(
              (String value) => value.isNotEmpty,
            ),
      );
    }
    final Object? trusted = decoded['trusted'] ?? decoded['trustedOnly'];
    if (trusted is bool) {
      result.add(
        trusted
            ? t.anime_download_trusted
            : '${t.anime_download_trusted}: false',
      );
    }
    return result.toSet().toList(growable: false);
  } on FormatException {
    return const <String>[];
  }
}

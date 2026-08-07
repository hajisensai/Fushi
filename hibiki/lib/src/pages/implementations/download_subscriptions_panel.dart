import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/torrent/anime_download_subscription.dart';
import 'package:fushi/src/media/video/jimaku_client.dart'
    show jimakuLanguageLabel;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/fushi_page_placeholders.dart';
import 'package:fushi/utils.dart';

class DownloadSubscriptionsPanel extends ConsumerStatefulWidget {
  const DownloadSubscriptionsPanel({super.key});

  @override
  ConsumerState<DownloadSubscriptionsPanel> createState() =>
      _DownloadSubscriptionsPanelState();
}

class _DownloadSubscriptionsPanelState
    extends ConsumerState<DownloadSubscriptionsPanel>
    with FushiPagePlaceholders<DownloadSubscriptionsPanel> {
  AnimeDownloadSubscriptionStore? _store;
  List<AnimeDownloadSubscription> _subscriptions =
      const <AnimeDownloadSubscription>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _store = ref.read(appProvider).animeDownloadSubscriptionStore;
    _store?.revision.addListener(_onStoreChanged);
    unawaited(_reload());
  }

  @override
  void dispose() {
    _store?.revision.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() => unawaited(_reload());

  Future<void> _reload() async {
    final AnimeDownloadSubscriptionStore? store =
        _store ?? ref.read(appProvider).animeDownloadSubscriptionStore;
    if (store == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (!identical(_store, store)) {
      _store?.revision.removeListener(_onStoreChanged);
      _store = store;
      store.revision.addListener(_onStoreChanged);
    }
    final List<AnimeDownloadSubscription> subscriptions = await store.loadAll();
    if (!mounted) return;
    setState(() {
      _subscriptions = subscriptions;
      _loading = false;
    });
  }

  Future<void> _checkAll() async {
    await ref.read(appProvider).animeDownloadSubscriptionService?.checkAll();
    await _reload();
  }

  Future<void> _checkOne(AnimeDownloadSubscription subscription) async {
    await ref
        .read(appProvider)
        .animeDownloadSubscriptionService
        ?.checkSubscription(subscription.id);
    await _reload();
  }

  Future<void> _setEnabled(
    AnimeDownloadSubscription subscription,
    bool enabled,
  ) async {
    await ref
        .read(appProvider)
        .animeDownloadSubscriptionService
        ?.setEnabled(subscription.id, enabled);
    await _reload();
  }

  Future<void> _delete(AnimeDownloadSubscription subscription) async {
    final bool confirmed = await showAppDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog(
            title: Text(t.download_subscription_delete),
            content: Text(
              t.download_subscription_delete_confirm(
                title: subscription.seriesTitle,
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
        .animeDownloadSubscriptionService
        ?.delete(subscription.id);
    await _reload();
  }

  String _formatTime(int? milliseconds) {
    if (milliseconds == null) return t.download_subscription_never_checked;
    final DateTime value =
        DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
    return FushiTimeFormat.dateHourMinute(value);
  }

  @override
  Widget build(BuildContext context) {
    final AnimeDownloadSubscriptionService? service =
        ref.read(appProvider).animeDownloadSubscriptionService;
    if (_loading) return buildLoading();
    if (service == null) {
      return Center(child: Text(t.anime_download_store_unavailable));
    }
    return ValueListenableBuilder<bool>(
      valueListenable: service.checking,
      builder: (BuildContext context, bool checking, Widget? child) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildHeader(context, checking),
            Expanded(
              child: _subscriptions.isEmpty
                  ? _buildEmptyState(context)
                  : RefreshIndicator(
                      onRefresh: _checkAll,
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        itemCount: _subscriptions.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (BuildContext context, int index) =>
                            _buildSubscriptionCard(
                          context,
                          _subscriptions[index],
                          checking,
                        ),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, bool checking) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: FushiCard(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.schedule_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    t.download_subscription_running_hint,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: checking ? null : _checkAll,
                  icon: checking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  label: Text(t.download_subscription_check_all),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: <Widget>[
        const SizedBox(height: 72),
        Icon(
          Icons.subscriptions_outlined,
          size: 48,
          color: theme.colorScheme.outline,
        ),
        const SizedBox(height: 16),
        Text(
          t.download_subscription_empty_title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          t.download_subscription_empty_body,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.outline),
        ),
      ],
    );
  }

  Widget _buildSubscriptionCard(
    BuildContext context,
    AnimeDownloadSubscription subscription,
    bool checking,
  ) {
    final ThemeData theme = Theme.of(context);
    final List<String> details = <String>[
      subscription.releaseGroup,
      if (subscription.resolution?.isNotEmpty ?? false)
        subscription.resolution!,
      if (subscription.jimakuEntryName?.isNotEmpty ?? false)
        '${t.video_jimaku_source}: ${subscription.jimakuEntryName}'
            '${subscription.jimakuLanguage == null ? '' : ' · '
                '${jimakuLanguageLabel(subscription.jimakuLanguage!)}'}',
      t.download_subscription_after_episode(
        episode: subscription.startAfterEpisode,
      ),
    ];
    final int? latestEpisode = subscription.processedEpisodes.isEmpty
        ? null
        : subscription.processedEpisodes.reduce(
            (int a, int b) => a > b ? a : b,
          );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: FushiCard(
          padding: EdgeInsets.zero,
          child: FushiListItem(
            subtitleMaxLines: 4,
            // BUG-1184：标题是番剧名，右侧 trailing 挂着开关 + 刷新 + 删除（≈150px
            // 不可压缩），窄屏上留给番剧名的宽度只剩几十像素。行高自由，放宽到两行。
            titleMaxLines: 2,
            leading: Icon(
              subscription.enabled
                  ? Icons.notifications_active_outlined
                  : Icons.notifications_off_outlined,
              color: subscription.enabled
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            title: Text(subscription.seriesTitle),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const SizedBox(height: 4),
                Text(details.join(' · ')),
                Text(
                  t.download_subscription_last_checked(
                    time: _formatTime(subscription.lastCheckedAtMs),
                  ),
                  style: theme.textTheme.bodySmall,
                ),
                if (latestEpisode != null)
                  Text(
                    t.download_subscription_latest_episode(
                      episode: latestEpisode,
                    ),
                    style: theme.textTheme.bodySmall,
                  ),
                if (subscription.lastError?.isNotEmpty ?? false)
                  Text(
                    subscription.lastError!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Switch.adaptive(
                  value: subscription.enabled,
                  onChanged: checking
                      ? null
                      : (bool value) => _setEnabled(subscription, value),
                ),
                FushiIconButton(
                  tooltip: t.download_subscription_check_now,
                  icon: Icons.refresh,
                  onTap: checking ? null : () => _checkOne(subscription),
                ),
                FushiIconButton(
                  tooltip: t.download_subscription_delete,
                  icon: Icons.delete_outline,
                  onTap: () => _delete(subscription),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

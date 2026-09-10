/// 下载页「订阅」tab 顶部的 host 订阅段：列出每台宣告 `subscriptions.supported`
/// 的已配对 host 上的订阅，可启停 / 立即检查 / 删除。订阅本身在 host 上跑，
/// 这里只是远程遥控 + 轮询快照（15 s），与本地订阅列表并排、互不混淆。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/sync/interconnect_subscription_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/utils.dart';

class RemoteSubscriptionsSection extends ConsumerStatefulWidget {
  const RemoteSubscriptionsSection({super.key});

  @override
  ConsumerState<RemoteSubscriptionsSection> createState() =>
      _RemoteSubscriptionsSectionState();
}

class _RemoteSubscriptionsSectionState
    extends ConsumerState<RemoteSubscriptionsSection> {
  InterconnectSubscriptionClient? _client;
  List<HostSubscriptionTarget> _targets = const <HostSubscriptionTarget>[];
  final Map<String, List<HostSubscription>> _byHost =
      <String, List<HostSubscription>>{};
  final Set<String> _busy = <String>{};
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _probe() async {
    final AppModel appModel = ref.read(appProvider);
    final InterconnectSubscriptionClient client =
        _client ??= InterconnectSubscriptionClient(
      repo: SyncRepository(appModel.database),
    );
    final List<HostSubscriptionTarget> targets = await client.probeAll();
    if (!mounted) return;
    setState(() => _targets = targets);
    if (targets.isEmpty) return;
    await _refresh();
    _poll ??= Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_refresh()),
    );
  }

  Future<void> _refresh() async {
    final InterconnectSubscriptionClient? client = _client;
    if (client == null) return;
    for (final HostSubscriptionTarget target in _targets) {
      try {
        final List<HostSubscription> rows = await client.list(target);
        if (!mounted) return;
        setState(() => _byHost[target.baseUrl] = rows);
      } catch (_) {
        // host 暂时不可达：保留上一份快照，下轮再试。
      }
    }
  }

  Future<void> _action(
    HostSubscriptionTarget target,
    HostSubscription sub,
    Future<void> Function(InterconnectSubscriptionClient client) body,
  ) async {
    final InterconnectSubscriptionClient? client = _client;
    if (client == null || _busy.contains(sub.subscriptionId)) return;
    setState(() => _busy.add(sub.subscriptionId));
    try {
      await body(client);
      await _refresh();
    } on HostSubscriptionException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.detail ?? error.code)),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(sub.subscriptionId));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_targets.isEmpty) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final HostSubscriptionTarget target in _targets)
            FushiCard(
              key: ValueKey<String>('remote-subscriptions-${target.baseUrl}'),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    t.subscription_remote_section_title(device: target.label),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  if ((_byHost[target.baseUrl] ?? const <HostSubscription>[])
                      .isEmpty)
                    Text(
                      t.subscription_remote_empty,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  else
                    for (final HostSubscription sub in _byHost[target.baseUrl]!)
                      _row(context, target, sub),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    HostSubscriptionTarget target,
    HostSubscription sub,
  ) {
    final ThemeData theme = Theme.of(context);
    final bool busy = _busy.contains(sub.subscriptionId);
    final String counts = sub.itemCounts.entries
        .map((MapEntry<String, int> e) => '${e.key} ${e.value}')
        .join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  sub.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  <String>[
                    sub.resourceProvider,
                    sub.mode,
                    if (counts.isNotEmpty) counts,
                    if (sub.lastError != null) sub.lastError!,
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: sub.lastError != null
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey<String>(
                'remote-subscription-check-${sub.subscriptionId}'),
            tooltip: t.download_subscription_check_all,
            onPressed: busy
                ? null
                : () => _action(
                      target,
                      sub,
                      (InterconnectSubscriptionClient c) =>
                          c.checkNow(target, sub.subscriptionId),
                    ),
            icon: const Icon(Icons.refresh, size: 18),
          ),
          IconButton(
            key: ValueKey<String>(
                'remote-subscription-delete-${sub.subscriptionId}'),
            tooltip: t.download_subscription_delete,
            onPressed: busy
                ? null
                : () => _action(
                      target,
                      sub,
                      (InterconnectSubscriptionClient c) =>
                          c.delete(target, sub.subscriptionId),
                    ),
            icon: const Icon(Icons.delete_outline, size: 18),
          ),
          Switch.adaptive(
            key: ValueKey<String>(
                'remote-subscription-toggle-${sub.subscriptionId}'),
            value: sub.enabled,
            onChanged: busy
                ? null
                : (bool value) => _action(
                      target,
                      sub,
                      (InterconnectSubscriptionClient c) =>
                          c.setEnabled(target, sub.subscriptionId, value),
                    ),
          ),
        ],
      ),
    );
  }
}

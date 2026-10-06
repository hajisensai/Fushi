import 'package:flutter/material.dart';
import 'package:fushi_engine/media/torrent/torrent_network_diagnosis.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

/// BUG-2950：会话级网络问题对应的用户文案；[TorrentNetworkIssue.none] 返回 null。
String? torrentNetworkIssueMessage(TorrentNetworkIssue issue) {
  return switch (issue) {
    TorrentNetworkIssue.none => null,
    TorrentNetworkIssue.fakeIpUdpBlocked =>
      t.download_network_fake_ip_udp_blocked,
    TorrentNetworkIssue.dhtUnreachable => t.download_network_dht_unreachable,
  };
}

/// BUG-2950：内置 torrent 引擎网络异常的警告条（下载页任务区、种子详情网络区共用）。
///
/// [TorrentNetworkIssue.none] 时不占任何高度；其余情况照诊断结论展示原因与
/// 用户能照着做的处理办法——任务 0 peer 时不再让用户猜是种子死了还是网络被掐。
class TorrentNetworkIssueBanner extends StatelessWidget {
  const TorrentNetworkIssueBanner({
    required this.issue,
    this.margin = EdgeInsets.zero,
    super.key,
  });

  final TorrentNetworkIssue issue;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final String? message = torrentNetworkIssueMessage(issue);
    if (message == null) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final bool eink = isEinkTheme(context);
    // 卡片底色 / 圆角 / eink 描边走共享 FushiCard（MD3 令牌），本组件不再自定。
    return FushiCard(
      key: ValueKey<String>('torrent-network-issue-${issue.name}'),
      margin: margin,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: eink
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

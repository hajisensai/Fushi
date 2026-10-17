import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/interconnect_p2p_app.dart';
import 'package:fushi_engine/sync/interconnect_p2p.dart';

/// 已配对 host 的 `p2p://` 地址行下方：当前隧道路径（直连 / 中继 + RTT），
/// 持续走中继时说明原因与处理办法（docs/specs/2026-09-28-interconnect-remote-reach.md §9）。
///
/// 没有 P2P 运行时（原生库不可用 / 未建过隧道）或尚未连上时什么都不画。
class InterconnectP2pPathBadge extends StatefulWidget {
  const InterconnectP2pPathBadge({super.key, required this.url});

  /// `p2p://<nodeId>…` 地址。
  final String url;

  /// 轮询间隔。状态读取是一次同步 FFI 调用，开销可以忽略。
  static const Duration pollInterval = Duration(seconds: 3);

  @override
  State<InterconnectP2pPathBadge> createState() =>
      _InterconnectP2pPathBadgeState();
}

class _InterconnectP2pPathBadgeState extends State<InterconnectP2pPathBadge> {
  final InterconnectP2pPathTracker _tracker = InterconnectP2pPathTracker();
  Timer? _timer;
  FushiP2pConnStatus? _status;
  bool _relayOnly = false;

  @override
  void initState() {
    super.initState();
    _poll();
    // 没有运行时就不起定时器：测试与不支持 P2P 的平台上零开销。
    if (currentAppInterconnectP2pRuntime != null) {
      _timer = Timer.periodic(
        InterconnectP2pPathBadge.pollInterval,
        (_) => _poll(),
      );
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _poll() {
    final String? nodeId = parseInterconnectP2pUrl(widget.url)?.nodeId;
    final InterconnectP2pNode? node = currentAppInterconnectP2pRuntime?.current;
    final FushiP2pConnStatus? status = (nodeId == null || node == null)
        ? null
        : node.status(nodeId);
    final bool relayOnly =
        status != null && _tracker.observe(status, DateTime.now());
    if (!mounted) return;
    setState(() {
      _status = status;
      _relayOnly = relayOnly;
    });
  }

  @override
  Widget build(BuildContext context) {
    final FushiP2pConnStatus? status = _status;
    if (status == null || !status.connected) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final String rtt = status.rttMs?.round().toString() ?? '?';
    final bool relay = status.path == FushiP2pPathKind.relay;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          relay
              ? t.sync_p2p_path_relay(rtt: rtt)
              : t.sync_p2p_path_direct(rtt: rtt),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (_relayOnly)
          Text(
            t.sync_p2p_relay_only_hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.tertiary,
            ),
          ),
      ],
    );
  }
}

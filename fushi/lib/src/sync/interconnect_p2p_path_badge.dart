import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/interconnect_p2p_app.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
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
  InterconnectP2pPathTracker _tracker = InterconnectP2pPathTracker();
  Timer? _timer;
  String? _nodeId;
  FushiP2pConnStatus? _status;
  bool _relayOnly = false;

  /// 上一次留痕的错误；同一种错误连续出现只记一次，成功一拍后清零。
  String? _lastErrorKey;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(InterconnectP2pPathBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url == widget.url) return;
    _timer?.cancel();
    _timer = null;
    _tracker = InterconnectP2pPathTracker();
    _status = null;
    _relayOnly = false;
    _lastErrorKey = null;
    _start();
  }

  void _start() {
    _nodeId = parseInterconnectP2pUrl(widget.url)?.nodeId;
    // NodeId 非法（畸形链接）从结构上不可能查到状态；没有运行时（测试与不支持
    // P2P 的平台）也不轮询：两种情况都不起定时器。
    if (_nodeId == null || currentAppInterconnectP2pRuntime == null) return;
    // 首拍放到 initState 之外：轮询里的 FFI 调用不在 build 阶段执行。
    _timer = Timer(Duration.zero, () {
      _timer = Timer.periodic(
        InterconnectP2pPathBadge.pollInterval,
        (_) => _poll(),
      );
      _poll();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _poll() {
    final String? nodeId = _nodeId;
    final InterconnectP2pNode? node = currentAppInterconnectP2pRuntime?.current;
    FushiP2pConnStatus? status;
    if (nodeId != null && node != null) {
      try {
        status = node.status(nodeId);
        _lastErrorKey = null;
      } on FushiP2pException catch (e, st) {
        // 端点被 restart 关掉的竞态 / 原生拒绝：本拍按无状态显示，继续轮询——
        // 运行时重建后新节点自愈。
        _recordError(e, st);
      } on StateError catch (e, st) {
        _recordError(e, st);
      }
    }
    final bool relayOnly =
        status != null && _tracker.observe(status, DateTime.now());
    if (!mounted) return;
    setState(() {
      _status = status;
      _relayOnly = relayOnly;
    });
  }

  void _recordError(Object error, StackTrace stack) {
    final String key = '${error.runtimeType}:$error';
    if (key == _lastErrorKey) return;
    _lastErrorKey = key;
    ErrorLogService.instance.log('P2pPathBadge', error, stack);
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

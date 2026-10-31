/// 库页远端条目「从远端删除」类动作此刻**能不能用**（反馈 R8duEiqRuy，所有者
/// 2026-10-31 拍板）。
///
/// 规则：可以删远端，但只在对端在线、可达时可用；离线时菜单项照样画出来、禁用并写明
/// 原因；可用时点下去还要再过一道二次确认（各页自己的确认框）。
///
/// 判据只有一个：[InterconnectSyncBackend.probeHostReachability] 在菜单打开时**重新**
/// 探一次已配对 host（不信缓存会话）。探测进行中这一项是禁用的「正在检查」，而不是先
/// 亮着——不然对端其实离线时用户可能在结论出来前点下去，确认后才收到失败提示。
library;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// [reachability] 对应的禁用原因；null 入参 = 还在探测。可用时返回 null。
String? remoteDeleteDisabledReason(
  InterconnectHostReachability? reachability,
) => switch (reachability) {
  null => t.remote_delete_host_checking,
  InterconnectHostReachability.reachable => null,
  InterconnectHostReachability.unreachable => t.remote_delete_host_offline,
  InterconnectHostReachability.credentialRejected =>
    t.remote_delete_host_pairing_rejected,
};

/// 包住远端条目的动作菜单：打开时探一次对端可达性，结论出来后用新的禁用原因重建菜单。
///
/// [probe] 为 null = 该远端来源没有删除能力（云盘等），不探测、[builder] 收到 null 且
/// 调用方本就不会画删除项。
class RemoteDeleteAvailabilityBuilder extends StatefulWidget {
  const RemoteDeleteAvailabilityBuilder({
    required this.probe,
    required this.builder,
    super.key,
  });

  final Future<InterconnectHostReachability> Function()? probe;

  /// [disabledReason] 为 null = 删除项可用（或 [probe] 为 null 时无删除项）。
  final Widget Function(BuildContext context, String? disabledReason) builder;

  @override
  State<RemoteDeleteAvailabilityBuilder> createState() =>
      _RemoteDeleteAvailabilityBuilderState();
}

class _RemoteDeleteAvailabilityBuilderState
    extends State<RemoteDeleteAvailabilityBuilder> {
  InterconnectHostReachability? _reachability;

  @override
  void initState() {
    super.initState();
    final Future<InterconnectHostReachability> Function()? probe = widget.probe;
    if (probe != null) _runProbe(probe);
  }

  Future<void> _runProbe(
    Future<InterconnectHostReachability> Function() probe,
  ) async {
    InterconnectHostReachability result;
    try {
      result = await probe();
    } catch (e, stack) {
      // probeHostReachability 已把鉴权 / 连不上映射成结论；走到这里是意料之外的
      // 失败（选路内部异常等）。记日志，并按「连不上」禁用——不能当可用放行。
      ErrorLogService.instance.log(
        'RemoteDeleteAvailabilityBuilder.probe',
        e,
        stack,
      );
      result = InterconnectHostReachability.unreachable;
    }
    if (!mounted) return;
    setState(() => _reachability = result);
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    widget.probe == null ? null : remoteDeleteDisabledReason(_reachability),
  );
}

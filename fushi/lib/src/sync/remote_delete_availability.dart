/// 库页远端条目「从远端删除」类动作此刻**能不能用**（反馈 R8duEiqRuy，所有者
/// 2026-10-31 拍板）。
///
/// 规则：可以删远端，但只在对端在线、可达时可用；离线时菜单项照样画出来、禁用并写明
/// 原因；可用时点下去还要再过一道二次确认（各页自己的确认框）。
///
/// 判据：菜单打开时**重新**探一次来源——互联用
/// `InterconnectSyncBackend.probeHostReachability`（不信缓存会话），云盘用
/// `CloudRemoteBookClient.probeRemoteReachability`（列一次同步根）。探测进行中这一项
/// 是禁用的「正在检查」，而不是先
/// 亮着——不然对端其实离线时用户可能在结论出来前点下去，确认后才收到失败提示。
library;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// [reachability] 对应的禁用原因；null 入参 = 还在探测。可用时返回 null。
/// [kind] 决定措辞：互联说「对端」（配对），云盘说「云盘」（登录）。
String? remoteDeleteDisabledReason(
  RemoteSourceReachability? reachability, {
  RemoteBookSourceKind kind = RemoteBookSourceKind.interconnect,
}) {
  final bool cloud = kind == RemoteBookSourceKind.cloud;
  return switch (reachability) {
    null =>
      cloud ? t.remote_delete_cloud_checking : t.remote_delete_host_checking,
    RemoteSourceReachability.reachable => null,
    RemoteSourceReachability.unreachable =>
      cloud ? t.remote_delete_cloud_offline : t.remote_delete_host_offline,
    RemoteSourceReachability.credentialRejected =>
      cloud
          ? t.remote_delete_cloud_signed_out
          : t.remote_delete_host_pairing_rejected,
  };
}

/// 包住远端条目的动作菜单：打开时探一次对端可达性，结论出来后用新的禁用原因重建菜单。
///
/// [probe] 为 null = 该远端来源没有删除能力，不探测、[builder] 收到 null 且
/// 调用方本就不会画删除项。
class RemoteDeleteAvailabilityBuilder extends StatefulWidget {
  const RemoteDeleteAvailabilityBuilder({
    required this.probe,
    required this.builder,
    this.kind = RemoteBookSourceKind.interconnect,
    super.key,
  });

  /// 远端来源类型，只决定禁用原因的措辞（见 [remoteDeleteDisabledReason]）。
  final RemoteBookSourceKind kind;

  final Future<RemoteSourceReachability> Function()? probe;

  /// [disabledReason] 为 null = 删除项可用（或 [probe] 为 null 时无删除项）。
  final Widget Function(BuildContext context, String? disabledReason) builder;

  @override
  State<RemoteDeleteAvailabilityBuilder> createState() =>
      _RemoteDeleteAvailabilityBuilderState();
}

class _RemoteDeleteAvailabilityBuilderState
    extends State<RemoteDeleteAvailabilityBuilder> {
  RemoteSourceReachability? _reachability;

  @override
  void initState() {
    super.initState();
    final Future<RemoteSourceReachability> Function()? probe = widget.probe;
    if (probe != null) _runProbe(probe);
  }

  Future<void> _runProbe(
    Future<RemoteSourceReachability> Function() probe,
  ) async {
    RemoteSourceReachability result;
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
      result = RemoteSourceReachability.unreachable;
    }
    if (!mounted) return;
    setState(() => _reachability = result);
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    widget.probe == null
        ? null
        : remoteDeleteDisabledReason(_reachability, kind: widget.kind),
  );
}

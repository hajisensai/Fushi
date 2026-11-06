/// 同步页的「设备」列表：每台设备的名称（「<名称>（Fushi X.Y）」）、平台图标、最后在线、状态（正常 / 落后 / 缺段 /
/// 需要升级 / 已停用）。点本机改昵称（只替换名称部分）；点别的设备「这台设备不用了」（停用，确认框说明后果，可在这里
/// 恢复），已停用的点了恢复。数据来自内核 `sync2_status`（native/fushi_fsrs/src/store/sync2/devices.rs）。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/srs/srs_device_view.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

/// 设备排序：本机在前，其余按最后在线新到旧。
List<SrsDeviceView> srsSortDevices(Iterable<SrsDeviceView> devices) =>
    devices.toList()..sort((SrsDeviceView a, SrsDeviceView b) {
      if (a.self != b.self) return a.self ? -1 : 1;
      return (b.seenAt ?? 0).compareTo(a.seenAt ?? 0);
    });

/// 一台设备的状态色调（设备行右侧的标签）。
FushiTagTone srsDeviceStateTone(SrsDeviceState s) => switch (s) {
  SrsDeviceState.ok => FushiTagTone.success,
  SrsDeviceState.behind => FushiTagTone.neutral,
  SrsDeviceState.missing => FushiTagTone.warning,
  SrsDeviceState.upgrade => FushiTagTone.error,
  SrsDeviceState.retired => FushiTagTone.neutral,
};

/// 设备行的标题：与其它行同一版式——标题是「<名称>（Fushi X.Y）」，「本机」/ 最后在线进副标题。本机还没起名
/// （第一次同步前）标题就是「本机」；没名字的对端标题只写「未命名设备」（最后在线照样在副标题）。
String srsDeviceRowTitle(BuildContext context, SrsDeviceView d) {
  if (d.baseName.isEmpty) {
    return d.self ? t.srs_timeline_this_device : t.srs_device_unnamed;
  }
  return d.displayName(formatTime: (DateTime x) => srsTimeLabel(context, x));
}

/// 设备行的说明（最后在线、状态细节、旧有的分歧 / 时钟告警）。
List<String> srsDeviceRowDetails(
  BuildContext context,
  SrsDeviceView d, {
  required bool syncing,
}) {
  final int? seen = d.seenAt;
  return <String?>[
    // 标题已是「本机」（还没起名）时不重复。
    if (d.self && d.baseName.isNotEmpty) t.srs_timeline_this_device,
    if (!d.self && seen != null)
      t.srs_device_seen(
        time: srsTimeLabel(context, DateTime.fromMillisecondsSinceEpoch(seen)),
      ),
    if (!d.self)
      switch (d.state) {
        SrsDeviceState.missing when d.blocking > 0 =>
          t.srs_device_blocking_detail(n: d.blocking),
        SrsDeviceState.missing => t.srs_device_gap_detail,
        SrsDeviceState.upgrade => t.srs_device_upgrade_detail,
        SrsDeviceState.retired => t.srs_device_retired_detail(
          time: srsTimeLabel(
            context,
            DateTime.fromMillisecondsSinceEpoch(d.retiredAt ?? 0),
          ),
        ),
        SrsDeviceState.behind =>
          syncing
              ? t.srs_timeline_receiving(n: d.behind)
              : t.srs_timeline_behind(n: d.behind),
        SrsDeviceState.ok => null,
      },
    if (d.digestMismatch) t.srs_timeline_digest_mismatch,
    if (d.warning != null) t.srs_timeline_device_warning,
  ].nonNulls.toList();
}

class SrsSyncDevicesSection extends StatelessWidget {
  const SrsSyncDevicesSection({
    super.key,
    required this.devices,
    required this.syncing,
    required this.enabled,
    required this.onRename,
    required this.onRetire,
    required this.onUnretire,
  });

  final List<SrsDeviceView> devices;

  /// 同步在跑：「没收到」换成「正在接收」。
  final bool syncing;

  /// 有操作在跑时禁用点按。
  final bool enabled;
  final ValueChanged<SrsDeviceView> onRename;
  final ValueChanged<SrsDeviceView> onRetire;
  final ValueChanged<SrsDeviceView> onUnretire;

  @override
  Widget build(BuildContext context) {
    final List<SrsDeviceView> sorted = srsSortDevices(devices);
    return AdaptiveSettingsSection(
      title: t.srs_devices_section,
      children: <Widget>[
        for (int i = 0; i < sorted.length; i++)
          FushiStaggeredEntrance(index: i, child: _row(context, sorted[i])),
      ],
    );
  }

  Widget _row(BuildContext context, SrsDeviceView d) {
    final VoidCallback? onTap = !enabled
        ? null
        : d.self
        ? () => onRename(d)
        : d.state == SrsDeviceState.retired
        ? () => onUnretire(d)
        : () => onRetire(d);
    final List<String> details = srsDeviceRowDetails(
      context,
      d,
      syncing: syncing,
    );
    return FushiPressScale(
      enabled: onTap != null,
      child: AdaptiveSettingsRow(
        key: ValueKey<String>('srs_timeline_device_${d.id}'),
        title: srsDeviceRowTitle(context, d),
        subtitle: details.isEmpty ? null : SrsMetaLine.join(details),
        icon:
            d.digestMismatch ||
                d.warning != null ||
                d.state == SrsDeviceState.upgrade
            ? FushiIcons.warning
            : d.icon,
        showIcon: true,
        subtitleMaxLines: 3,
        trailing: d.self
            ? FushiTooltip(
                key: ValueKey<String>('srs_device_rename_${d.id}'),
                message: t.srs_device_rename_tooltip,
                child: const FushiIcon(FushiIcons.rename),
              )
            : FushiTag(
                key: ValueKey<String>('srs_device_state_${d.id}'),
                text: d.state.label,
                tone: srsDeviceStateTone(d.state),
                dense: true,
              ),
        onTap: onTap,
      ),
    );
  }
}

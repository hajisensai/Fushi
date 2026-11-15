/// 复习同步 v2 的设备怎么显示（同步页设备列表、冲突中心、修改记录共用）：内核 `sync2_status` 每台设备一行
/// （native/fushi_fsrs/src/store/sync2/devices.rs 补了型号 / 版本 / 平台 / 状态）。解析、挑出还没信任的设备与
/// 信任 / 拒绝在 engine（package:fushi_engine/srs/srs_devices.dart，无头服务端的管理接口共用），这里只做人读格式。
///
/// 名称规则：自报名字（昵称或型号）→ 「<名称>（Fushi X.Y）」；老版本没自报名字、互联 host 认得出是哪个已配对对端
/// 写的 → 对端名；都没有 → 「未命名设备 · 最后在线 <日期>」。
library;

import 'package:flutter/widgets.dart' show IconData;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_devices.dart';
import 'package:fushi_engine/srs/srs_edit_history.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

export 'package:fushi_engine/srs/srs_devices.dart';

/// 设备状态的人读名。
extension SrsDeviceStateLabel on SrsDeviceState {
  String get label => switch (this) {
    SrsDeviceState.ok => t.srs_device_state_ok,
    SrsDeviceState.behind => t.srs_device_state_behind,
    SrsDeviceState.missing => t.srs_device_state_missing,
    SrsDeviceState.upgrade => t.srs_device_state_upgrade,
    SrsDeviceState.retired => t.srs_device_state_retired,
  };
}

/// 设备的人读名与图标。
extension SrsDeviceViewDisplay on SrsDeviceView {
  /// 「<名称>（Fushi X.Y）」/ 对端名 / 「未命名设备 · 最后在线 <日期>」。
  String displayName({required String Function(DateTime time) formatTime}) {
    final String base = baseName;
    if (base.isNotEmpty) {
      return app.isEmpty
          ? base
          : t.srs_device_label_versioned(name: base, version: app);
    }
    final int? seen = seenAt;
    if (seen != null) {
      return t.srs_device_unnamed_seen(
        time: formatTime(DateTime.fromMillisecondsSinceEpoch(seen)),
      );
    }
    return t.srs_device_unnamed;
  }

  /// 按平台的图标（老版本没报平台的给通用设备图标）。
  IconData get icon => switch (platform) {
    'ios' || 'android' => FushiIcons.phone,
    'windows' || 'macos' || 'linux' => FushiIcons.laptop,
    _ => FushiIcons.devices,
  };
}

/// 设备 ID → 设备（冲突中心 / 修改记录按写入者 ID 查名字）。
class SrsDeviceDirectory {
  SrsDeviceDirectory(Iterable<SrsDeviceView> devices)
    : _byKey = <String, SrsDeviceView>{
        for (final SrsDeviceView d in devices) srsDeviceKey(d.id): d,
      };

  static final SrsDeviceDirectory empty = SrsDeviceDirectory(
    const <SrsDeviceView>[],
  );

  final Map<String, SrsDeviceView> _byKey;

  SrsDeviceView? of(String writerId) => _byKey[srsDeviceKey(writerId)];

  /// 目录里的全部设备（冲突中心从同一份状态里挑出还没信任的，不再另读一次 `sync2_status`）。
  Iterable<SrsDeviceView> get all => _byKey.values;

  /// 写入者的显示名：本机 → [selfLabel]；认识的设备 → [SrsDeviceView.displayName]；不认识 → [fallback]。
  String label(
    String writerId, {
    required String selfLabel,
    required String fallback,
    required String Function(DateTime time) formatTime,
  }) {
    final SrsDeviceView? d = of(writerId);
    if (d == null) return fallback;
    if (d.self) return selfLabel;
    return d.displayName(formatTime: formatTime);
  }
}

/// 读内核的设备表（远程复习库等不支持状态的实现读不到时退到只有名字的表）。
Future<SrsDeviceDirectory> srsLoadDeviceDirectory(SrsDbStore store) async {
  try {
    return SrsDeviceDirectory(await srsLoadDevices(store));
  } catch (e, stack) {
    ErrorLogService.instance.log('SrsDeviceDirectory.load', e, stack);
    try {
      return SrsDeviceDirectory(<SrsDeviceView>[
        for (final MapEntry<String, String> e
            in (await store.sync2DeviceNames()).entries)
          SrsDeviceView(id: e.key, name: e.value),
      ]);
    } catch (_) {
      return SrsDeviceDirectory.empty;
    }
  }
}

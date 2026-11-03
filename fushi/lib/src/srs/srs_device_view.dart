/// 复习同步 v2 的设备怎么显示（同步页设备列表、冲突中心、修改记录共用）：内核 `sync2_status` 每台设备一行
/// （native/fushi_fsrs/src/store/sync2/devices.rs 补了型号 / 版本 / 平台 / 状态），这里只做人读格式。
///
/// 名称规则：自报名字（昵称或型号）→ 「<名称>（Fushi X.Y）」；老版本没自报名字、互联 host 认得出是哪个已配对对端
/// 写的 → 对端名；都没有 → 「未命名设备 · 最后在线 <日期>」。
library;

import 'package:flutter/widgets.dart' show IconData;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_edit_history.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart' show ErrorLogService;

/// 一台设备在同步里的状态（内核 `state`）。
enum SrsDeviceState {
  ok,
  behind,
  missing,
  upgrade,
  retired;

  static SrsDeviceState parse(Object? v) => switch (v) {
    'behind' => SrsDeviceState.behind,
    'missing' => SrsDeviceState.missing,
    'upgrade' => SrsDeviceState.upgrade,
    'retired' => SrsDeviceState.retired,
    _ => SrsDeviceState.ok,
  };

  String get label => switch (this) {
    SrsDeviceState.ok => t.srs_device_state_ok,
    SrsDeviceState.behind => t.srs_device_state_behind,
    SrsDeviceState.missing => t.srs_device_state_missing,
    SrsDeviceState.upgrade => t.srs_device_state_upgrade,
    SrsDeviceState.retired => t.srs_device_state_retired,
  };
}

/// 设备 ID 的比较形（内核给带连字符的 UUID 文本，修改记录的写入者 ID 可能带 `#化身号`）。
String srsDeviceKey(String id) {
  final int hash = id.lastIndexOf('#');
  final String base = hash < 0 ? id : id.substring(0, hash);
  return base.replaceAll('-', '').toLowerCase();
}

/// 内核 `sync2_status.devices` 的一行。
class SrsDeviceView {
  const SrsDeviceView({
    required this.id,
    this.self = false,
    this.name = '',
    this.hint = '',
    this.model = '',
    this.app = '',
    this.platform = '',
    this.seenAt,
    this.behind = 0,
    this.gap = 0,
    this.blocking = 0,
    this.retiredAt,
    this.state = SrsDeviceState.ok,
    this.digestMismatch = false,
    this.warning,
  });

  factory SrsDeviceView.fromStatus(Map<String, Object?> d) {
    String s(String k) => (d[k] as String?)?.trim() ?? '';
    int n(String k) => (d[k] as num?)?.toInt() ?? 0;
    return SrsDeviceView(
      id: d['device'] as String? ?? '',
      self: d['self'] == true,
      name: s('name'),
      hint: s('hint'),
      model: s('model'),
      app: s('app'),
      platform: s('platform'),
      seenAt: (d['seenAt'] as num?)?.toInt(),
      behind: n('behind'),
      gap: n('gap'),
      blocking: n('blocking'),
      retiredAt: (d['retiredAt'] as num?)?.toInt(),
      state: SrsDeviceState.parse(d['state']),
      digestMismatch: d['digestMismatch'] == true,
      warning: s('warning').isEmpty ? null : s('warning'),
    );
  }

  final String id;
  final bool self;

  /// 自报的人读名（昵称或型号）。
  final String name;

  /// 互联 host 认出的已配对对端名（没自报名字时用）。
  final String hint;
  final String model;

  /// App 版本（`major.minor`）。
  final String app;

  /// `ios` / `android` / `windows` / `macos` / `linux`（老版本没有 = 空）。
  final String platform;
  final int? seenAt;
  final int behind;
  final int gap;
  final int blocking;
  final int? retiredAt;
  final SrsDeviceState state;
  final bool digestMismatch;
  final String? warning;

  /// 名称部分（不带版本）；没有名字返回空串。
  String get baseName => name.isNotEmpty ? name : hint;

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
    final Map<String, Object?> status = await store.sync2Status();
    return SrsDeviceDirectory(<SrsDeviceView>[
      for (final Object? d in (status['devices'] as List<Object?>?) ?? const [])
        if (d is Map) SrsDeviceView.fromStatus(d.cast<String, Object?>()),
    ]);
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

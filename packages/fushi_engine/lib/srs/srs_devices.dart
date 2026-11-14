/// 复习同步 v2 的设备表与设备信任（app 的同步页 / 冲突中心与无头服务端的管理接口共用）。
///
/// 数据源是内核 `sync2_status` 的 `devices`（native/fushi_fsrs/src/store/sync2/devices.rs，信任字段见
/// store/sync2/trust.rs）：这里只做解析、挑出还没信任的设备、以及「信任 / 拒绝」前的校验。人读格式（「未命名设备」、
/// 版本号拼接、图标）依赖 app 的翻译，在 fushi/lib/src/srs/srs_device_view.dart。
library;

import 'package:fushi_engine/srs/srs_db_store.dart';

/// 一台设备在同步里的状态（内核 `state`）。
enum SrsDeviceState {
  ok('ok'),
  behind('behind'),
  missing('missing'),
  upgrade('upgrade'),
  retired('retired');

  const SrsDeviceState(this.wire);

  final String wire;

  static SrsDeviceState parse(Object? v) => switch (v) {
    'behind' => SrsDeviceState.behind,
    'missing' => SrsDeviceState.missing,
    'upgrade' => SrsDeviceState.upgrade,
    'retired' => SrsDeviceState.retired,
    _ => SrsDeviceState.ok,
  };
}

/// 本机对一台设备的信任（内核 `trust`，native/fushi_fsrs/src/store/sync2/trust.rs）：没有 = 可信；待确认 / 已拒绝的
/// 设备的删除与彻底清除在本机扣着。顺序即列表顺序（待确认在前，再是已拒绝）。
enum SrsDeviceTrust {
  trusted('trusted'),
  pending('pending'),
  rejected('rejected');

  const SrsDeviceTrust(this.wire);

  final String wire;

  static SrsDeviceTrust parse(Object? v) => switch (v) {
    'pending' => SrsDeviceTrust.pending,
    'rejected' => SrsDeviceTrust.rejected,
    _ => SrsDeviceTrust.trusted,
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
    this.trust = SrsDeviceTrust.trusted,
    this.trustSince,
    this.heldDeletes = 0,
    this.heldPurges = 0,
    this.rulesTheirs,
    this.rulesMine,
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
      trust: SrsDeviceTrust.parse(d['trust']),
      trustSince: (d['trustSince'] as num?)?.toInt(),
      heldDeletes: n('heldDeletes'),
      heldPurges: n('heldPurges'),
      rulesTheirs: ((d['rules'] as Map?)?['theirs'] as num?)?.toInt(),
      rulesMine: ((d['rules'] as Map?)?['mine'] as num?)?.toInt(),
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

  /// 本机对它的信任；不是 [SrsDeviceTrust.trusted] 时它的删除（[heldDeletes]）与彻底清除（[heldPurges]）在本机
  /// 扣着，确认后生效。[trustSince] = 它第一份 head 的时刻。
  final SrsDeviceTrust trust;
  final int? trustSince;
  final int heldDeletes;
  final int heldPurges;

  /// 待本机确认（冲突中心的确认卡片与角标、服务端管理接口的待确认列表）。
  bool get needsTrust => trust == SrsDeviceTrust.pending;

  /// 对端的派生规则版本与本机不同（内核 `rules`，从它摘要串的前缀解析，store/sync2/digest.rs）：两边的数据摘要
  /// 不比对。规则相同 / 不知道时都是 null。
  final int? rulesTheirs;
  final int? rulesMine;

  /// 名称部分（不带版本）；没有名字返回空串。
  String get baseName => name.isNotEmpty ? name : hint;

  /// 管理接口的 JSON 形（服务端 `/api/admin/srs/devices`）；没有的可选项不出现。
  Map<String, Object?> toJson() => <String, Object?>{
    'device': id,
    'self': self,
    'name': baseName,
    if (model.isNotEmpty) 'model': model,
    if (app.isNotEmpty) 'app': app,
    if (platform.isNotEmpty) 'platform': platform,
    'seenAt': ?seenAt,
    'state': state.wire,
    'retiredAt': ?retiredAt,
    'trust': trust.wire,
    'trustSince': ?trustSince,
    'heldDeletes': heldDeletes,
    'heldPurges': heldPurges,
  };
}

/// 内核 `sync2_status` 的设备行。本机那一行的名称 / 版本 / 平台取顶层 `selfInfo`（本机自报的，devices 表里本机行
/// 没有对端 head 记下的扩展信息）。
List<SrsDeviceView> srsDeviceViewsOf(Map<String, Object?> status) {
  final Object? info = status['selfInfo'];
  final Map<String, Object?> self = info is Map
      ? info.cast<String, Object?>()
      : const <String, Object?>{};
  final List<SrsDeviceView> out = <SrsDeviceView>[];
  for (final Object? d in (status['devices'] as List<Object?>?) ?? const []) {
    if (d is! Map) continue;
    final Map<String, Object?> row = Map<String, Object?>.of(
      d.cast<String, Object?>(),
    );
    if (row['self'] == true) {
      for (final String k in const <String>[
        'name',
        'model',
        'app',
        'platform',
      ]) {
        final Object? v = self[k];
        if (v is String && v.trim().isNotEmpty) row[k] = v;
      }
    }
    out.add(SrsDeviceView.fromStatus(row));
  }
  return out;
}

/// 还没信任的别的设备：待确认在前，再是已拒绝的（同一档按首次出现先后）。
List<SrsDeviceView> srsUntrustedDevices(Iterable<SrsDeviceView> devices) =>
    devices
        .where(
          (SrsDeviceView d) => !d.self && d.trust != SrsDeviceTrust.trusted,
        )
        .toList()
      ..sort((SrsDeviceView a, SrsDeviceView b) {
        final int byTrust = a.trust.index.compareTo(b.trust.index);
        if (byTrust != 0) return byTrust;
        return (a.trustSince ?? 0).compareTo(b.trustSince ?? 0);
      });

/// 读 [store] 的设备表（内核 `sync2_status`）。
Future<List<SrsDeviceView>> srsLoadDevices(SrsDbStore store) async =>
    srsDeviceViewsOf(await store.sync2Status());

/// [srsSetDeviceTrust] 拒绝执行的原因。
enum SrsDeviceTrustRefusal {
  /// 设备表里没有这台设备。
  unknownDevice('device_unknown'),

  /// 是本机自己（本机永远可信）。
  selfDevice('device_self'),

  /// 已经可信：没有扣着的东西，也不能再拒绝（可信设备的删除早已生效）。
  alreadyTrusted('device_trusted');

  const SrsDeviceTrustRefusal(this.reason);

  /// 管理接口回包里的 `reason`。
  final String reason;
}

/// 信任 / 拒绝之前的校验没过。
class SrsDeviceTrustException implements Exception {
  const SrsDeviceTrustException(this.refusal, this.device);

  final SrsDeviceTrustRefusal refusal;
  final String device;

  @override
  String toString() => 'SrsDeviceTrustException(${refusal.reason}: $device)';
}

/// 信任（[trust] = true：扣着的删除与彻底清除同一次调用里放行进投影）/ 拒绝（继续扣着，之后仍可改为信任）一台还没
/// 信任的设备。[device] 按 [srsDeviceKey] 比较（带不带连字符都认）。只对待确认 / 已拒绝的别的设备：不认识、是本机、
/// 已经可信时抛 [SrsDeviceTrustException]，不进内核。返回操作之后那台设备的行。
Future<SrsDeviceView> srsSetDeviceTrust(
  SrsDbStore store,
  String device, {
  required bool trust,
}) async {
  final String key = srsDeviceKey(device);
  SrsDeviceView? find(List<SrsDeviceView> all) {
    for (final SrsDeviceView d in all) {
      if (srsDeviceKey(d.id) == key) return d;
    }
    return null;
  }

  final SrsDeviceView? d = find(await srsLoadDevices(store));
  if (d == null) {
    throw SrsDeviceTrustException(SrsDeviceTrustRefusal.unknownDevice, device);
  }
  if (d.self) {
    throw SrsDeviceTrustException(SrsDeviceTrustRefusal.selfDevice, device);
  }
  if (d.trust == SrsDeviceTrust.trusted) {
    throw SrsDeviceTrustException(SrsDeviceTrustRefusal.alreadyTrusted, device);
  }
  await store.sync2Trust(d.id, trust: trust);
  return find(await srsLoadDevices(store)) ??
      SrsDeviceView(
        id: d.id,
        trust: trust ? SrsDeviceTrust.trusted : SrsDeviceTrust.rejected,
      );
}

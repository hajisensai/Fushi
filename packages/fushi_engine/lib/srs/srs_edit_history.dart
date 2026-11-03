/// 一个实体的完整修改历史（docs/specs/2026-10-25-srs-sync-v2-design.md §10.2：每张卡、每个字段的修改历史——
/// 谁、哪台设备、何时——可直接展示）。
///
/// 投影只留生效的记录（被因果支配的修改落地时就删了），完整历史在操作日志里：内核 `history` 命令按实体列出
/// 碰过它的全部字段修改与标签操作（store/sync2/timeline.rs `sync2_history`）。被彻底清除的只剩骨架。
library;

import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';

/// 历史里的一条。
class SrsHistoryEntry {
  const SrsHistoryEntry({
    required this.key,
    required this.writer,
    required this.device,
    required this.at,
    this.value,
    this.machine = false,
    this.tagAdded,
    this.tagRemoved,
    this.purged = false,
  });

  factory SrsHistoryEntry.fromJson(Map<String, Object?> j) => SrsHistoryEntry(
    key: j['key'] as String? ?? '',
    value: j['value'],
    writer: j['writer'] as String? ?? '',
    device: j['device'] as String? ?? '',
    at: (j['at'] as num?)?.toInt() ?? 0,
    machine: j['machine'] == true,
    tagAdded: j['tagAdded'] as String?,
    tagRemoved: j['tagRemoved'] as String?,
    purged: j['purged'] == true,
  );

  /// 字段键（笔记字段是 `f/<字段 ID>`；标签操作是 `tags`）。
  final String key;
  final Object? value;

  /// 写下它的写入者：v2 是设备 ID；迁移来的旧记录是旧写入者 ID。
  final String writer;

  /// 承载它的操作所属的设备。
  final String device;

  /// 写下时刻（毫秒）。
  final int at;

  /// 机械写入（导入 / 批量重排之类），界面上可以弱化。
  final bool machine;
  final String? tagAdded;
  final String? tagRemoved;
  final bool purged;
}

extension SrsEditHistory on SrsDbStore {
  /// [kind] / [entityId] 的全部修改，新的在前。
  Future<List<SrsHistoryEntry>> editHistory(
    SrsEntityKind kind,
    String entityId,
  ) async {
    final SrsDbStore self = this;
    if (self is SrsRemoteForwarding) {
      return (self as SrsRemoteForwarding).remoteEditHistory(kind, entityId);
    }
    final SrsSync2Result r = await sync2Command(<String, Object?>{
      'op': 'history',
      'kind': kind.wire,
      'entity': entityId,
    });
    return <SrsHistoryEntry>[
      for (final Object? e in (r.json as List<Object?>?) ?? const <Object?>[])
        if (e is Map) SrsHistoryEntry.fromJson(e.cast<String, Object?>()),
    ];
  }

  /// 设备 ID → 设备名（各设备 head 里报的名字；没报过的不在表里）。
  Future<Map<String, String>> sync2DeviceNames() async {
    final SrsDbStore self = this;
    if (self is SrsRemoteForwarding) {
      return (self as SrsRemoteForwarding).remoteDeviceNames();
    }
    final Map<String, Object?> status = await sync2Status();
    return <String, String>{
      for (final Object? d in (status['devices'] as List?) ?? const <Object?>[])
        if (d is Map && ((d['name'] as String?) ?? '').isNotEmpty)
          d['device']! as String: d['name']! as String,
    };
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:fushi_core/fushi_core.dart'
    show PendingMineRow, PendingMineStatus;
import 'package:fushi_engine/sync/sync_asset_store.dart';

import 'package:fushi/src/anki/pending_mining/pending_mine_store.dart';

/// 一轮跨设备中转的结果。
class PendingMineRelayReport {
  const PendingMineRelayReport({
    this.uploaded = 0,
    this.received = 0,
    this.acknowledged = 0,
  });

  /// 本机上传给落地设备的卡数。
  final int uploaded;

  /// 本机（落地设备）新收到、待交给 Anki 的卡数。
  final int received;

  /// 清掉的远端记录（回执 / 已落地卡）数。
  final int acknowledged;
}

/// 待发制卡的**跨设备中转**：经用户已配置的同步后端（Google Drive / OneDrive /
/// Dropbox / WebDAV / FTP / SFTP / 互联）的资产层，把没装 Anki 的设备制的卡送到
/// 一台装了 Anki 的「落地设备」，由它交给本机 Anki，再经官方客户端同步进 AnkiWeb。
///
/// 数据全在命名空间 [namespace] 下，全部是**写一次**的文件，没有合并逻辑：
/// * `landing.json`：落地设备认领 `{deviceId, deviceName, claimedAt}`。只有一份，
///   认领时刻大者胜（用户在哪台设备上**后**打开「本机落地」就是哪台）。
/// * `<id>.json`：一张待发卡 `{id, createdAt, expression, reading, originDeviceId,
///   payload}`，由制卡设备写。
/// * `<id>.landed.json`：落地回执，由落地设备在交给 Anki 后写；制卡设备看到回执
///   删本地行与回执。
///
/// 没有任何设备认领落地时，制卡设备什么都不上传——没人要的卡不外流。
///
/// 重复落地的兜底：落地后、写回执前进程被杀，下一轮会再落一次；Anki 自己的查重
/// 判重复，按「已送达」出队。
class PendingMineRelay {
  PendingMineRelay({
    required PendingMineStore store,
    required String deviceId,
    required String deviceName,
    required int landingClaimedAt,
    int Function()? clock,
  }) : _store = store,
       _deviceId = deviceId,
       _deviceName = deviceName,
       _landingClaimedAt = landingClaimedAt,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 本机（落地设备）收到新卡时发一个事件（张数）。补发要用到 Riverpod 里的仓库，
  /// 而同步跑在没有 ref 的层里：由持有 ref 的根组件订阅并补发。进程级、广播。
  static Stream<int> get arrivals => _arrivals.stream;
  static final StreamController<int> _arrivals =
      StreamController<int>.broadcast();

  /// 中转命名空间名。
  static const String namespace = '__pending_mines__';
  static const String landingFile = 'landing.json';
  static const String _landedSuffix = '.landed.json';
  static const String _recordSuffix = '.json';

  final PendingMineStore _store;
  final String _deviceId;
  final String _deviceName;

  /// 本机「作为落地设备」开关打开的时刻（毫秒）；0 = 没打开。
  final int _landingClaimedAt;
  final int Function() _clock;

  Future<PendingMineRelayReport> run(SyncAssetStore assets) async {
    final String ns = await assets.ensureNamespace(namespace);
    final Map<String, AssetEntry> entries = <String, AssetEntry>{
      for (final AssetEntry e in await assets.listChildren(ns))
        if (!e.isFolder) e.name: e,
    };
    final String? landingId = await _resolveLanding(assets, ns, entries);
    final bool amLanding = landingId == _deviceId;

    int uploaded = 0;
    int received = 0;
    int acknowledged = 0;

    for (final PendingMineRow row in await _store.rows()) {
      if (row.originDeviceId != null) continue;
      final AssetEntry? receipt = entries['${row.id}$_landedSuffix'];
      final AssetEntry? record = entries['${row.id}$_recordSuffix'];
      if (receipt != null || row.status == PendingMineStatus.landed) {
        // 落地设备交过了，或本机自己交过 / 用户删了：清远端、出队。
        if (record != null) await assets.deleteAsset(record.id);
        if (receipt != null) await assets.deleteAsset(receipt.id);
        await _store.remove(row.id);
        acknowledged++;
        continue;
      }
      if (row.uploaded || landingId == null || amLanding) continue;
      if (row.status == PendingMineStatus.sending) continue;
      final String? payload = await _store.readPayloadJson(row.id);
      if (payload == null) continue;
      await assets
          .putJsonAsset(ns, '${row.id}$_recordSuffix', <String, Object?>{
            'id': row.id,
            'createdAt': row.createdAt,
            'expression': row.expression,
            'reading': row.reading,
            'originDeviceId': _deviceId,
            'payload': jsonDecode(payload),
          });
      await _store.markUploaded(row.id);
      uploaded++;
    }

    if (amLanding) {
      final Set<String> local = <String>{
        for (final PendingMineRow r in await _store.rows()) r.id,
      };
      for (final MapEntry<String, AssetEntry> e in entries.entries) {
        final String? id = _recordId(e.key);
        if (id == null || local.contains(id)) continue;
        if (entries.containsKey('$id$_landedSuffix')) continue;
        if (await _receive(assets, id, e.value)) received++;
      }
    }

    // 收来的卡：交过了就写回执、撤远端记录。不看本机此刻是不是落地设备——落地角色
    // 被别的设备接走后，手上已收下的卡照样会被补发，回执也必须照样写出去。
    for (final PendingMineRow row in await _store.rows()) {
      if (row.originDeviceId == null) continue;
      final AssetEntry? record = entries['${row.id}$_recordSuffix'];
      if (row.status == PendingMineStatus.landed) {
        await assets.putJsonAsset(
          ns,
          '${row.id}$_landedSuffix',
          <String, Object?>{'landedAt': _clock(), 'landedBy': _deviceId},
        );
        if (record != null) await assets.deleteAsset(record.id);
        await _store.remove(row.id);
        acknowledged++;
      } else if (record == null) {
        // 制卡设备自己交给 Anki 了（或用户在那边删了）：远端记录已撤，本机别再落。
        // 本轮刚收下的行，其记录必在 entries 里，不会走到这里。
        await _store.remove(row.id);
      }
    }

    if (received > 0) _arrivals.add(received);
    return PendingMineRelayReport(
      uploaded: uploaded,
      received: received,
      acknowledged: acknowledged,
    );
  }

  /// 读取 / 写入落地设备认领，返回当前落地设备 id（没有则 null）。
  Future<String?> _resolveLanding(
    SyncAssetStore assets,
    String ns,
    Map<String, AssetEntry> entries,
  ) async {
    final AssetEntry? entry = entries[landingFile];
    Map<String, Object?>? claim;
    if (entry != null) {
      final Object? json = await assets.getJsonAsset(entry.id);
      if (json is Map) claim = Map<String, Object?>.from(json);
    }
    final int claimedAt = (claim?['claimedAt'] as num?)?.toInt() ?? 0;
    if (_landingClaimedAt > 0 && _landingClaimedAt > claimedAt) {
      claim = <String, Object?>{
        'deviceId': _deviceId,
        'deviceName': _deviceName,
        'claimedAt': _landingClaimedAt,
      };
      await assets.putJsonAsset(ns, landingFile, claim);
    }
    final Object? id = claim?['deviceId'];
    return id is String && id.isNotEmpty ? id : null;
  }

  Future<bool> _receive(SyncAssetStore assets, String id, AssetEntry e) async {
    final Object? json = await assets.getJsonAsset(e.id);
    if (json is! Map) return false;
    final Object? payload = json['payload'];
    final Object? origin = json['originDeviceId'];
    final Object? expression = json['expression'];
    if (payload is! Map || origin is! String || expression is! String) {
      return false;
    }
    if (origin == _deviceId) return false;
    return _store.insertRemote(
      id: id,
      createdAt: (json['createdAt'] as num?)?.toInt() ?? _clock(),
      expression: expression,
      reading: json['reading'] as String? ?? '',
      originDeviceId: origin,
      payloadJson: jsonEncode(payload),
    );
  }

  /// `<id>.json` → id；回执、认领与其它文件返回 null。
  static String? _recordId(String name) {
    if (name == landingFile || name.endsWith(_landedSuffix)) return null;
    if (!name.endsWith(_recordSuffix)) return null;
    final String id = name.substring(0, name.length - _recordSuffix.length);
    return id.isEmpty ? null : id;
  }
}

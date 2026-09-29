import 'dart:async';
import 'dart:convert';

import 'package:fushi_core/fushi_core.dart'
    show PendingMineRow, PendingMineStatus;
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';

import 'package:fushi_engine/anki_sync/pending_mine_store.dart';

/// 一轮跨设备中转的结果。
class PendingMineRelayReport {
  const PendingMineRelayReport({
    this.uploaded = 0,
    this.received = 0,
    this.acknowledged = 0,
    this.errors = const <String>[],
  });

  /// 本机上传给落地设备的卡数。
  final int uploaded;

  /// 本机（落地设备）新收到、待交给 Anki 的卡数。
  final int received;

  /// 清掉的远端记录（回执 / 已落地卡）数。
  final int acknowledged;

  /// 单张卡的失败（不打断本轮其余的卡）。
  final List<String> errors;
}

/// 待发制卡的**跨设备中转**：经用户已配置的同步后端（Google Drive / OneDrive /
/// Dropbox / WebDAV / FTP / SFTP / 互联）的资产层，把没装 Anki 的设备制的卡送到
/// 一台装了 Anki 的「落地设备」，由它交给本机 Anki，再经官方客户端同步进 AnkiWeb。
///
/// 数据全在命名空间 [namespace] 下（已登记为同步保留目录，不会被当成书），全部是
/// **只由一台设备写**的文件，没有合并逻辑：
/// * `landing.<deviceId>.json`：该设备的落地认领 `{deviceId, deviceName, claimedAt}`。
///   每台设备只写 / 删自己那份；读时 `claimedAt` 最大者是落地设备。关掉开关就删掉
///   自己那份——认领随之撤销。
/// * `<id>.json`：一张待发卡 `{id, createdAt, expression, reading, originDeviceId,
///   payload}`，由制卡设备写。
/// * `<id>.landed.json`：落地回执，由落地设备在交给 Anki 后写；制卡设备看到回执
///   撤记录与回执、删本地行。
///
/// 本机既没认领、也没有任何需要中转的行时，本轮**一个请求都不发**。有卡但没有任何
/// 设备认领落地时，只列一次目录，不上传——没人要的卡不外流。
///
/// 收敛纪律：每一步先把本地意图落库，再改远端；任何两步之间进程被杀，下一轮都能
/// 从库里的状态继续。重复落地（落地后、写回执前被杀）由落地设备 Anki 查重兜底。
///
/// 幂等键是记录 id（BUG-2778）：
/// * 已上传的卡只由落地设备落，制卡设备本机不再补发（[PendingMineStore.sendable]）；
///   本机自己成了落地设备时先撤回远端记录，再回到本机补发。
/// * 同一张卡可能经多条同步通道（每条通道各一个本类实例）各传一份。落地设备落过
///   的 id 留本地墓碑（[PendingMineStore.hasLanded]），任一通道再见到同 id 不收，
///   只写回执、撤记录。
/// * 远端 id 来自对端文件名，不合 [PendingMineStore.isValidId] 的记录直接跳过。
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

  /// 中转命名空间名（同步保留目录，见 `isReservedSyncFolderName`）。
  static const String namespace = '__pending_mines__';

  /// 单张卡的上限。各后端的 JSON 读取有 10 MB 上限（WebDAV / Google Drive），
  /// 载荷里的媒体是 base64 内联的；超限的卡留在本机，不走中转。
  static const int maxRecordBytes = 9 * 1024 * 1024;

  static const String _claimPrefix = 'landing.';
  static const String _landedSuffix = '.landed.json';
  static const String _recordSuffix = '.json';

  final PendingMineStore _store;
  final String _deviceId;
  final String _deviceName;

  /// 本机「作为落地设备」开关打开的时刻（毫秒）；0 = 关。
  final int _landingClaimedAt;
  final int Function() _clock;

  String get _myClaim => '$_claimPrefix$_deviceId.json';

  Future<PendingMineRelayReport> run(SyncAssetStore assets) async {
    final List<PendingMineRow> rows = await _store.rows();
    // 没开落地、也没有要中转的卡：不碰远端。旧开关关掉后遗留的认领，在本机下一次
    // 有卡要中转、或重新打开开关时顺带处理。
    if (_landingClaimedAt <= 0 && !rows.any(_needsRelay)) {
      return const PendingMineRelayReport();
    }

    final String ns = await assets.ensureNamespace(namespace);
    final Map<String, AssetEntry> entries = <String, AssetEntry>{
      for (final AssetEntry e in await assets.listChildren(ns))
        if (!e.isFolder) e.name: e,
    };
    final List<String> errors = <String>[];

    final String? landingId = await _resolveLanding(
      assets,
      ns,
      entries,
      errors,
    );
    final bool amLanding = landingId == _deviceId;

    int uploaded = 0;
    int received = 0;
    int acknowledged = 0;

    // ── 本机制的卡 ──────────────────────────────────────────────────────────
    for (final PendingMineRow row in rows) {
      if (row.originDeviceId != null) continue;
      try {
        switch (await _relayOwn(assets, ns, entries, row, landingId)) {
          case _Step.uploaded:
            uploaded++;
          case _Step.acknowledged:
            acknowledged++;
          case _Step.none:
            break;
        }
      } catch (e) {
        errors.add('${row.id}: $e');
      }
    }

    // ── 收来的卡 ────────────────────────────────────────────────────────────
    if (amLanding) {
      final Set<String> local = <String>{
        for (final PendingMineRow r in rows) r.id,
      };
      for (final MapEntry<String, AssetEntry> e in entries.entries) {
        final String? id = _recordId(e.key);
        if (id == null || local.contains(id)) continue;
        if (entries.containsKey('$id$_landedSuffix')) continue;
        try {
          if (await _store.hasLanded(id)) {
            // 本机已经落过这张（另一条同步通道送来的同一张卡）：不再收，写回执让
            // 制卡设备出队，撤掉这条通道上的副本。
            await _writeReceipt(assets, ns, id);
            await assets.deleteAsset(e.value.id);
            acknowledged++;
            continue;
          }
          if (await _receive(assets, id, e.value)) received++;
        } catch (err) {
          // 单张坏卡 / 超限不能挡住其余的卡与后面的回执。
          errors.add('$id: $err');
        }
      }
    }
    for (final PendingMineRow row in await _store.rows()) {
      if (row.originDeviceId == null) continue;
      try {
        if (await _settleReceived(assets, ns, entries, row, amLanding)) {
          acknowledged++;
        }
      } catch (e) {
        errors.add('${row.id}: $e');
      }
    }

    if (received > 0) _arrivals.add(received);
    return PendingMineRelayReport(
      uploaded: uploaded,
      received: received,
      acknowledged: acknowledged,
      errors: errors,
    );
  }

  /// 这一行需要和远端打交道吗。
  bool _needsRelay(PendingMineRow row) =>
      row.originDeviceId != null ||
      row.uploaded ||
      row.status == PendingMineStatus.pending ||
      row.status == PendingMineStatus.failed;

  /// 认领：写 / 撤本机那份，返回当前落地设备（claimedAt 最大者）。
  Future<String?> _resolveLanding(
    SyncAssetStore assets,
    String ns,
    Map<String, AssetEntry> entries,
    List<String> errors,
  ) async {
    final AssetEntry? mine = entries[_myClaim];
    if (_landingClaimedAt > 0) {
      await assets.putJsonAsset(ns, _myClaim, <String, Object?>{
        'deviceId': _deviceId,
        'deviceName': _deviceName,
        'claimedAt': _landingClaimedAt,
      });
    } else if (mine != null) {
      await assets.deleteAsset(mine.id);
    }

    String? best = _landingClaimedAt > 0 ? _deviceId : null;
    int bestAt = _landingClaimedAt;
    for (final MapEntry<String, AssetEntry> e in entries.entries) {
      if (!e.key.startsWith(_claimPrefix) || e.key == _myClaim) continue;
      try {
        final Object? json = await assets.getJsonAsset(e.value.id);
        if (json is! Map) continue;
        final Object? id = json['deviceId'];
        final int at = (json['claimedAt'] as num?)?.toInt() ?? 0;
        if (id is String && id.isNotEmpty && at > bestAt) {
          best = id;
          bestAt = at;
        }
      } catch (err) {
        errors.add('${e.key}: $err');
      }
    }
    return best;
  }

  Future<_Step> _relayOwn(
    SyncAssetStore assets,
    String ns,
    Map<String, AssetEntry> entries,
    PendingMineRow row,
    String? landingId,
  ) async {
    final AssetEntry? receipt = entries['${row.id}$_landedSuffix'];
    final AssetEntry? record = entries['${row.id}$_recordSuffix'];

    if (receipt != null || row.status == PendingMineStatus.landed) {
      // 落地设备交过了，或本机自己交过 / 用户删了。先把意图落库（landed），再清远端，
      // 最后删行——任何一步之后被杀，下一轮从 landed 接着清。
      if (row.status != PendingMineStatus.landed) {
        await _store.markDelivered(row);
      }
      if (record != null) await assets.deleteAsset(record.id);
      if (receipt != null) await assets.deleteAsset(receipt.id);
      await _store.remove(row.id);
      return _Step.acknowledged;
    }

    if (landingId == _deviceId) {
      // 本机成了落地设备：上传过的卡撤回远端记录，交回本机补发。先撤远端再清标记——
      // 两步之间被杀，下一轮照样「上传过、记录不在」→ 再清一次标记。
      if (!row.uploaded) return _Step.none;
      if (record != null) await assets.deleteAsset(record.id);
      await _store.clearUploaded(row.id);
      return _Step.none;
    }
    if (landingId == null) return _Step.none;
    if (row.status == PendingMineStatus.sending) return _Step.none;
    // 已上传且远端记录还在：等落地设备。上传过但记录不在（上次 PUT 失败）：重传。
    if (row.uploaded && record != null) return _Step.none;

    final String? payload = await _store.readPayloadJson(row.id);
    if (payload == null) return _Step.none;
    final Map<String, Object?> body = <String, Object?>{
      'id': row.id,
      'createdAt': row.createdAt,
      'expression': row.expression,
      'reading': row.reading,
      'originDeviceId': _deviceId,
      'payload': jsonDecode(payload),
    };
    if (utf8.encode(jsonEncode(body)).length > maxRecordBytes) {
      await _store.markFailed(
        row.id,
        'Too large to send to another device (over '
        '${maxRecordBytes ~/ (1024 * 1024)} MB of media).',
      );
      return _Step.none;
    }
    // 先落库「已上传」的意图：与补发并发时，补发看到它就不会直接删行（远端那份
    // 就有人撤）。PUT 失败时下一轮按「上传过但记录不在」重传。本机补发已经认领了
    // 这张（sending）时不成立——不上传，免得两边各落一张。
    if (!await _store.markUploaded(row.id)) return _Step.none;
    await assets.putJsonAsset(ns, '${row.id}$_recordSuffix', body);
    return _Step.uploaded;
  }

  /// 收来的一张卡：交过了写回执撤记录；制卡设备已撤记录、或本机不再是落地设备就交出。
  Future<bool> _settleReceived(
    SyncAssetStore assets,
    String ns,
    Map<String, AssetEntry> entries,
    PendingMineRow row,
    bool amLanding,
  ) async {
    final AssetEntry? record = entries['${row.id}$_recordSuffix'];
    if (row.status == PendingMineStatus.landed) {
      // 不看本机此刻是不是落地设备：交过的卡回执照样要写。
      await _writeReceipt(assets, ns, row.id);
      if (record != null) await assets.deleteAsset(record.id);
      await _store.remove(row.id);
      return true;
    }
    // 制卡设备自己交给 Anki 了 / 用户在那边删了：远端记录已撤，本机别再落。
    // 本轮刚收下的行，其记录必在 entries 里，不会走到这里。正在交给 Anki 的
    // （sending）不能删：删了它，落完后 markDelivered 找不到行、留不下墓碑，别的
    // 通道再送来同一张就会再落一次（BUG-2778）。
    if (record == null) {
      if (row.status != PendingMineStatus.sending) await _store.remove(row.id);
      return false;
    }
    // 落地设备易主：还没交的卡交给新落地设备（它会从远端记录收下），本机别再落，
    // 否则两边各落一次。正在拉起中的（sending）让它走完。
    if (!amLanding && row.status != PendingMineStatus.sending) {
      await _store.remove(row.id);
    }
    return false;
  }

  Future<void> _writeReceipt(SyncAssetStore assets, String ns, String id) =>
      assets.putJsonAsset(ns, '$id$_landedSuffix', <String, Object?>{
        'landedAt': _clock(),
        'landedBy': _deviceId,
      });

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
  ///
  /// 文件名来自同步后端，任何能写这块目录的一方都能放进来：id 要拼进本机载荷
  /// 路径，不合白名单（`..`、分隔符、过长）的一律丢弃并记日志（BUG-2778）。
  static String? _recordId(String name) {
    if (name.startsWith(_claimPrefix) || name.endsWith(_landedSuffix)) {
      return null;
    }
    if (!name.endsWith(_recordSuffix)) return null;
    final String id = name.substring(0, name.length - _recordSuffix.length);
    if (!PendingMineStore.isValidId(id)) {
      engineLog.logDiagnostic(
        'PendingMineRelay.recordId',
        'skip relay record with invalid id: ${jsonEncode(name)}',
      );
      return null;
    }
    return id;
  }
}

enum _Step { none, uploaded, acknowledged }

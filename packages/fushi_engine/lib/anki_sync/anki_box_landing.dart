import 'dart:io';

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart' show PendingMineRow;

import 'package:fushi_engine/anki_sync/pending_mine_relay.dart';
import 'package:fushi_engine/anki_sync/pending_mine_store.dart';
import 'package:fushi_engine/sync/forwarded_mine_materialize.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart' show AssetEntry;

/// 把一张卡落进本机 Anki 的回调（`rawPayloadJson` + 已还原的 context）。
typedef AnkiLandingMine =
    Future<MineOutcome> Function(
      String rawPayloadJson,
      AnkiMiningContext context,
    );

class AnkiBoxLandingReport {
  const AnkiBoxLandingReport({
    this.received = 0,
    this.delivered = 0,
    this.failed = 0,
    this.waiting = 0,
    this.errors = const <String>[],
  });

  /// 这一轮从目录收下的卡。
  final int received;

  /// 落进 Anki 的卡（含 Anki 里本来就有、按重复算送达的）。
  final int delivered;

  /// 落不进去、标成失败的卡（管理页可重试）。
  final int failed;

  /// 因为没配置 / 没登录而留着等下一轮的卡。
  final int waiting;
  final List<String> errors;
}

/// 互联主机（无头服务端 / 桌面 app）直接对**自己的**同步目录当落地设备。
///
/// 手机经互联同步把待发卡写进主机磁盘上的 `<sync-data>/fushi-data/__pending_mines__/`。
/// 主机用 [LocalDirectoryAssetStore] 对这块目录跑与客户端完全相同的 [PendingMineRelay]
/// （认领 / 收卡 / 回执 / 易主都是同一份代码），收下的卡还原媒体后交给 [mine] 落进 Anki，
/// 落完再跑一轮中转写回执——制卡设备看到回执才出队。
class AnkiBoxLanding {
  AnkiBoxLanding({
    required Directory syncRoot,
    required PendingMineStore store,
    required String deviceId,
    required String deviceName,
    required int Function() landingClaimedAt,
    required AnkiLandingMine mine,
    int Function()? clock,
  }) : _assets = LocalDirectoryAssetStore(syncRoot),
       _store = store,
       _deviceId = deviceId,
       _deviceName = deviceName,
       _landingClaimedAt = landingClaimedAt,
       _mine = mine,
       _clock = clock;

  final LocalDirectoryAssetStore _assets;
  final PendingMineStore _store;
  final String _deviceId;
  final String _deviceName;
  final int Function() _landingClaimedAt;
  final AnkiLandingMine _mine;
  final int Function()? _clock;

  Future<void> _tail = Future<void>.value();

  /// 跑一轮。多次并发调用会排队串行（定时器与「立即同步」按钮可能撞在一起）。
  Future<AnkiBoxLandingReport> runOnce() => _queued(_run);

  /// 排在所有已提交操作之后完成（停机时等在跑的那一轮落完）。
  Future<void> get idle => _tail;

  Future<T> _queued<T>(Future<T> Function() action) {
    final Future<T> run = _tail.then((_) => action());
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<AnkiBoxLandingReport> _run() async {
    final List<String> errors = <String>[];
    final PendingMineRelayReport inbound = await _relay().run(_assets);
    errors.addAll(inbound.errors);

    int delivered = 0;
    int failed = 0;
    int waiting = 0;
    for (final PendingMineRow row in await _store.sendable()) {
      if (row.originDeviceId == null) continue;
      switch (await _land(row)) {
        case _Landed.delivered:
          delivered++;
        case _Landed.failed:
          failed++;
        case _Landed.waiting:
          waiting++;
          // 没配置 / 没登录：后面的卡也全会撞墙，停下等下一轮。
          break;
        case _Landed.skipped:
          break;
      }
      if (waiting > 0) break;
    }

    if (delivered > 0) {
      // 落完立刻写回执，制卡设备下次同步就能出队。
      errors.addAll((await _relay().run(_assets)).errors);
    }
    return AnkiBoxLandingReport(
      received: inbound.received,
      delivered: delivered,
      failed: failed,
      waiting: waiting,
      errors: errors,
    );
  }

  /// 关掉落地时立刻撤掉本机的认领文件。
  ///
  /// 中转层只在本机有卡要中转时才顺带撤认领（客户端迟早会有卡）；主机自己从不制卡，
  /// 不显式撤的话认领会一直挂着，别的设备就一直把卡传给一台已经不收卡的主机。
  ///
  /// 与 [runOnce] 同一条队列：正在跑的那一轮开头会写认领，撤销必须排在它后面，
  /// 否则认领被写回去、再也没人撤。
  Future<void> revokeClaim() => _queued(() async {
    final String ns = await _assets.ensureNamespace(PendingMineRelay.namespace);
    final AssetEntry? mine = await _assets.findAsset(
      ns,
      'landing.$_deviceId.json',
    );
    if (mine != null) await _assets.deleteAsset(mine.id);
  });

  PendingMineRelay _relay() => PendingMineRelay(
    store: _store,
    deviceId: _deviceId,
    deviceName: _deviceName,
    landingClaimedAt: _landingClaimedAt(),
    clock: _clock,
  );

  Future<_Landed> _land(PendingMineRow row) async {
    final ForwardedMinePayload? payload = await _store.readPayload(row.id);
    if (payload == null) {
      await _store.markFailed(row.id, 'The card data could not be read.');
      return _Landed.failed;
    }
    if (!await _store.markSending(row.id)) return _Landed.skipped;
    final MineOutcome outcome;
    try {
      // 收来的卡全部来自其他设备：只认随附的媒体字节（BUG-2773）。
      outcome = await withMaterializedMiningContext<MineOutcome>(
        payload,
        _mine,
        bundledMediaOnly: true,
      );
    } catch (e) {
      await _store.markFailed(row.id, '$e');
      return _Landed.failed;
    }
    switch (outcome.result) {
      case MineResult.success:
      case MineResult.duplicate:
        await _store.markDelivered(row);
        return _Landed.delivered;
      case MineResult.notConfigured:
        await _store.markPending(row.id, error: 'Anki is not configured.');
        return _Landed.waiting;
      case MineResult.queued:
        await _store.markPending(row.id);
        return _Landed.waiting;
      case MineResult.error:
        final String detail = outcome.errorDetail ?? 'Unknown error';
        if (outcome.errorCode == AnkiErrorCode.syncClientSignedOut ||
            outcome.errorCode == AnkiErrorCode.syncClientUnavailable) {
          await _store.markPending(row.id, error: detail);
          return _Landed.waiting;
        }
        await _store.markFailed(row.id, detail);
        return _Landed.failed;
    }
  }
}

enum _Landed { delivered, failed, waiting, skipped }

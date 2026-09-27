import 'dart:async';
import 'dart:convert';

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart'
    show PendingMineRow, PendingMineStatus;
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';

import 'package:fushi/src/anki/delegating_anki_repository.dart';
import 'package:fushi/src/anki/forwarded_mine_codec.dart';
import 'package:fushi/src/anki/pending_mining/pending_mine_store.dart';

/// 打开一个 URL（AnkiMobile 的 `anki://x-callback-url/sync`）。
typedef PendingMineUrlOpener = Future<bool> Function(Uri uri);

/// AnkiMobile 同步入口（官方手册 URL Schemes 一节）。
final Uri ankiMobileSyncUri = Uri.parse('anki://x-callback-url/sync');

/// 一次补发的结果。
class PendingFlushReport {
  const PendingFlushReport({
    this.delivered = 0,
    this.failed = 0,
    this.remaining = 0,
    this.unreachable = false,
    this.skipped = false,
    this.awaitingConfirmation = false,
  });

  /// 送进 Anki（或 Anki 说已经有了）的张数。
  final int delivered;

  /// 这一轮被 Anki 拒收、停在「失败」的张数。
  final int failed;

  /// 这一轮结束后队列里还剩几张可补发的。
  final int remaining;

  /// 这一轮因后端不可达而提前停下。
  final bool unreachable;

  /// 这一轮根本没跑（例如 AnkiMobile 上的自动触发）。
  final bool skipped;

  /// 已拉起 AnkiMobile，正等它加完卡回跳确认（那张仍在队列里）。
  final bool awaitingConfirmation;
}

/// 这次失败是不是「确定没送到」——只有这种才能放心入队、之后原样重发。
///
/// * `connectionRefused`：建连就没成（Anki 没开 / 地址不通）。
/// * `pairedDeviceUnreachable`：互联远端制卡时一个已配对设备都连不上。
///
/// 刻意**不**包括：`connectionTimeout`（连上了、请求可能已发出）、
/// `connectionUnknown`（含 AnkiConnect「提交结果未知」与远端兜底异常）——卡可能
/// 已经建好，自动重发会造出重复卡，这类仍按原样报失败给用户。
bool isUndeliveredMineFailure(MineOutcome outcome) =>
    outcome.result == MineResult.error &&
    (outcome.errorCode == AnkiErrorCode.connectionRefused ||
        outcome.errorCode == AnkiErrorCode.pairedDeviceUnreachable);

/// 待发制卡队列的仓库层接线：包在制卡链路最外层。
///
/// * 批量模式（[AnkiSettings.batchMiningEnabled]）：制卡一律冻结进队列，返回
///   [MineOutcome.queued]。
/// * 否则照常交给 [inner]；若结果是「确定没送到」（[isUndeliveredMineFailure]），
///   把这张卡冻结进队列，返回 [MineOutcome.queued] 而不是让它丢掉。
/// * 一次直接制卡成功说明后端此刻可达，顺手触发一轮自动补发。
///
/// 冻结必须在 [mineEntry] 返回前完成：调用方在它返回后就清理临时封面 / 句子音频。
///
/// 补发 [flush] 用 [inner] 重放——那条链路里还有自动重排等装饰器，补发进去的卡与
/// 直接制的卡待遇一致。
class PendingMiningAnkiRepository extends DelegatingAnkiRepository {
  PendingMiningAnkiRepository({
    required super.inner,
    required PendingMineStore store,
    ForwardedMinePayloadBuilder? payloadBuilder,
    PendingMineUrlOpener? openUrl,
  }) : _store = store,
       _payloadBuilder = payloadBuilder ?? ForwardedMinePayloadBuilder(),
       _openUrl = openUrl;

  final PendingMineStore _store;
  final ForwardedMinePayloadBuilder _payloadBuilder;
  final PendingMineUrlOpener? _openUrl;

  PendingMineStore get store => _store;

  /// 进程内的补发串行锁。provider 重建会换掉仓库实例，锁必须跨实例——否则回前台
  /// 的自动补发与用户点的「全部发送」各读一遍同一批行，同一张卡会被送两次。
  static Future<void> _tail = Future<void>.value();

  /// 测试用：复位跨实例的静态状态。
  static void debugReset() {
    _tail = Future<void>.value();
  }

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final AnkiSettings settings = await inner.loadSettings();
    if (settings.batchMiningEnabled) {
      return _enqueueOr(
        rawPayloadJson: rawPayloadJson,
        context: context,
        fallback: null,
      );
    }
    final MineOutcome outcome = await inner.mineEntry(
      rawPayloadJson: rawPayloadJson,
      context: context,
    );
    if (isUndeliveredMineFailure(outcome)) {
      return _enqueueOr(
        rawPayloadJson: rawPayloadJson,
        context: context,
        fallback: outcome,
      );
    }
    if (outcome.result == MineResult.success && !inner.switchesAppPerNote) {
      // 后台补发失败只影响那几张待发卡（它们留在队列里），不能冒泡成未处理异常。
      unawaited(flush().then((_) {}, onError: (Object _) {}));
    }
    return outcome;
  }

  /// 冻结进队列。冻结本身失败（磁盘满、数据库关闭）时：有 [fallback] 就原样报
  /// 那个失败，没有（批量模式）就报一个说明原因的失败——绝不假装入队成功。
  Future<MineOutcome> _enqueueOr({
    required String rawPayloadJson,
    required AnkiMiningContext context,
    required MineOutcome? fallback,
  }) async {
    try {
      final ForwardedMinePayload payload = await _payloadBuilder.build(
        rawPayloadJson: rawPayloadJson,
        context: context,
      );
      final (String expression, String reading) = _displayKey(
        rawPayloadJson,
        context,
      );
      await _store.enqueue(payload, expression: expression, reading: reading);
      return const MineOutcome.queued();
    } catch (e, st) {
      return fallback ??
          MineOutcome.failure(
            'Could not save the card to the pending queue: $e',
            error: e,
            stackTrace: st,
          );
    }
  }

  /// 列表显示用的（词条, 读音）：取 fields 的 expression / reading，取不到用句子。
  static (String, String) _displayKey(
    String rawPayloadJson,
    AnkiMiningContext context,
  ) {
    try {
      final Object? json = jsonDecode(rawPayloadJson);
      if (json is Map) {
        final String expression = (json['expression'] as String?)?.trim() ?? '';
        final String reading = (json['reading'] as String?)?.trim() ?? '';
        if (expression.isNotEmpty) return (expression, reading);
      }
    } catch (_) {}
    return (context.sentence.trim(), '');
  }

  /// 补发队列里的卡。
  ///
  /// 连续补发所有可补发的卡，遇到「后端不可达」就停下（剩下的也必然不可达）。
  ///
  /// 每张卡都要切 app 的后端（AnkiMobile，[BaseAnkiRepository.switchesAppPerNote]）
  /// 走另一条路：只有用户显式点「全部发送」（[interactive]）才发，而且一次只发
  /// 一张——之后由 AnkiMobile 的 `x-success` 回跳（[confirmAnkiMobileDelivery]）确认
  /// 这张、再发下一张。回前台等自动触发对它一律跳过：用户只是切回 Fushi，不该被
  /// 拉去 AnkiMobile。
  Future<PendingFlushReport> flush({bool interactive = false}) => _serialized(
    () => inner.switchesAppPerNote
        ? _startAnkiMobileSend(interactive: interactive)
        : _flushAll(),
  );

  /// AnkiMobile 加完卡回跳（`fushi://ankiSuccess?expression=…`）：确认那张已进 Anki、
  /// 出队；还有就拉起下一张。连发链到此为止（发完了，或下一张没能拉起）时请 AnkiMobile
  /// 同步一次——此刻至少这一张确实已经存进 AnkiMobile。
  ///
  /// 「正在等哪张」只看库里的 `sending` 行，不靠内存：切到 AnkiMobile 期间 Fushi 被
  /// iOS 杀掉、由回跳冷启动时照样能确认。对不上任何 `sending` 行的回跳（来自一张
  /// 直接制的卡）什么都不做。
  Future<void> confirmAnkiMobileDelivery(String expression) =>
      _serialized<void>(() async {
        final String key = expression.trim();
        final PendingMineRow? row = (await _store.rows())
            .where(
              (PendingMineRow r) =>
                  r.status == PendingMineStatus.sending && r.expression == key,
            )
            .firstOrNull;
        if (row == null) return;
        await _store.markDelivered(row);
        final PendingFlushReport next = await _sendNextToAnkiMobile();
        if (!next.awaitingConfirmation) await _openUrl?.call(ankiMobileSyncUri);
      });

  Future<T> _serialized<T>(Future<T> Function() body) {
    final Completer<T> done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await body());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<PendingFlushReport> _flushAll() async {
    try {
      await _store.sweepOrphanPayloads();
    } catch (_) {
      // 清理孤儿文件失败不影响补发。
    }
    int delivered = 0;
    int failed = 0;
    for (final PendingMineRow row in await _store.sendable()) {
      switch (await _sendOne(row)) {
        case _SendResult.delivered:
          delivered++;
        case _SendResult.failed:
          failed++;
        case _SendResult.opened:
          // 只有 switchesAppPerNote 的后端会「只拉起、未确认」，不走这条路。
          break;
        case _SendResult.unreachable:
          return PendingFlushReport(
            delivered: delivered,
            failed: failed,
            remaining: (await _store.sendable()).length,
            unreachable: true,
          );
      }
    }
    return PendingFlushReport(
      delivered: delivered,
      failed: failed,
      remaining: (await _store.sendable()).length,
    );
  }

  /// 用户点「全部发送」。还停在 `sending` 的卡（用户在 AnkiMobile 里取消后手动切回、
  /// 或回跳没送达）先核对一次：后端认得它（AnkiMobile 的本机账本记过这个词）就算已
  /// 送达出队，否则退回 `pending` 重发。然后拉起一张。
  Future<PendingFlushReport> _startAnkiMobileSend({
    required bool interactive,
  }) async {
    if (!interactive) return const PendingFlushReport(skipped: true);
    for (final PendingMineRow row in await _store.rows()) {
      if (row.status != PendingMineStatus.sending) continue;
      if (await inner.isDuplicate(row.expression, row.reading)) {
        await _store.markDelivered(row);
      } else {
        await _store.markPending(row.id);
      }
    }
    return _sendNextToAnkiMobile();
  }

  /// 按顺序找下一张能拉起的卡拉起它（行停在 `sending` 等回跳）。
  Future<PendingFlushReport> _sendNextToAnkiMobile() async {
    int failed = 0;
    for (final PendingMineRow row in await _store.sendable()) {
      switch (await _sendOne(row)) {
        case _SendResult.opened:
          return PendingFlushReport(
            failed: failed,
            remaining: (await _store.sendable()).length,
            awaitingConfirmation: true,
          );
        case _SendResult.delivered:
          // Anki 判重复：已在库里，看下一张。
          continue;
        case _SendResult.failed:
          failed++;
        case _SendResult.unreachable:
          return PendingFlushReport(
            failed: failed,
            remaining: (await _store.sendable()).length,
            unreachable: true,
          );
      }
    }
    return PendingFlushReport(failed: failed);
  }

  /// 送一张。永不抛：任何意外（读不到载荷、落文件失败、后端违约抛异常）都把这张
  /// 标成 failed 让用户处理，而不是当成「不可达」——那样它会永远挡在队首。
  Future<_SendResult> _sendOne(PendingMineRow row) async {
    try {
      await _store.markSending(row.id);
      final ForwardedMinePayload? payload = await _store.readPayload(row.id);
      if (payload == null) {
        await _store.markFailed(row.id, 'The saved card data is missing.');
        return _SendResult.failed;
      }
      final MineOutcome outcome = await withMaterializedMiningContext(
        payload,
        (String raw, AnkiMiningContext context) =>
            inner.mineEntry(rawPayloadJson: raw, context: context),
      );
      return await _record(row, outcome);
    } catch (e) {
      try {
        await _store.markFailed(row.id, '$e');
      } catch (_) {}
      return _SendResult.failed;
    }
  }

  Future<_SendResult> _record(PendingMineRow row, MineOutcome outcome) async {
    switch (outcome.result) {
      case MineResult.success:
        if (inner.switchesAppPerNote) return _SendResult.opened;
        await _store.markDelivered(row);
        return _SendResult.delivered;
      case MineResult.duplicate:
        // Anki 里已经有这张卡（例如上次送到了但没来得及出队）——同样算送达。
        await _store.markDelivered(row);
        return _SendResult.delivered;
      case MineResult.notConfigured:
        // 没选牌组 / 笔记类型：后面的卡也全会撞墙，停下等用户配置。
        await _store.markPending(row.id, error: 'Anki is not configured.');
        return _SendResult.unreachable;
      case MineResult.queued:
        // inner 不套本装饰器，不会出现；按「这次没送出去」处理。
        await _store.markPending(row.id);
        return _SendResult.unreachable;
      case MineResult.error:
        final String detail = outcome.errorDetail ?? 'Unknown error';
        if (isUndeliveredMineFailure(outcome)) {
          await _store.markPending(row.id, error: detail);
          return _SendResult.unreachable;
        }
        await _store.markFailed(row.id, detail);
        return _SendResult.failed;
    }
  }
}

/// [opened]：每张卡都切 app 的后端已拉起、等回跳确认（行仍在队列里）。
enum _SendResult { delivered, opened, failed, unreachable }

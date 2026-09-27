import 'dart:async';
import 'dart:convert';

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart' show PendingMineRow;
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

  /// AnkiMobile 的「全部发送」会话：用户点了以后，每次 app 回到前台（AnkiMobile
  /// 加完卡 `x-success` 跳回）就发下一张，直到队列清空。跨实例，理由同 [_tail]。
  static bool _ankiMobileSessionActive = false;

  /// 测试用：复位跨实例的静态状态。
  static void debugReset() {
    _tail = Future<void>.value();
    _ankiMobileSessionActive = false;
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
  /// [interactive] = 用户显式点了「全部发送」。每张卡都要切 app 的后端（AnkiMobile）
  /// 只在 [interactive] 或已开启的发送会话里才发，且一次只发一张；其余后端连续发完
  /// 所有可补发的卡，遇到「后端不可达」就停下（剩下的也必然不可达）。
  Future<PendingFlushReport> flush({bool interactive = false}) {
    final Completer<PendingFlushReport> done = Completer<PendingFlushReport>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await _flushLocked(interactive: interactive));
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<PendingFlushReport> _flushLocked({required bool interactive}) async {
    final bool oneAtATime = inner.switchesAppPerNote;
    if (oneAtATime) {
      if (interactive) _ankiMobileSessionActive = true;
      if (!_ankiMobileSessionActive) {
        return const PendingFlushReport(skipped: true);
      }
    }
    final List<PendingMineRow> rows = await _store.sendable();
    if (rows.isEmpty) return _finishSession(const PendingFlushReport());

    int delivered = 0;
    int failed = 0;
    for (final PendingMineRow row in rows) {
      final _SendResult r = await _sendOne(row);
      switch (r) {
        case _SendResult.delivered:
          delivered++;
        case _SendResult.failed:
          failed++;
        case _SendResult.unreachable:
          return PendingFlushReport(
            delivered: delivered,
            failed: failed,
            remaining: (await _store.sendable()).length,
            unreachable: true,
          );
      }
      if (oneAtATime) break;
    }
    final int remaining = (await _store.sendable()).length;
    final PendingFlushReport report = PendingFlushReport(
      delivered: delivered,
      failed: failed,
      remaining: remaining,
    );
    return remaining == 0 ? _finishSession(report) : report;
  }

  /// AnkiMobile 会话发完最后一张：请 AnkiMobile 同步一次，结束会话。
  Future<PendingFlushReport> _finishSession(PendingFlushReport report) async {
    if (!_ankiMobileSessionActive) return report;
    _ankiMobileSessionActive = false;
    await _openUrl?.call(ankiMobileSyncUri);
    return report;
  }

  Future<_SendResult> _sendOne(PendingMineRow row) async {
    await _store.markSending(row.id);
    final ForwardedMinePayload? payload = await _store.readPayload(row.id);
    if (payload == null) {
      await _store.markFailed(row.id, 'The saved card data is missing.');
      return _SendResult.failed;
    }
    final MineOutcome outcome;
    try {
      outcome = await withMaterializedMiningContext<MineOutcome>(
        payload,
        (String raw, AnkiMiningContext context) =>
            inner.mineEntry(rawPayloadJson: raw, context: context),
      );
    } catch (e) {
      await _store.markPending(row.id, error: '$e');
      return _SendResult.unreachable;
    }
    switch (outcome.result) {
      case MineResult.success:
      case MineResult.duplicate:
        // 重复 = Anki 里已经有这张卡（例如上次送到了但没来得及出队）——同样出队。
        await _store.remove(row.id);
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

enum _SendResult { delivered, failed, unreachable }

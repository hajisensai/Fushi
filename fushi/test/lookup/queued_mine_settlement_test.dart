// 反馈 Va3bdT-X0r（BUG-5386 遗留）：gal 查词制卡转后台写入后，结局按编号推回 app 外
// 查词卡；失败可重试的入口是一次性的（查词卡与主窗 toast 共用）。
//
// popup.js 收推送的行为在 test/utils/misc/popup_asset_behavior_test.js（「queued mine
// settlement」段，node 真跑），host 转发在 test/lookup/global_lookup_host_test.mjs。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/queued_mine_settlement.dart';
import 'package:fushi/src/mining/gal_hook_mining_coordinator.dart';

import '../helpers/source_guard.dart';

void main() {
  group('QueuedMineJobs', () {
    test('编号单调递增', () {
      final QueuedMineJobs jobs = QueuedMineJobs();
      final int a = jobs.mint();
      final int b = jobs.mint();
      expect(b, greaterThan(a));
    });

    test('重试入口一次性：先点的生效，后点的失效', () {
      final QueuedMineJobs jobs = QueuedMineJobs();
      final int job = jobs.mint();
      int runs = 0;
      jobs.armRetry(job, () => runs++);
      expect(jobs.canRetry(job), isTrue);
      expect(jobs.retry(job), isTrue);
      expect(jobs.retry(job), isFalse, reason: '查词卡与 toast 各点一次不得写两张');
      expect(runs, 1);
    });

    test('disarm 后不可重试；未登记的编号不可重试', () {
      final QueuedMineJobs jobs = QueuedMineJobs();
      final int job = jobs.mint();
      jobs.armRetry(job, () {});
      jobs.disarm(job);
      expect(jobs.retry(job), isFalse);
      expect(jobs.retry(999), isFalse);
    });

    test('超出容量时最老的先出', () {
      final QueuedMineJobs jobs = QueuedMineJobs(capacity: 2);
      final int a = jobs.mint();
      final int b = jobs.mint();
      final int c = jobs.mint();
      jobs
        ..armRetry(a, () {})
        ..armRetry(b, () {})
        ..armRetry(c, () {});
      expect(jobs.canRetry(a), isFalse);
      expect(jobs.canRetry(b), isTrue);
      expect(jobs.canRetry(c), isTrue);
    });
  });

  group('queuedMineOutcomeOf', () {
    test('写进 Anki = landed；真失败 = failed', () {
      expect(
        queuedMineOutcomeOf(success: true, queued: false),
        QueuedMineOutcome.landed,
      );
      expect(
        queuedMineOutcomeOf(success: false, queued: false),
        QueuedMineOutcome.failed,
      );
    });

    test('进本机待发 / 复习后台队列不是失败：不推，查词卡保持「已加入」', () {
      // 推 failed 会把按钮翻回 +，用户再点就在待发队列里多制一张。
      expect(queuedMineOutcomeOf(success: false, queued: true), isNull);
    });
  });

  group('settlement wire', () {
    test('toJson 只带有意义的字段', () {
      expect(
        const QueuedMineSettlement(
          job: 3,
          outcome: QueuedMineOutcome.failed,
          message: 'Anki 没开',
          retryable: true,
        ).toJson(),
        <String, Object?>{
          'job': 3,
          'outcome': 'failed',
          'message': 'Anki 没开',
          'retryable': true,
        },
      );
      expect(
        const QueuedMineSettlement(
          job: 4,
          outcome: QueuedMineOutcome.landed,
          noteId: 12,
        ).toJson(),
        <String, Object?>{'job': 4, 'outcome': 'landed', 'noteId': 12},
      );
    });

    test('宿主脚本带守卫，载荷是 JSON', () {
      const QueuedMineSettlement s = QueuedMineSettlement(
        job: 5,
        outcome: QueuedMineOutcome.requeued,
      );
      final String script = buildQueuedMineSettledScript(s);
      expect(script, startsWith('window.__globalLookupHost && '));
      expect(
        script,
        contains('window.__globalLookupHost.queuedMineSettled && '),
      );
      expect(script, contains(jsonEncode(s.toJson())));
    });

    test('queued 回包带编号', () {
      final Map<String, Object?> reply =
          GalHookMiningResult.queuedPopupReplyFor(8);
      expect(reply['queued'], isTrue);
      expect(reply['ankiConnect'], isFalse);
      expect(reply['queuedJob'], 8);
    });
  });

  test('GlobalLookupController 接 retryQueuedMine 桥，入口失效也回一条失败推送', () {
    final String src = File(
      'lib/src/lookup/global_lookup_controller.dart',
    ).readAsStringSync();
    final String onJs = compactCode(
      maskComments(methodBody(src, 'void _onJsMessage(')),
    );
    final int retry = onJs.indexOf("handler=='retryQueuedMine'");
    final int deferred = onJs.indexOf('maybeHandleOverlayDeferredBridge(');
    expect(retry, greaterThanOrEqualTo(0));
    expect(retry, lessThan(deferred));
    final String onRetry = compactCode(
      maskComments(methodBody(src, 'void _onRetryQueuedMine(')),
    );
    expect(
      onRetry.contains('QueuedMineOutcome.failed'),
      isTrue,
      reason: '按钮已画回「已加入」，入口失效时不回推送它就永远挂着',
    );
  });
}

// BUG-5386 / 反馈 y90oiVojic 的守卫：gal 查词弹窗（浮窗点词 + 游戏内查词）制卡只等
// **采样**，不等编码与写卡。
//
// 为什么用源码守卫：`_mineFromLookup` 是 GalHookTextOverlayController 的私有方法，结果
// 走 FushiToast（没有注入点的 static）；行为层面「采样完即返回、写卡可重试」已由
// `test/mining/gal_hook_mining_coordinator_test.dart` 的 y90oiVojic 组钉住，这里只钉
// 控制器不能退回去 await 整张卡。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

const String _controllerPath =
    'lib/src/lookup/gal_hook_text_overlay_controller.dart';

void main() {
  test('BUG-5386：新卡采样完即回 queued，写卡在后台落地', () {
    final String src = File(_controllerPath).readAsStringSync();
    final String body = compactCode(
      maskComments(
        methodBody(src, 'Future<Map<String, Object?>> _mineFromLookup('),
      ),
    );
    expect(
      body.contains('_miningCoordinator.mineLine('),
      isFalse,
      reason: 'mineLine 会等到写卡结束，弹窗按钮被锁约 10 秒（反馈 y90oiVojic）',
    );
    final int start = body.indexOf('_miningCoordinator.startMineLine(');
    final int queued = body.indexOf(
      '...GalHookMiningResult.queuedPopupReply,QueuedMineSettlements.tokenKey:settleToken,',
    );
    final int awaitFull = body.indexOf('awaitticket.result');
    expect(start, greaterThanOrEqualTo(0));
    expect(queued, greaterThan(start));
    expect(
      awaitFull,
      greaterThan(queued),
      reason: '只有采样失败 / 覆写既有卡才陪等完整结果，且必须排在 queued 分支之后',
    );
    expect(
      body.contains('ticket.captured&&updateNoteId==null'),
      isTrue,
      reason: '覆写（updateEntry 路径不认 queued）与采样失败必须继续陪等',
    );
  });

  test('BUG-5386：后台落地补记统计、通知制卡态、失败带重试', () {
    final String src = File(_controllerPath).readAsStringSync();
    final String body = compactCode(
      maskComments(
        methodBody(src, 'Future<void> _landLookupMineInBackground('),
      ),
    );
    expect(body.contains('recordOverlayMinedStats('), isTrue);
    expect(
      body.contains('settlements.land(settleToken'),
      isTrue,
      reason: '反馈 Va3bdT-X0r：落地结局要交给还在等的 app 外查词卡',
    );
    expect(
      body.contains('settlements.fail(settleToken'),
      isTrue,
      reason: '反馈 Va3bdT-X0r：失败先交给查词卡就地说，主窗 toast 只在 onUnseen 里',
    );
    // 进了本机待发队列（Anki 没开时 PendingMiningAnkiRepository 的结局）不是失败：
    // result.success 为假，若落到 fail 分支，查词卡会说「制卡失败」并翻回 +，诱导再制
    // 一张重复卡。queued 必须在 fail 之前分流成 offlineQueued 落地。
    final int queuedLand = body.indexOf(
      'settlements.land(settleToken,offlineQueued:true)',
    );
    expect(queuedLand, greaterThanOrEqualTo(0));
    final int queuedBranch = body.indexOf('if(result.queued)');
    expect(queuedBranch, greaterThanOrEqualTo(0));
    expect(queuedBranch, lessThan(queuedLand));
    expect(
      queuedLand,
      lessThan(body.indexOf('settlements.fail(settleToken')),
      reason: '待发队列的结局要在失败分支之前分流',
    );
    expect(
      body.contains('()=>settlements.retry(settleToken)'),
      isTrue,
      reason: '主窗 toast 的重试与卡上的重试必须经同一个收口，避免一次失败重写两次',
    );
    expect(body.contains('MinedStateSignal.instance.notifyWord('), isTrue);
    expect(
      body.contains('retryWrite(repo:model.miningAnkiRepository)'),
      isTrue,
      reason: '重试要写进点重试那一刻的制卡仓库（用户可能刚改了设置）',
    );
  });

  test('反馈 Va3bdT-X0r：app 外覆盖窗的结局推送通道接通（桥 + native deferred）', () {
    final String bridge = File(
      'lib/src/lookup/overlay_bridge_handlers.dart',
    ).readAsStringSync();
    expect(bridge.contains("case 'awaitMineSettled':"), isTrue);
    expect(bridge.contains("case 'retryQueuedMine':"), isTrue);
    expect(
      bridge.contains('QueuedMineSettlements.instance.bindOrigin('),
      isTrue,
      reason: '转交 queued 回包时要登记发起这张卡的在屏探针',
    );
    final String native = File(
      'windows/runner/global_lookup_window.cpp',
    ).readAsStringSync();
    for (final String name in <String>['awaitMineSettled', 'retryQueuedMine']) {
      expect(
        native.contains('body.find("\\"$name\\"")'),
        isTrue,
        reason: '$name 必须是 native deferred 桥，否则立即被回 null，卡永远等不到结局',
      );
    }
    final String channel = File(
      'lib/src/lookup/global_lookup_channel.dart',
    ).readAsStringSync();
    expect(
      channel.contains('QueuedMineSettlements.instance.recheckHeld()'),
      isTrue,
      reason: 'route 作废（关卡 / 换词）时压着的失败要改走主窗 toast',
    );
  });
}

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
      'returnGalHookMiningResult.queuedPopupReplyFor(job);',
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
    expect(body.contains('MinedStateSignal.instance.notifyWord('), isTrue);
    expect(
      body.contains('retryWrite(repo:model.miningAnkiRepository)'),
      isTrue,
      reason: '重试要写进点重试那一刻的制卡仓库（用户可能刚改了设置）',
    );
  });

  // 反馈 Va3bdT-X0r（BUG-5386 遗留）：结局只走主窗 toast 时，游戏全屏下写卡失败用户
  // 看不见。结局必须按编号推回 app 外查词卡，两处的「重试」共用同一个一次性入口。
  test('反馈 Va3bdT-X0r：后台结局推回查词卡，toast 重试走同一入口', () {
    final String src = File(_controllerPath).readAsStringSync();
    final String mine = compactCode(
      maskComments(
        methodBody(src, 'Future<Map<String, Object?>> _mineFromLookup('),
      ),
    );
    expect(
      mine.contains('GlobalLookupController.instance.beginQueuedMine()'),
      isTrue,
      reason: 'queued 回包要带编号，宿主才能按编号把结局推回这颗按钮',
    );
    final String land = compactCode(
      maskComments(
        methodBody(src, 'Future<void> _landLookupMineInBackground('),
      ),
    );
    expect(
      land.contains('lookup.settleQueuedMine('),
      isTrue,
      reason: '落地 / 失败必须推回 app 外查词卡（主窗 toast 游戏全屏时看不见）',
    );
    expect(
      land.contains('QueuedMineOutcome.requeued'),
      isTrue,
      reason: '重试重新排队时卡上要回到「已加入」',
    );
    expect(
      land.contains('()=>lookup.retryQueuedMine(job)'),
      isTrue,
      reason: 'toast 上的重试必须走与查词卡同一个一次性入口，否则两处各点一次写两张',
    );
  });
}

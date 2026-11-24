// 反馈 Va3bdT-X0r（BUG-5386 遗留）：gal 查词卡后台写卡的结局要能被 app 外查词卡等到，
// 失败原因恰好说一次——卡还在屏上就交给卡就地说，卡已关 / 换了词才走主窗 toast（onUnseen）。
// popup.js 那半（awaitMineSettled / retryQueuedMine 的按钮态）在
// test/utils/misc/popup_asset_behavior_test.js 的 testQueuedSettlement* 里由 node 真跑。

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/mine_failure_notice.dart';
import 'package:fushi/src/anki/queued_mine_settlement.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';

const Map<String, Object?> _failure = <String, Object?>{
  'ankiConnect': false,
  'noteId': null,
  'message': 'Anki 没开',
};

void main() {
  late QueuedMineSettlements settlements;
  late int unseen;
  void onUnseen() => unseen++;

  setUp(() {
    settlements = QueuedMineSettlements();
    unseen = 0;
  });

  tearDown(() => MineNotices.filter = (MineToastStatus _) => true);

  test('卡还在屏上：失败交给等待中的卡就地说，主窗不 toast', () async {
    final int token = settlements.open();
    settlements.bindOrigin(token, () => true);
    final Future<Map<String, Object?>> settled = settlements.wait(
      token,
      origin: () => true,
    );
    settlements.fail(
      token,
      failure: _failure,
      onUnseen: onUnseen,
      retry: () {},
    );
    expect(await settled, <String, Object?>{
      'settled': 'failed',
      'message': 'Anki 没开',
      'retryable': true,
    });
    expect(unseen, 0);
  });

  test('等待中的卡已关：主窗 toast 一次，回包标 hostReported 不带原因', () async {
    final int token = settlements.open();
    bool onScreen = true;
    settlements.bindOrigin(token, () => onScreen);
    final Future<Map<String, Object?>> settled = settlements.wait(
      token,
      origin: () => onScreen,
    );
    onScreen = false;
    settlements.fail(token, failure: _failure, onUnseen: onUnseen);
    final Map<String, Object?> reply = await settled;
    expect(reply['settled'], 'failed');
    expect(reply.containsKey('message'), isFalse);
    expect(reply[MineFailureNotice.hostReportedKey], isTrue);
    expect(unseen, 1);
  });

  test('失败抢在等待者之前：卡在屏上就压着，等待者到了就地说', () async {
    final int token = settlements.open();
    settlements.bindOrigin(token, () => true);
    settlements.fail(token, failure: _failure, onUnseen: onUnseen);
    expect(unseen, 0, reason: '卡还在：popup.js 的等待马上就到，不能先 toast');
    final Map<String, Object?> reply = await settlements.wait(
      token,
      origin: () => true,
    );
    expect(reply['message'], 'Anki 没开');
    expect(unseen, 0);
  });

  test('压着的失败：卡在等待者到来前关掉（route 作废）→ recheckHeld 改走 toast', () {
    final int token = settlements.open();
    bool onScreen = true;
    settlements.bindOrigin(token, () => onScreen);
    settlements.fail(token, failure: _failure, onUnseen: onUnseen);
    onScreen = false;
    settlements.recheckHeld();
    expect(unseen, 1);
    settlements.recheckHeld();
    expect(unseen, 1, reason: '恰好一次');
  });

  test('失败早于回包交付（探针未登记）：登记时卡已不在 → toast', () {
    final int token = settlements.open();
    settlements.fail(token, failure: _failure, onUnseen: onUnseen);
    expect(unseen, 0, reason: '回包还没交给卡，不知道卡在不在');
    settlements.bindOrigin(token, () => false);
    expect(unseen, 1);
  });

  test('落地：等待者拿到 landed + noteId', () async {
    final int token = settlements.open();
    final Future<Map<String, Object?>> settled = settlements.wait(
      token,
      origin: () => true,
    );
    settlements.land(token, noteId: 42);
    expect(await settled, <String, Object?>{'settled': 'landed', 'noteId': 42});
  });

  test('重试：两条入口收口，同一次失败只重写一次；重写后可再等同一令牌', () async {
    final int token = settlements.open();
    settlements.bindOrigin(token, () => true);
    int reruns = 0;
    settlements.fail(
      token,
      failure: _failure,
      onUnseen: onUnseen,
      retry: () => reruns++,
    );
    expect(settlements.retry(token), 'queued');
    expect(settlements.retry(token), 'queued', reason: '另一条入口：已在重写，不再触发');
    expect(reruns, 1);
    final Future<Map<String, Object?>> settled = settlements.wait(
      token,
      origin: () => true,
    );
    settlements.land(token, noteId: 7);
    expect((await settled)['settled'], 'landed');
    expect(settlements.retry(token), 'landed');
  });

  test('不可重写的失败（重复卡）/ 未知令牌：retry 回 unavailable', () {
    final int token = settlements.open();
    settlements.bindOrigin(token, () => true);
    settlements.fail(
      token,
      failure: const <String, Object?>{
        'ankiConnect': false,
        'message': '重复',
        'duplicate': true,
      },
      onUnseen: onUnseen,
    );
    expect(settlements.retry(token), 'unavailable');
    expect(settlements.retry(9999), 'unavailable');
  });

  test('关掉了重复卡提示：卡上也不说（去 message、标 hostReported），仍报 duplicate', () async {
    MineNotices.filter = (MineToastStatus s) => s != MineToastStatus.duplicate;
    final int token = settlements.open();
    settlements.bindOrigin(token, () => true);
    final Future<Map<String, Object?>> settled = settlements.wait(
      token,
      origin: () => true,
    );
    settlements.fail(
      token,
      failure: const <String, Object?>{
        'ankiConnect': false,
        'message': '重复',
        'duplicate': true,
      },
      onUnseen: onUnseen,
    );
    final Map<String, Object?> reply = await settled;
    expect(reply.containsKey('message'), isFalse);
    expect(reply['duplicate'], isTrue);
    expect(reply[MineFailureNotice.hostReportedKey], isTrue);
  });

  test('未知令牌：wait 立即回 unknown；fail 直接走 toast', () async {
    expect(await settlements.wait(123, origin: () => true), <String, Object?>{
      'settled': 'unknown',
    });
    settlements.fail(123, failure: _failure, onUnseen: onUnseen);
    expect(unseen, 1);
  });

  test('容量逐出：等待者拿到 unknown，压着的失败改走 toast', () async {
    final QueuedMineSettlements small = QueuedMineSettlements(capacity: 2);
    final int a = small.open();
    final Future<Map<String, Object?>> waitingA = small.wait(
      a,
      origin: () => true,
    );
    final int b = small.open();
    small.bindOrigin(b, () => true);
    small.fail(b, failure: _failure, onUnseen: onUnseen);
    small.open();
    expect((await waitingA)['settled'], 'unknown');
    expect(unseen, 0);
    small.open();
    expect(unseen, 1, reason: 'b 被逐出时它压着的失败必须说出来');
    expect(small.debugTicketCount, 2);
  });
}

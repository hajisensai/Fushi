import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_mining_coordinator.dart';
import 'package:fushi_anki/fushi_anki.dart' show MineOutcome, MineResult;

/// gal 浮窗的回包：进了待发队列的卡要让 popup.js 画 ✓（`reply.queued`），
/// 且不能带失败原因——卡没有丢，只是之后补发。
void main() {
  test('queued：带 queued 位、不带 message、不算成功', () {
    const GalHookMiningResult result = GalHookMiningResult(
      outcome: MineOutcome.queued(),
    );
    final Map<String, Object?> reply = result.toPopupReply(message: 'boom');

    expect(result.queued, isTrue);
    expect(reply['queued'], isTrue);
    expect(reply['ankiConnect'], isFalse);
    expect(reply.containsKey('message'), isFalse);
  });

  test('失败仍带 message、不带 queued', () {
    const GalHookMiningResult result = GalHookMiningResult(
      outcome: MineOutcome(MineResult.error),
    );
    final Map<String, Object?> reply = result.toPopupReply(message: 'boom');

    expect(reply['message'], 'boom');
    expect(reply.containsKey('queued'), isFalse);
  });
}

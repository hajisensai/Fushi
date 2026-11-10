import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/overlay_bridge_handlers.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';
import 'package:fushi_anki/fushi_anki.dart';

// BUG-4276：「保存到」被主机退回默认的提示从客户端级 toast 挪到了 MineOutcome.notice，
// 只有 describeMineOutcome 的结果 toast 会说它。app 外浮窗（全局查词 / 剪贴板面板 /
// 截屏识字）成功时宿主不弹结果 toast，提示必须随回包回到浮窗、由 popup.js 就地说出来。
void main() {
  const String notice = 'Save to was reset to the host default.';

  test('成功且结果带提示：回包 message 是这句提示', () {
    const MineOutcome outcome = MineOutcome.success(noteId: 7, notice: notice);
    final Map<String, Object?> reply = overlayMineReply(outcome, (
      message: 'Card exported. $notice',
      success: true,
      record: true,
      status: MineToastStatus.addedWithWarning,
    ));
    expect(reply['ankiConnect'], isTrue);
    expect(reply['noteId'], 7);
    expect(reply['message'], notice);
  });

  test('成功不带提示：回包不带 message（浮窗 ➕→✓ 已表达成功）', () {
    const MineOutcome outcome = MineOutcome.success(noteId: 7);
    final Map<String, Object?> reply = overlayMineReply(outcome, (
      message: 'Card exported.',
      success: true,
      record: true,
      status: MineToastStatus.added,
    ));
    expect(reply['ankiConnect'], isTrue);
    expect(reply.containsKey('message'), isFalse);
  });

  test('失败：回包 message 仍是失败原因', () {
    const MineOutcome outcome = MineOutcome.duplicate();
    final Map<String, Object?> reply = overlayMineReply(outcome, (
      message: 'Already in Anki.',
      success: false,
      record: false,
      status: MineToastStatus.duplicate,
    ));
    expect(reply['ankiConnect'], isFalse);
    expect(reply['message'], 'Already in Anki.');
  });

  test('popup.js 成功分支把宿主给的 message 就地说出来', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();
    final int start = js.indexOf('} else if (result.ankiConnect) {');
    expect(start, isNonNegative);
    final int end = js.indexOf('} else {', start);
    expect(
      js.substring(start, end),
      contains(
        'if (result.message) showInlineHint(mineButton, result.message);',
      ),
    );
  });
}

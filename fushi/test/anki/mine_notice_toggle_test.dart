import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 「制卡提示」开关组（反馈 zNuGKLIhmT：阅读时制卡成功 toast 挡字；aK5wv0CnWf：
/// 明知重复不想被提醒）。toast 出口只有 `FushiToast.showMine`，裁决是纯函数
/// [mineToastShown]，这里钉死它的口径，再用源码扫描确认接线没断。
void main() {
  bool shown(MineToastStatus s, {bool success = true, bool duplicate = true}) =>
      mineToastShown(s, showSuccess: success, showDuplicate: duplicate);

  test('全开（默认）：每一类都弹', () {
    for (final MineToastStatus s in MineToastStatus.values) {
      expect(shown(s), isTrue, reason: '$s');
    }
  });

  test('关掉成功提示：added / queued / pending 不弹，其余照弹', () {
    expect(shown(MineToastStatus.added, success: false), isFalse);
    expect(shown(MineToastStatus.overwritten, success: false), isFalse);
    expect(shown(MineToastStatus.queued, success: false), isFalse);
    expect(
      shown(MineToastStatus.pending, success: false),
      isFalse,
      reason: 'pending 是结果 toast 的过渡态，结果不弹时它会独自停 4 秒',
    );
    expect(shown(MineToastStatus.duplicate, success: false), isTrue);
    expect(shown(MineToastStatus.failed, success: false), isTrue);
    expect(
      shown(MineToastStatus.addedWithWarning, success: false),
      isTrue,
      reason: '卡缺了音频必须让用户知道（TODO-779）',
    );
  });

  test('关掉重复提示：只有 duplicate 不弹', () {
    for (final MineToastStatus s in MineToastStatus.values) {
      expect(
        shown(s, duplicate: false),
        s != MineToastStatus.duplicate,
        reason: '$s',
      );
    }
  });

  test('失败恒弹：两个开关都关也弹', () {
    expect(
      shown(MineToastStatus.failed, success: false, duplicate: false),
      isTrue,
    );
  });

  test('成功但带音频缺失提示 → addedWithWarning；纯成功仍是 added', () {
    expect(
      describeMineOutcome(const MineOutcome.success(deckName: 'D')).status,
      MineToastStatus.added,
    );
    expect(
      describeMineOutcome(
        const MineOutcome.success(deckName: 'D', audioWarning: 'HTTP 404'),
      ).status,
      MineToastStatus.addedWithWarning,
    );
    expect(
      describeMineOutcome(
        const MineOutcome.success(deckName: 'D'),
        overwrite: true,
      ).status,
      MineToastStatus.overwritten,
      reason: '覆盖已有卡与新制分色',
    );
    expect(
      mineToastSeverity(MineToastStatus.addedWithWarning),
      ToastSeverity.warning,
    );
  });

  test('接线：showMine 先过 mineNoticeFilter，各 entry point 装上偏好闭包', () {
    final String toast = File(
      'lib/src/utils/misc/fushi_toast.dart',
    ).readAsStringSync();
    final int showMine = toast.indexOf('static void showMine(');
    expect(showMine, greaterThan(0));
    final int body = toast.indexOf('{', showMine);
    final int overlay = toast.indexOf('_toastNavigatorKey', body);
    final int gate = toast.indexOf(
      'if (!mineNoticeFilter(status)) return;',
      body,
    );
    expect(gate, greaterThan(body), reason: 'showMine 必须先过开关');
    expect(gate, lessThan(overlay), reason: '开关判断要在任何绘制之前');

    for (final String entry in <String>[
      'lib/main.dart',
      'lib/popup_main.dart',
    ]) {
      expect(
        File(entry).readAsStringSync(),
        contains('FushiToast.mineNoticeFilter ='),
        reason: '$entry 没装「制卡提示」开关，那个进程的 toast 不听设置',
      );
    }
  });
}

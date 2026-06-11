import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-132 诉求B 源码守卫：退出书同步必须 fire-and-forget 不阻塞 UI，且不弹打断式
/// 「同步成功」SnackBar（用户报的「退出书后必须等同步成功条才能离开」=卡手）。
/// HSA 契约：退出书 export 与页面生命周期解耦、静默，冲突才提示。本守卫扫
/// sync_auto_trigger.dart 的源码结构（运行时无法触达页面 messenger / 真后端）。
void main() {
  late String body;

  setUpAll(() {
    final File src = File('lib/src/sync/sync_auto_trigger.dart');
    expect(src.existsSync(), isTrue,
        reason: 'run from the hibiki/ package root');
    body = src.readAsStringSync();
  });

  test(
      'triggerAutoSyncAfterClose is fire-and-forget (returns void, not awaited)',
      () {
    // 退出书入口必须返回 void：onWillPop 不能 await 它，否则退出阻塞在网络同步上。
    expect(
      RegExp(r'void\s+triggerAutoSyncAfterClose\s*\(').hasMatch(body),
      isTrue,
      reason: 'triggerAutoSyncAfterClose 必须返回 void（fire-and-forget）。'
          '改成 Future 会让 onWillPop await 它 → 退出阻塞 UI，违反 132B。',
    );
  });

  test('_runAutoSync registers its in-flight future into BookExitSyncScope',
      () {
    // 关书同步必须挂 app-scope，使页面销毁后仍跑完、退出路径能有界等它落定。
    expect(
      body.contains('BookExitSyncScope'),
      isTrue,
      reason: '_runAutoSync 必须把在飞同步登记进 BookExitSyncScope（app-scope），'
          '否则退出杀应用会把关书 export 打成半截（132B/132A 互补）。',
    );
    expect(
      RegExp(r"import\s+'package:hibiki/src/sync/book_exit_sync_scope\.dart';")
          .hasMatch(body),
      isTrue,
      reason: 'sync_auto_trigger 必须导入 book_exit_sync_scope.dart',
    );
  });

  test('book-exit sync does NOT show an interrupting success SnackBar', () {
    // 退出书后弹「同步成功」打断条 = 卡手。去掉 imported/exported 成功提示；
    // 冲突仍走 onReport/presentAutoConflicts（那是用户必须看的）。
    final int runIdx = body.indexOf('Future<void> _runAutoSync(');
    expect(runIdx, greaterThanOrEqualTo(0),
        reason: '_runAutoSync 被改名/删除 — 更新本守卫');
    final String runBody = body.substring(runIdx);

    expect(
      runBody.contains('showSnackBar'),
      isFalse,
      reason: '_runAutoSync 不得再弹任何 SnackBar（含「同步成功」）。退出书静默，'
          '不打断用户（HSA 契约）；冲突走 onReport 对话框，不是 SnackBar。',
    );
  });
}

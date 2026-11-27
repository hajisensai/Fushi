import 'dart:io';

import 'package:flutter/widgets.dart' show SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_store.dart';

/// 测试体末尾调用：摘掉页面树，再边 pump 边让真实事件循环走，直到 [root] 下没有
/// 写到一半的临时文件（BUG-5608）。
///
/// 根因：widget 测试里页面发起的真实文件 IO（「临时文件 + rename」落盘：反馈本机列表
/// `tickets.json.tmp`、排行榜资料缓存 `profile_<id>.self.json.tmp`、草稿目录
/// `draft.tmp`、回复状态 `poll_state.json.<随机>.tmp` 与锁文件……）跑在 fakeAsync
/// 区里：IO 线程把每一步做完后，续体只在 pump 时推进。测试体在页面已刷新、但后台
/// 落盘还没走完时结束，之后再没人 pump，`writeAsString` 打开的临时文件句柄永远不关，
/// tearDown 删临时目录在 Windows 上即 errno 32（`PathAccessException`）。哪条用例撞上
/// 取决于那一刻 IO 的快慢，所以表现为偶发。
///
/// 等待的是真实条件（临时文件 / 锁文件都消失、反馈列表的串行写队列排空），连续两轮
/// 都满足才算完；[maxRounds] 轮仍没写完就直接判失败并列出残留文件——那是真泄漏，
/// 不能被 tearDown 吞掉。
Future<void> drainPendingFileWrites(
  WidgetTester tester,
  Directory root, {
  int maxRounds = 500,
}) async {
  // 先在页面还挂着时等完：在途的写完成后服务还要 notifyListeners，先摘树会把
  // provider 持有的服务 dispose 掉，续体再通知即「used after being disposed」。
  await _drain(tester, root, maxRounds);
  // 页面 dispose 里也会起落盘（如提交页退场把草稿写下去），摘树后再等一轮。
  await tester.pumpWidget(const SizedBox());
  await _drain(tester, root, maxRounds);
}

Future<void> _drain(WidgetTester tester, Directory root, int maxRounds) async {
  int clean = 0;
  for (int round = 0; round < maxRounds; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
    if (_inFlight(root).isEmpty && !FeedbackTicketStore.debugHasPendingWrites) {
      if (++clean >= 2) return;
    } else {
      clean = 0;
    }
  }
  fail(
    '页面起的落盘 $maxRounds 轮后仍没写完：${_inFlight(root).join(', ')}'
    '${FeedbackTicketStore.debugHasPendingWrites ? '（反馈列表写队列未排空）' : ''}',
  );
}

List<String> _inFlight(Directory root) {
  if (!root.existsSync()) return const <String>[];
  return <String>[
    for (final FileSystemEntity e in root.listSync(recursive: true))
      if (e.path.endsWith('.tmp') || e.path.endsWith('.lock')) e.path,
  ];
}

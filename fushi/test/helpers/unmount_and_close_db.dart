import 'dart:async';

import 'package:material_ui/material_ui.dart' show SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// 卸掉挂着后台工作的页面，并在用例体内把 [db] 关完。
///
/// 视频库等页面挂载即起后台工作（`database.runBackgroundWork`，如封面回填），
/// 关库要等它退出（BUG-5387）。那些工作里的真实文件 I/O 回调落在测试的假时间
/// zone：用例体结束后没人再 pump，工作就停在半路，tearDown 的 `db.close()`
/// 永远等不到，用例卡到 10 分钟超时。所以在用例体内卸页、边推进真实时间边
/// pump，直到关库完成；一分钟内没关完说明后台工作真没退出，直接判红。
///
/// 调用方 tearDown 里不要再关同一个库（用返回后置位的标志跳过）。
Future<void> unmountAndCloseDb(WidgetTester tester, FushiDatabase db) async {
  await tester.pumpWidget(const SizedBox.shrink());
  bool closed = false;
  unawaited(db.close().then((_) => closed = true));
  final Stopwatch waited = Stopwatch()..start();
  while (!closed) {
    if (waited.elapsed > const Duration(minutes: 1)) {
      fail('一分钟内没等到关库（后台工作没退出）');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
}

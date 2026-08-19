// BUG-1734：工作台展示的台词与游戏内制卡回溯的台词**必须是同一份**。
//
// 这两个 getter 过去各写各的，且在 `sessionStartedAt == null` 时方向相反：
//   workbenchLines        -> 不过滤，照常显示
//   selectedSessionLines  -> 直接返回空
// 于是用户在工作台看得见台词，游戏内点「制卡」却因为拿到空列表而静默失败。
// Ren'Py 上实测过这个后果：同一句台词，工作台点词能写出 Anki 卡，游戏内卡片点「+」零反应
// （Ren'Py 走「启动器 → 子进程」，比单进程引擎多出若干绑定时机，更容易落在该窗口里）。
//
// 本测试锚的是「两者一致」这个不变量本身，而不是某一侧的具体返回值——真正要防的
// 回归是它们再次分叉。

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/src/sync/texthooker_ws_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  GalHookSessionController build(TexthookerService service) =>
      GalHookSessionController(
        textService: service,
        isWindows: true,
        endpointListenable: ValueNotifier<int>(0),
        endpointStatusLoader: () => const <TexthookerEndpointStatus>[],
      );

  test('未开始计会话时，两个台词集合仍必须一致（BUG-1734）', () {
    final TexthookerService service = TexthookerService.test();
    final GalHookSessionController controller = build(service);

    // 没有调用 launchAndCapture / bindWindow，所以 sessionStartedAt 为 null。
    // 这正是分叉发生的条件。
    service.appendLine('I am not a fan of mornings.');

    expect(controller.workbenchLines, isNotEmpty,
        reason: '工作台在未计会话时本来就会显示台词');
    expect(
      controller.selectedSessionLines.map((e) => e.id).toList(),
      controller.workbenchLines.map((e) => e.id).toList(),
      reason: '制卡回溯用的集合与工作台展示的集合必须逐条一致，'
          '否则用户看得见的台词在制卡时"不存在"，且失败是静默的',
    );
  });

  test('多行时两个集合逐条一致（顺序也一致）', () {
    final TexthookerService service = TexthookerService.test();
    final GalHookSessionController controller = build(service);

    service.appendLine('Not my favourite time of the day.');
    service.appendLine('The morning is when you are not awake enough.');
    service.appendLine('I am not a fan of mornings.');

    final List<String> workbench =
        controller.workbenchLines.map((e) => e.id).toList();
    final List<String> session =
        controller.selectedSessionLines.map((e) => e.id).toList();
    expect(workbench.length, 3);
    expect(session, workbench);
    // 制卡按「最新一条」回溯，所以末元素必须是最后写进来的那句。
    expect(controller.selectedSessionLines.last.text,
        'I am not a fan of mornings.');
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';

// 复现 BUG：宽屏设置「外观」详情里，焦点在右侧详情面板（一个 Scrollable）的
// 「设计系统」段控上，按 Down 应去同面板下方的「主题」；但左侧导航面板（另一个
// Scrollable）的「阅读」在纵向上更近，旧评分会误选它。修复后方向焦点优先留在
// 当前项所在的同一 Scrollable 面板内。
Widget _twoPane({
  required GlobalKey rootKey,
}) {
  // 左面板（导航 ListView）：nav0 / nav-阅读 / nav2，各高 56。
  // 右面板（详情 ListView）：seg（高 56）/ 非聚焦留白（高 80）/ theme（高 56）。
  // 两面板顶端对齐：seg 中心≈28，theme 中心≈164；nav-阅读 中心≈84（比 theme 更近）。
  Widget target(String id, double height, double width) => HibikiFocusTarget(
        id: HibikiFocusId(id),
        child: SizedBox(height: height, width: width),
      );
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
    home: Scaffold(
      body: HibikiFocusRoot(
        child: Row(
          key: rootKey,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 200,
              height: 300,
              child: ListView(
                children: <Widget>[
                  target('nav-0', 56, 200),
                  target('nav-reading', 56, 200),
                  target('nav-2', 56, 200),
                ],
              ),
            ),
            SizedBox(
              width: 400,
              height: 300,
              child: ListView(
                children: <Widget>[
                  target('detail-seg', 56, 400),
                  const SizedBox(height: 80, width: 400),
                  target('detail-theme', 56, 400),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
      'Down from a detail-pane control stays in the same Scrollable pane '
      '(does not jump to the closer cross-pane nav item)', (tester) async {
    final GlobalKey rootKey = GlobalKey();
    await tester.pumpWidget(_twoPane(rootKey: rootKey));
    await tester.pump();

    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(rootKey.currentContext!);

    expect(controller.requestById(const HibikiFocusId('detail-seg')), isTrue);
    await tester.pump();

    expect(controller.move(HibikiFocusDirection.down), isTrue);
    await tester.pump();

    expect(
      controller.activeId,
      const HibikiFocusId('detail-theme'),
      reason: 'Down must prefer the same-pane control below, not the closer '
          'cross-pane nav item',
    );
  });

  testWidgets('Right from the nav pane still crosses into the detail pane',
      (tester) async {
    final GlobalKey rootKey = GlobalKey();
    await tester.pumpWidget(_twoPane(rootKey: rootKey));
    await tester.pump();

    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(rootKey.currentContext!);

    expect(controller.requestById(const HibikiFocusId('nav-0')), isTrue);
    await tester.pump();

    // 导航面板单列、右侧无同面板候选 → Right 必须跨到详情面板（不被同面板档锁死）。
    expect(controller.move(HibikiFocusDirection.right), isTrue);
    await tester.pump();
    expect(
      controller.activeId?.value.startsWith('detail-'),
      isTrue,
      reason: 'crossing panes via Left/Right must still work',
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';

// BUG-015 regression. 宽屏设置「外观」详情：焦点在最底部的整宽开关「反转底栏方向」，
// 按方向键左，焦点会跳到上方的「主题」色块行（一个同面板的对角候选），而不是离开
// 详情面板去左侧导航栏。根因：方向几何评分把 `samePane`（同一可滚动面板）排在
// `clears`（在按压轴上整体越过源的真·方向邻居）之上 —— 整宽行没有同行的左邻居，
// 唯一的同面板「左方」候选只能是斜上方的色块，于是它击败了正左方、确实越过源的
// 导航项。修复后 `clears` 高于 `samePane`，左移落到导航面板。
Widget _twoPane({required GlobalKey rootKey}) {
  Widget target(String id, {required double width, required double height}) =>
      HibikiFocusTarget(
        id: HibikiFocusId(id),
        child: SizedBox(width: width, height: height),
      );
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
    home: Scaffold(
      body: HibikiFocusRoot(
        child: Row(
          key: rootKey,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 左：导航面板（独立 ListView），x 0..200。
            SizedBox(
              width: 200,
              height: 400,
              child: ListView(
                children: <Widget>[
                  target('nav-0', width: 200, height: 56),
                  target('nav-1', width: 200, height: 56),
                  target('nav-2', width: 200, height: 56),
                ],
              ),
            ),
            // 右：详情面板（独立 ListView），x 200..600。
            //  - 左对齐的「色块」行（x 200..300，y≈0..48）——同面板、斜上方候选。
            //  - 整宽的「开关」行（x 200..600，下方）——焦点起点；它的左缘=面板左缘，
            //    所以导航项在按压轴(左)上整体越过它（clears），而色块没有。
            SizedBox(
              width: 400,
              height: 400,
              child: ListView(
                children: <Widget>[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: target('detail-swatch', width: 100, height: 48),
                  ),
                  target('detail-switch', width: 400, height: 56),
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
      'Left from a full-width detail row escapes to the nav pane, not a '
      'diagonal same-pane swatch (BUG-015)', (WidgetTester tester) async {
    final GlobalKey rootKey = GlobalKey();
    await tester.pumpWidget(_twoPane(rootKey: rootKey));
    await tester.pump();

    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(rootKey.currentContext!);

    expect(
      controller.requestById(const HibikiFocusId('detail-switch')),
      isTrue,
    );
    await tester.pump();

    expect(controller.move(HibikiFocusDirection.left), isTrue);
    await tester.pump();

    // 修复前会落到 'detail-swatch'（同面板斜上方）。修复后落到导航面板的某一项。
    expect(
      controller.activeId?.value.startsWith('nav-'),
      isTrue,
      reason: 'Left from the full-width switch must leave the detail pane for '
          'the nav rail (a real directional neighbour that clears), not jump '
          'up to the diagonal same-pane swatch',
    );
  });
}

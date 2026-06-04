import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';

// 复现书架 bug：左 rail 与右 body 各一个 FocusTraversalGroup。右 body 顶部是无
// Scrollable 的「页头按钮」，下方是一个 ListView 内容。按 Down 必须落到同 body 组
// 的内容，而不是另一组（rail）的导航项——即便某个 rail 项纵向更近。
Widget _shell({required GlobalKey rootKey}) {
  Widget t(String id, {required double w, required double h}) =>
      HibikiFocusTarget(
          id: HibikiFocusId(id), child: SizedBox(width: w, height: h));
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
    home: Scaffold(
      body: HibikiFocusRoot(
        child: Row(
          key: rootKey,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 左：rail（独立组，非滚动 Column，垂直居中 → 项落在中段，纵向接近顶部按钮）
            FocusTraversalGroup(
              child: SizedBox(
                width: 80,
                height: 400,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    t('nav-0', w: 80, h: 56),
                    t('nav-1', w: 80, h: 56),
                    t('nav-2', w: 80, h: 56),
                  ],
                ),
              ),
            ),
            // 右：body（独立组）：顶部无 Scrollable 的页头按钮 + 下方 ListView 内容
            Expanded(
              child: FocusTraversalGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Align(
                      alignment: Alignment.centerRight,
                      child: t('header-btn', w: 48, h: 48),
                    ),
                    Expanded(
                      child: ListView(
                        children: <Widget>[
                          t('content-0', w: 400, h: 56),
                          t('content-1', w: 400, h: 56),
                        ],
                      ),
                    ),
                  ],
                ),
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
      'Down from a header button stays in the body pane, never enters '
      'the rail group', (WidgetTester tester) async {
    final GlobalKey rootKey = GlobalKey();
    await tester.pumpWidget(_shell(rootKey: rootKey));
    await tester.pump();
    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(rootKey.currentContext!);

    expect(controller.requestById(const HibikiFocusId('header-btn')), isTrue);
    await tester.pump();

    expect(controller.move(HibikiFocusDirection.down), isTrue);
    await tester.pump();
    expect(
      controller.activeId?.value.startsWith('content-'),
      isTrue,
      reason: 'Down from header must reach the body content, not the rail',
    );
  });

  testWidgets('Left from body content still escapes into the rail group',
      (WidgetTester tester) async {
    final GlobalKey rootKey = GlobalKey();
    await tester.pumpWidget(_shell(rootKey: rootKey));
    await tester.pump();
    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(rootKey.currentContext!);

    expect(controller.requestById(const HibikiFocusId('content-0')), isTrue);
    await tester.pump();

    expect(controller.move(HibikiFocusDirection.left), isTrue);
    await tester.pump();
    expect(
      controller.activeId?.value.startsWith('nav-'),
      isTrue,
      reason: 'Left must still cross panes into the rail',
    );
  });
}

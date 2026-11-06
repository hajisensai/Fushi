import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';

/// 反馈 03cff3908u / Sb7jHbNO43（Windows 截图）：库页 / 多数页面往下滑、顶部
/// 工具区收起后，视口顶边仍留一条页面底色的白带，盖住页面背景装饰。
///
/// 根因：最外层遮罩收起后仍按外壳让位区 `outer`（MD3 库页外壳标题条的让位，
/// 此时标题条是收起态、什么也不画）画实色段 + 32 px 渐隐。遮罩只该为看得见的
/// 工具区垫底：整段不透明度跟随工具区弹簧，完全收起时不画。
void main() {
  Widget harness(FushiFloatingChromeController controller) => MaterialApp(
    home: Scaffold(
      body: FushiFloatingChromeInset(
        // 外壳让位区（标题条高度 + 间距）：不为 0 才会出现那条实色带。
        top: 46,
        child: FushiFloatingChromeScope(
          controller: controller,
          child: FushiFloatingChromeOverlay(
            chrome: const SizedBox(height: 56, child: Text('tabs')),
            child: NotificationListener<ScrollNotification>(
              onNotification: controller.handleScrollNotification,
              child: Builder(
                builder: (BuildContext context) => ListView.builder(
                  padding: EdgeInsets.only(
                    top: FushiFloatingChromeInset.of(context),
                  ),
                  itemCount: 40,
                  itemBuilder: (BuildContext context, int i) =>
                      SizedBox(height: 120, child: Text('item $i')),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('工具区收起后顶部不留遮罩底色带', (WidgetTester tester) async {
    final FushiFloatingChromeController controller =
        FushiFloatingChromeController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(harness(controller));
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(controller.visible, isFalse, reason: '前提：往下滚后工具区收起');
    expect(controller.contentUnderTop, isTrue);
    expect(
      find.byType(FushiTopFadeScrim),
      findsNothing,
      reason: '收起后让位区里没有可见工具，遮罩不得再画页面底色盖住背景',
    );
  });

  testWidgets('工具区弹回（内容仍在底下）时遮罩照常垫在工具区之下', (WidgetTester tester) async {
    final FushiFloatingChromeController controller =
        FushiFloatingChromeController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(harness(controller));
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(controller.visible, isTrue);
    expect(controller.contentUnderTop, isTrue);
    final Finder scrim = find.byType(FushiTopFadeScrim);
    expect(scrim, findsOneWidget);
    final Opacity fade = tester.widget<Opacity>(
      find.ancestor(of: scrim, matching: find.byType(Opacity)).first,
    );
    expect(fade.opacity, closeTo(1, 0.001), reason: '展开时遮罩不打折扣');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:material_ui/material_ui.dart';

/// 冷启动首帧上屏前挂载的进场件直接显示终态；首帧上屏后恢复正常进场。
void main() {
  tearDown(FushiColdStartEntrance.finish);

  Widget host({required Widget child}) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  Widget item(String label) => FushiStaggeredEntrance(
    index: 0,
    child: SizedBox(key: ValueKey<String>(label), width: 40, height: 40),
  );

  double opacityOf(WidgetTester tester, String label) => tester
      .widget<Opacity>(
        find
            .ancestor(
              of: find.byKey(ValueKey<String>(label)),
              matching: find.byType(Opacity),
            )
            .first,
      )
      .opacity;

  testWidgets('默认不是冷启动：scope 下的项照常从透明淡入', (WidgetTester tester) async {
    expect(FushiColdStartEntrance.pending, isFalse);
    await tester.pumpWidget(host(child: FushiEntranceScope(child: item('a'))));

    expect(opacityOf(tester, 'a'), 0);
    await tester.pumpAndSettle();
    expect(opacityOf(tester, 'a'), 1);
  });

  testWidgets('冷启动首帧上屏前：scope 下的项直接是终态，没有在跑的动画', (WidgetTester tester) async {
    FushiColdStartEntrance.begin();
    await tester.pumpWidget(host(child: FushiEntranceScope(child: item('a'))));

    expect(opacityOf(tester, 'a'), 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('冷启动首帧上屏前：没有 scope 的项也直接是终态', (WidgetTester tester) async {
    FushiColdStartEntrance.begin();
    await tester.pumpWidget(host(child: item('a')));

    expect(opacityOf(tester, 'a'), 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('冷启动时打开的 scope：首帧后晚到的项也不补播，replayKey 变化才重新进场', (
    WidgetTester tester,
  ) async {
    Widget tree({required bool late, required int replay}) => host(
      child: FushiEntranceScope(
        replayKey: replay,
        child: Column(children: <Widget>[item('a'), if (late) item('b')]),
      ),
    );

    FushiColdStartEntrance.begin();
    await tester.pumpWidget(tree(late: false, replay: 0));
    FushiColdStartEntrance.finish();

    // 首帧刚上屏、仍在这个 scope 原本的进场窗口（600 ms）之内，数据晚到一项。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(tree(late: true, replay: 0));
    expect(opacityOf(tester, 'b'), 1);
    expect(tester.binding.transientCallbackCount, 0);

    // 用户切了分组 / 排序：这一屏照常播进场。
    await tester.pumpWidget(tree(late: true, replay: 1));
    expect(opacityOf(tester, 'a'), 0);
    await tester.pumpAndSettle();
    expect(opacityOf(tester, 'a'), 1);
  });

  testWidgets('首帧上屏后新打开的 scope 照常进场', (WidgetTester tester) async {
    FushiColdStartEntrance.begin();
    await tester.pumpWidget(host(child: FushiEntranceScope(child: item('a'))));
    FushiColdStartEntrance.finish();

    await tester.pumpWidget(
      host(
        child: FushiEntranceScope(
          key: const ValueKey<String>('next-page'),
          child: item('b'),
        ),
      ),
    );
    expect(opacityOf(tester, 'b'), 0);
    await tester.pumpAndSettle();
    expect(opacityOf(tester, 'b'), 1);
  });
}

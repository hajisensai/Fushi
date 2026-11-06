import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';

void main() {
  // 骨架与真内容在 AnimatedSwitcher 里交叉淡入时两棵子树同时在树上；骨架里的
  // 滚动视图若也去认分区的 PrimaryScrollController，过渡那几帧同一个 controller
  // 挂两个位置，桌面滚动条断言「attached to more than one ScrollPosition」
  // （游戏串流页实测，2026-10-30）。
  testWidgets('骨架里的主滚动视图不挂到外层 PrimaryScrollController 上', (
    WidgetTester tester,
  ) async {
    final ScrollController primary = ScrollController();
    addTearDown(primary.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PrimaryScrollController(
          controller: primary,
          child: Column(
            children: <Widget>[
              Expanded(
                child: FushiSkeletonShimmer(
                  child: ListView(
                    primary: true,
                    children: const <Widget>[SizedBox(height: 2000)],
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  primary: true,
                  children: const <Widget>[SizedBox(height: 2000)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    // 只有真内容那一个位置挂在主控制器上。
    expect(primary.positions, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}

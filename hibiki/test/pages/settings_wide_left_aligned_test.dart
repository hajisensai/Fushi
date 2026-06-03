import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';

// 守卫:大屏全屏设置的「宽屏主从布局」导航(supporting)面板必须贴屏幕最左缘
// (平板友好),而不是被居中限宽的 DesktopContentLayout 推离左缘。
// 用真实大视口(1500px)测绝对 left,避免默认 800x600 测试面板导致负偏移误判。
Widget _fullBleed(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      home: Scaffold(body: child),
    );

void main() {
  const Key navKey = Key('settings-nav-pane');

  Widget masterDetail() => MaterialSupportingPaneLayout(
        minSplitWidth: 720,
        supportingSide: SupportingPaneSide.start,
        supporting: Container(key: navKey, color: Colors.blue),
        primary: const ColoredBox(color: Colors.green),
      );

  Future<void> useWideSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets('FIX: wide settings master-detail nav pane hugs the left edge',
      (tester) async {
    await useWideSurface(tester);
    await tester.pumpWidget(_fullBleed(masterDetail()));
    await tester.pump();
    final Rect nav = tester.getRect(find.byKey(navKey));
    // 全宽布局里导航面板贴 x=0(不再被居中限宽推走)。
    expect(nav.left, lessThan(1.0),
        reason: 'nav pane must be flush to the left edge for tablet reach');
  });

  testWidgets(
      'REGRESSION DOC: wrapping in centered DesktopContentLayout '
      'pushes the nav pane off the left (why we do NOT wrap the wide branch)',
      (tester) async {
    await useWideSurface(tester);
    await tester.pumpWidget(_fullBleed(
      DesktopContentLayout(
        kind: DesktopContentKind.settings,
        child: masterDetail(),
      ),
    ));
    await tester.pump();
    final Rect nav = tester.getRect(find.byKey(navKey));
    // 1500 宽被居中限到 960 → 左缘明显 > 0(这正是我们要避免的旧行为)。
    expect(nav.left, greaterThan(100.0));
  });
}

// BUG-3359（反馈 uYumRL_Gwe）：在漫画「来源」下拉里拨滚轮，列表下不去、页面顶栏
// 反而跟着收起。根因：下拉面板是 OverlayPortal 浮层，元素树上是锚点的后代，面板
// 的滚动通知冒泡进页面——页面层的「滚动收起」监听把它当正文滚动。修复在共享的
// 下拉 / 菜单组件里把浮层的滚动通知截在锚点处（同类选择框一并受益）。
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:material_ui/material_ui.dart';

const int _kEntries = 60;

Widget _host({required Widget child, required List<ScrollNotification> seen}) {
  return MaterialApp(
    home: Scaffold(
      body: NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification n) {
          seen.add(n);
          return false;
        },
        child: Align(alignment: Alignment.topCenter, child: child),
      ),
    ),
  );
}

ScrollPosition _menuPosition(WidgetTester tester, String visibleLabel) {
  final ScrollableState scrollable = tester.state<ScrollableState>(
    find
        .ancestor(
          of: find.text(visibleLabel).last,
          matching: find.byType(Scrollable),
        )
        .first,
  );
  return scrollable.position;
}

Future<void> _wheel(WidgetTester tester, Offset at, double dy) async {
  final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(at));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('下拉面板的滚轮滚得动列表，且滚动通知不冒泡进页面', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<ScrollNotification> seen = <ScrollNotification>[];
    await tester.pumpWidget(
      _host(
        seen: seen,
        child: FushiDropdownMenu<int>(
          initialSelection: 0,
          requestFocusOnTap: false,
          dropdownMenuEntries: <DropdownMenuEntry<int>>[
            for (int i = 0; i < _kEntries; i++)
              DropdownMenuEntry<int>(value: i, label: 'Source $i'),
          ],
        ),
      ),
    );
    await tester.tap(find.byType(DropdownMenu<int>));
    await tester.pumpAndSettle();

    final ScrollPosition menu = _menuPosition(tester, 'Source 1');
    expect(menu.maxScrollExtent, greaterThan(0), reason: '条目足够多，面板必须可滚');
    seen.clear();

    await _wheel(tester, tester.getCenter(find.text('Source 3').last), 200);

    expect(menu.pixels, greaterThan(0), reason: '滚轮必须滚动下拉列表本身');
    expect(seen, isEmpty, reason: '浮层的滚动通知不得冒泡进页面（页面会当正文滚动收起顶栏）');
  });

  testWidgets('FushiMenuAnchor：面板滚动截下，锚点自身的滚动照常冒泡', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<ScrollNotification> seen = <ScrollNotification>[];
    final MenuController controller = MenuController();
    await tester.pumpWidget(
      _host(
        seen: seen,
        child: FushiMenuAnchor(
          controller: controller,
          menuChildren: <Widget>[
            for (int i = 0; i < _kEntries; i++)
              MenuItemButton(onPressed: () {}, child: Text('Item $i')),
          ],
          child: SizedBox(
            key: const ValueKey<String>('anchor_list'),
            width: 200,
            height: 80,
            child: ListView(
              children: <Widget>[
                for (int i = 0; i < 20; i++)
                  SizedBox(height: 40, child: Text('Row $i')),
              ],
            ),
          ),
        ),
      ),
    );
    controller.open();
    await tester.pumpAndSettle();
    final ScrollPosition menu = _menuPosition(tester, 'Item 1');
    seen.clear();

    await _wheel(tester, tester.getCenter(find.text('Item 3').last), 200);
    expect(menu.pixels, greaterThan(0));
    expect(seen, isEmpty);

    controller.close();
    await tester.pumpAndSettle();
    await _wheel(
      tester,
      tester.getCenter(find.byKey(const ValueKey<String>('anchor_list'))),
      80,
    );
    expect(seen, isNotEmpty, reason: '锚点自身是页面内容，它的滚动通知必须照常冒泡');
  });
}

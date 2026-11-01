import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/web_browser/web_browser_layout.dart';
import 'package:fushi/src/pages/implementations/web_browser/web_browser_tab_lists.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:material_ui/material_ui.dart';

/// 中键单击标签即关闭（Chrome / Edge 习惯）；左键照常是切换。
void main() {
  testWidgets('标签栏中键单击关闭该标签，不切换', (WidgetTester tester) async {
    final WebBrowserTab a = WebBrowserTab(
      id: 'a',
      url: Uri.parse('https://a.test/'),
      title: 'A',
    );
    final WebBrowserTab b = WebBrowserTab(
      id: 'b',
      url: Uri.parse('https://b.test/'),
      title: 'B',
    );
    final List<String> closed = <String>[];
    final List<String> selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            child: WebBrowserTabStrip(
              tabs: <WebBrowserTab>[a, b],
              callbacks: WebBrowserTabCallbacks(
                isActive: (WebBrowserTab t) => t == a,
                onSelect: (WebBrowserTab t) => selected.add(t.id),
                onClose: (WebBrowserTab t) => closed.add(t.id),
                onNewTab: () {},
                onContextMenu: (WebBrowserTab _, Offset _) {},
                onReorder: (int _, int _) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    final Offset tabB = tester.getCenter(
      find.byKey(const ValueKey<String>('web-browser-strip-tab-b')),
    );
    final TestGesture mouse = await tester.startGesture(
      tabB,
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 500));

    expect(closed, <String>['b']);
    expect(selected, isEmpty);
  });

  testWidgets('标签栏鼠标横拖排序，单击照常切换', (WidgetTester tester) async {
    final List<WebBrowserTab> tabs = <WebBrowserTab>[
      for (final String id in <String>['a', 'b', 'c'])
        WebBrowserTab(
          id: id,
          url: Uri.parse('https://$id.test/'),
          title: id.toUpperCase(),
        ),
    ];
    final List<(int, int)> reorders = <(int, int)>[];
    final List<String> selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            child: WebBrowserTabStrip(
              tabs: tabs,
              callbacks: WebBrowserTabCallbacks(
                isActive: (WebBrowserTab t) => t == tabs.first,
                onSelect: (WebBrowserTab t) => selected.add(t.id),
                onClose: (WebBrowserTab _) {},
                onNewTab: () {},
                onContextMenu: (WebBrowserTab _, Offset _) {},
                onReorder: (int from, int to) => reorders.add((from, to)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    Offset center(String id) => tester.getCenter(
      find.byKey(ValueKey<String>('web-browser-strip-tab-$id')),
    );

    // 单击：切换，不排序。
    await tester.tapAt(center('b'), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 500));
    expect(selected, <String>['b']);
    expect(reorders, isEmpty);

    // 按住 a 横拖到 c 之后。
    final Offset start = center('a');
    final double dx = center('c').dx - start.dx + 60;
    final TestGesture mouse = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    for (int i = 1; i <= 10; i++) {
      await mouse.moveTo(start + Offset(dx * i / 10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await mouse.up();
    await tester.pumpAndSettle();
    expect(reorders, <(int, int)>[(0, 3)]);
  });

  testWidgets('标签贴着标签栏底边（与地址栏之间无缝）', (WidgetTester tester) async {
    final WebBrowserTab a = WebBrowserTab(
      id: 'a',
      url: Uri.parse('https://jiten.moe/'),
      title: 'Jiten',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 800,
              child: WebBrowserTabStrip(
                tabs: <WebBrowserTab>[a],
                callbacks: WebBrowserTabCallbacks(
                  isActive: (WebBrowserTab t) => t == a,
                  onSelect: (WebBrowserTab _) {},
                  onClose: (WebBrowserTab _) {},
                  onNewTab: () {},
                  onContextMenu: (WebBrowserTab _, Offset _) {},
                  onReorder: (int _, int _) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    final Rect strip = tester.getRect(
      find.byKey(const ValueKey<String>('web-browser-tab-strip')),
    );
    final Rect tab = tester.getRect(
      find.byKey(const ValueKey<String>('web-browser-strip-tab-a')),
    );
    expect(strip.height, kWebBrowserTabStripHeight);
    expect(tab.bottom, strip.bottom);
    expect(tab.top, greaterThan(strip.top));
  });
}

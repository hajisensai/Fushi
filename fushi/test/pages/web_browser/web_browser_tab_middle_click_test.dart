import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
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
}

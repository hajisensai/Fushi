import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/manga/cookie/browser_cookie_import.dart';
import 'package:fushi/src/media/video/underlay_composition.dart';
import 'package:fushi/src/pages/implementations/web_browser/web_browser_menus.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/features/login_import/web_browser_login_import_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 2026-10-26 用户截图的四件事：视频站点网页被页底盖住（加载不出来）、悬浮球点不到、
/// 「⋯」菜单离按钮一大截、app 内浏览器没有「从浏览器导入登录」。
void main() {
  tearDown(() => underlayCompositionActive.value = false);

  Finder shapeLayer() => find.byWidgetPredicate(
    (Widget w) => w.runtimeType.toString() == '_LibraryShapeLayer',
  );

  testWidgets('持有底层合成的路由：页底不画底色也不画形状，网页才透得出来', (WidgetTester tester) async {
    late Route<Object?> route;
    await tester.pumpWidget(
      MaterialApp(
        home: FushiPageBackdrop(
          child: Builder(
            builder: (BuildContext context) {
              route = ModalRoute.of(context)!;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    expect(shapeLayer(), findsOneWidget);

    setFushiPageRouteTransparent(route, true);
    await tester.pump();
    expect(shapeLayer(), findsNothing);
    final ColoredBox base = tester.widget<ColoredBox>(
      find
          .descendant(
            of: find.byType(FushiPageBackdrop),
            matching: find.byType(ColoredBox),
          )
          .first,
    );
    expect(base.color, Colors.transparent);

    setFushiPageRouteTransparent(route, false);
    await tester.pump();
    expect(shapeLayer(), findsOneWidget);
  });

  testWidgets('输入区：底层合成开着时上报全局矩形，卸载 / 关掉后清空', (WidgetTester tester) async {
    Widget app({required bool region}) => Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: <Widget>[
          if (region)
            const Positioned(
              left: 10,
              top: 20,
              width: 48,
              height: 48,
              child: UnderlayInputRegion(radius: 24, child: SizedBox.expand()),
            ),
        ],
      ),
    );

    await tester.pumpWidget(app(region: true));
    expect(underlayInputExclusions.value, isEmpty, reason: '底层合成没开不上报');

    underlayCompositionActive.value = true;
    await tester.pump();
    expect(underlayInputExclusions.value, <UnderlayInputExclusion>[
      const UnderlayInputExclusion(Rect.fromLTWH(10, 20, 48, 48), 24),
    ]);

    await tester.pumpWidget(app(region: false));
    expect(underlayInputExclusions.value, isEmpty);
  });

  testWidgets('「⋯」菜单紧贴按钮下沿，不再空出一个按钮高', (WidgetTester tester) async {
    final GlobalKey anchor = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 40, right: 8),
              child: Builder(
                builder: (BuildContext context) => SizedBox(
                  key: anchor,
                  width: 48,
                  height: 48,
                  child: GestureDetector(
                    onTap: () => showWebBrowserMenu(
                      context: context,
                      sections: <WebBrowserMenuSection>[
                        WebBrowserMenuItems(<WebBrowserMenuItem>[
                          WebBrowserMenuItem(
                            id: 'a',
                            icon: FushiIcons.add,
                            label: 'Item A',
                            onSelected: () {},
                          ),
                        ]),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(anchor));
    await tester.pumpAndSettle();
    final double buttonBottom = tester.getBottomLeft(find.byKey(anchor)).dy;
    final double itemTop = tester
        .getTopLeft(find.byKey(const ValueKey<String>('web-browser-menu-a')))
        .dy;
    expect(itemTop, greaterThanOrEqualTo(buttonBottom));
    expect(
      itemTop - buttonBottom,
      lessThan(32),
      reason: '旧锚点下移了一个按钮高（48），菜单首项离按钮下沿 > 48',
    );
  });

  group('从浏览器导入登录', () {
    test('无痕标签页 / 非 http(s) 页面不给这个动作', () {
      final WebBrowserLoginImportFeature feature = WebBrowserLoginImportFeature(
        environment: () async => null,
        openExternal: (Uri _) async => true,
      );
      final _FakeContext context = _FakeContext();
      expect(
        feature.actions(
          context,
          WebBrowserTab(
            id: 'i',
            url: Uri.parse('https://example.com/a'),
            incognito: true,
          ),
        ),
        isEmpty,
      );
      expect(
        feature.actions(
          context,
          WebBrowserTab(id: 'b', url: Uri.parse('about:blank')),
        ),
        isEmpty,
      );
      expect(
        feature
            .actions(
              context,
              WebBrowserTab(id: 'n', url: Uri.parse('https://example.com/a')),
            )
            .map((dynamic a) => a.id),
        <String>['login-import'],
      );
      feature.dispose();
    });

    testWidgets('点了：登记本站并在系统浏览器打开站点首页', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final List<Uri> opened = <Uri>[];
      final WebBrowserLoginImportFeature feature = WebBrowserLoginImportFeature(
        environment: () async => null,
        openExternal: (Uri url) async {
          opened.add(url);
          return true;
        },
      );
      await feature.begin(
        WebBrowserTab(id: 'n', url: Uri.parse('https://www.netflix.com/login')),
        Uri.parse('https://www.netflix.com/login'),
      );
      expect(BrowserCookieImportGate.pending?.host, 'netflix.com');
      expect(opened, <Uri>[Uri.parse('https://www.netflix.com/')]);
      feature.dispose();
      expect(BrowserCookieImportGate.pending, isNull);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}

class _FakeContext extends Fake implements BuildContext {}

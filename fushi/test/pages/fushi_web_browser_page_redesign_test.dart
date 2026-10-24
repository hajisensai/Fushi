import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/fushi_web_browser_page.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

/// 2026-10-19 用户截图三连：
/// ① 浏览器页点「⋯」左上角凭空出现返回键——根因是脚手架默认返回键问的是
///    `Navigator.canPop()`（整个导航栈），弹出菜单路由压栈也算数；
/// ② 浏览器嵌在模块页里，主导航底栏 + 「阅读本章」FAB 叠在网页上互相遮挡、
///    顶部还有一整行「浏览器」标题；
/// 重设计后：模块页只是入口（地址栏 + 站点），打开网址推全屏浏览页。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('脚手架默认返回键只看本页路由', () {
    testWidgets('根页在弹出路由（菜单 / 对话框）打开期间重建，不长出返回键', (WidgetTester tester) async {
      final GlobalKey<_RebuildableRootState> root =
          GlobalKey<_RebuildableRootState>();
      await tester.pumpWidget(MaterialApp(home: _RebuildableRoot(key: root)));
      expect(find.byTooltip('Back'), findsNothing);

      showDialog<void>(
        context: root.currentContext!,
        builder: (BuildContext _) => const AlertDialog(content: Text('menu')),
      );
      await tester.pumpAndSettle();
      root.currentState!.rebuild();
      await tester.pump();

      expect(
        find.byTooltip('Back'),
        findsNothing,
        reason: '弹出路由压在根页之上时 Navigator.canPop() 为 true，但根页本身没有可退的页面',
      );
    });

    testWidgets('推出来的页照常有返回键', (WidgetTester tester) async {
      final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: nav, home: const Text('origin')),
      );
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (BuildContext _) =>
              const FushiPageScaffold(title: 'pushed', body: SizedBox()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Back'), findsOneWidget);
    });
  });

  test('浏览页返回的优先级：查词弹窗 → 网页历史 → 离开浏览页', () {
    // 弹窗栈挂在浏览页路由之内、没有自己的 PopScope：弹窗开着时返回若直接退
    // 网页历史 / 整页 pop，弹窗会留在换掉的网页上，或随浏览页一起被关掉。
    for (final bool canGoBack in <bool>[false, true]) {
      expect(
        webBrowserBackStep(lookupOpen: true, canGoBack: canGoBack),
        WebBrowserBackStep.closeLookup,
      );
    }
    expect(
      webBrowserBackStep(lookupOpen: false, canGoBack: true),
      WebBrowserBackStep.webHistoryBack,
    );
    expect(
      webBrowserBackStep(lookupOpen: false, canGoBack: false),
      WebBrowserBackStep.leavePage,
    );
  });

  // 入口页 / 多标签页浏览页的 widget 测试在 fushi_web_browser_shell_test.dart。

  test('chrome 摆放只看窗口宽度：窄窗口底部、宽窗口顶部', () {
    expect(
      webBrowserChromeLayout(size: const Size(390, 844)),
      WebBrowserChromeLayout.bottom,
    );
    expect(
      webBrowserChromeLayout(size: const Size(599, 900)),
      WebBrowserChromeLayout.bottom,
    );
    expect(
      webBrowserChromeLayout(size: const Size(600, 900)),
      WebBrowserChromeLayout.top,
    );
    expect(
      webBrowserChromeLayout(size: const Size(844, 390)),
      WebBrowserChromeLayout.top,
    );
    expect(
      webBrowserChromeLayout(size: const Size(1600, 1000)),
      WebBrowserChromeLayout.top,
    );
  });
}

class _RebuildableRoot extends StatefulWidget {
  const _RebuildableRoot({super.key});

  @override
  State<_RebuildableRoot> createState() => _RebuildableRootState();
}

class _RebuildableRootState extends State<_RebuildableRoot> {
  int _generation = 0;

  void rebuild() => setState(() => _generation++);

  @override
  Widget build(BuildContext context) =>
      FushiPageScaffold(title: 'root $_generation', body: const SizedBox());
}

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-5414（反馈 WtYMwfPjpe）：内置浏览器的网页全屏（网站请求全屏被截成页内
/// 伪全屏）只收起了浏览器自己的 chrome，桌面自绘顶栏照常常显，最小化 / 最大化 /
/// 关闭一直压在全屏视频右上角。页面经 [FushiTitleBarContentFullscreenScope] 声明
/// 页内全屏，顶栏整个收起；被别的整页盖住、退出全屏、离开页面都要还回来。
/// 浏览页本身的接线见 `test/pages/fushi_web_browser_shell_test.dart`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FushiDesktopTitleBar.debugIsEnabled = true;
    FushiDesktopTitleBar.debugHostPlatform = () => TargetPlatform.windows;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          MethodCall call,
        ) async {
          switch (call.method) {
            case 'isMaximized':
            case 'isFullScreen':
            case 'isFocused':
              return false;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    FushiDesktopTitleBar.debugIsEnabled = false;
    FushiDesktopTitleBar.debugHostPlatform = () => defaultTargetPlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  Finder closeButton() => find.byKey(FushiDesktopTitleBar.closeButtonKey);

  Future<void> pumpShell(
    WidgetTester tester, {
    required Widget home,
    GlobalKey<NavigatorState>? navigatorKey,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 760);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        builder: (BuildContext context, Widget? child) =>
            FushiDesktopTitleBar(title: const Text('Fushi'), child: child!),
        home: home,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('页内全屏时窗口按钮整个收起，页面拿到整窗；退出全屏还回来', (WidgetTester tester) async {
    final ValueNotifier<bool> fullscreen = ValueNotifier<bool>(false);
    addTearDown(fullscreen.dispose);
    double? pageTopPadding;
    await pumpShell(
      tester,
      home: ValueListenableBuilder<bool>(
        valueListenable: fullscreen,
        builder: (BuildContext context, bool value, Widget? _) =>
            FushiTitleBarContentFullscreenScope(
              enabled: value,
              child: Builder(
                builder: (BuildContext context) {
                  pageTopPadding = MediaQuery.paddingOf(context).top;
                  return const Scaffold();
                },
              ),
            ),
      ),
    );
    expect(closeButton(), findsOneWidget);
    expect(FushiDesktopTitleBar.contentFullscreen.value, isFalse);
    expect(pageTopPadding, FushiDesktopTitleBar.height);

    fullscreen.value = true;
    await tester.pumpAndSettle();
    expect(FushiDesktopTitleBar.contentFullscreen.value, isTrue);
    expect(closeButton(), findsNothing);
    expect(pageTopPadding, 0);

    fullscreen.value = false;
    await tester.pumpAndSettle();
    expect(FushiDesktopTitleBar.contentFullscreen.value, isFalse);
    expect(closeButton(), findsOneWidget);
    expect(pageTopPadding, FushiDesktopTitleBar.height);
  });

  testWidgets('全屏页被另一整页盖住时撤回，回到前台再收起，离开页面归还', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
    await pumpShell(
      tester,
      navigatorKey: nav,
      home: const FushiTitleBarContentFullscreenScope(
        enabled: true,
        child: Scaffold(),
      ),
    );
    expect(FushiDesktopTitleBar.contentFullscreen.value, isTrue);
    expect(closeButton(), findsNothing);

    nav.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
    expect(FushiDesktopTitleBar.contentFullscreen.value, isFalse);
    expect(closeButton(), findsOneWidget);

    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(FushiDesktopTitleBar.contentFullscreen.value, isTrue);
    expect(closeButton(), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(FushiDesktopTitleBar.contentFullscreen.value, isFalse);
  });
}

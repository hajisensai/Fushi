import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_hdr_output.dart'
    show hdrHostActiveGlobal;
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';
import 'package:window_manager/window_manager.dart' show DragToMoveArea;

/// 桌面自绘顶栏挂在 Navigator 外，`Theme.of` 只读得到根主题；阅读器的纸色是
/// 预设色（ecru `#F7F6EB`），与种子色生成的 `surface` 不同源——不上报，正文顶上
/// 就是一条白带（2026-10-01 macOS 录屏）。这里钉住上报通道的完整生命周期。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const Color paper = Color(0xFFF7F6EB);
  const Color ink = Color(0xFF3A3A3A);
  const FushiTitleBarColors readerColors = (background: paper, foreground: ink);

  setUp(() {
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  Future<ColorScheme> pumpShell(WidgetTester tester, Widget home) async {
    late ColorScheme scheme;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorSchemeSeed: const Color(0xFF8B7355)),
        navigatorKey: navigatorKey,
        builder: (BuildContext context, Widget? child) {
          scheme = Theme.of(context).colorScheme;
          return FushiDesktopTitleBar(
            title: const Text('Fushi'),
            child: child!,
          );
        },
        home: home,
      ),
    );
    await tester.pumpAndSettle();
    return scheme;
  }

  // 顶栏不再显示页面标题（用户 2026-10-04），按拖动区找标题行容器。
  Color? captionColor(WidgetTester tester) => tester
      .widget<Container>(
        find
            .ancestor(
              of: find.byType(DragToMoveArea),
              matching: find.byType(Container),
            )
            .first,
      )
      .color;

  /// 窗口按钮的前景色来源：页面上报的 foreground（null = 根主题 token）。
  Color? titleColor(WidgetTester tester) =>
      FushiDesktopTitleBar.pageColors.value?.foreground;

  Widget reader() => const FushiTitleBarColorScope(
    colors: readerColors,
    child: Scaffold(backgroundColor: paper),
  );

  testWidgets('没有页面上报时顶栏用根主题 surface', (WidgetTester tester) async {
    final ColorScheme scheme = await pumpShell(tester, const Scaffold());
    expect(captionColor(tester), scheme.surface);
    expect(titleColor(tester), isNull);
    expect(
      scheme.surface,
      isNot(paper),
      reason: '前置条件：种子色生成的 surface 与阅读器纸色不同，否则本测试是空壳',
    );
  });

  testWidgets('阅读器上报纸色后顶栏底色 / 标题色跟随，关书后回落', (WidgetTester tester) async {
    final ColorScheme scheme = await pumpShell(tester, const Scaffold());

    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => reader()),
    );
    await tester.pumpAndSettle();
    expect(captionColor(tester), paper);
    expect(titleColor(tester), ink);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(captionColor(tester), scheme.surface);
    expect(FushiDesktopTitleBar.pageColors.value, isNull);
  });

  testWidgets('被另一整页盖住时撤回、回到阅读器时恢复；弹窗不撤回', (WidgetTester tester) async {
    final ColorScheme scheme = await pumpShell(tester, reader());
    expect(captionColor(tester), paper);

    // 弹窗（PopupRoute）不推动 PageRoute 的 secondaryAnimation：顶栏不闪色。
    showDialog<void>(
      context: navigatorKey.currentContext!,
      builder: (_) => const AlertDialog(content: Text('dialog')),
    );
    await tester.pumpAndSettle();
    expect(captionColor(tester), paper);
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    // 整页（统计中心等）盖上来：由盖上来的页面决定，阅读器撤回。
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
    expect(captionColor(tester), scheme.surface);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(captionColor(tester), paper);
  });

  testWidgets('HDR 直通时内容区透明，标题行仍是不透明的页面色；半透明上报也叠成不透明', (
    WidgetTester tester,
  ) async {
    addTearDown(() => hdrHostActiveGlobal.value = false);
    final ColorScheme scheme = await pumpShell(
      tester,
      const FushiTitleBarColorScope(
        colors: (background: Color(0x80000000), foreground: ink),
        child: SizedBox.expand(),
      ),
    );
    hdrHostActiveGlobal.value = true;
    await tester.pumpAndSettle();

    final Color caption = captionColor(tester)!;
    expect(caption.a, 1.0, reason: '标题行透明 = HDR 时能看见后面的窗口');
    expect(caption, Color.alphaBlend(const Color(0x80000000), scheme.surface));
    final ColoredBox frame = tester.widget<ColoredBox>(
      find
          .ancestor(of: find.byType(Column), matching: find.byType(ColoredBox))
          .first,
    );
    expect(frame.color, Colors.transparent, reason: '内容区底色仍听 HDR 让开');
  });

  testWidgets('阅读器在 build 中改色（切换阅读主题）顶栏跟着重画', (WidgetTester tester) async {
    final ValueNotifier<Color> bg = ValueNotifier<Color>(paper);
    addTearDown(bg.dispose);
    await pumpShell(
      tester,
      ValueListenableBuilder<Color>(
        valueListenable: bg,
        builder: (_, Color color, __) => FushiTitleBarColorScope(
          colors: (background: color, foreground: ink),
          child: Scaffold(backgroundColor: color),
        ),
      ),
    );
    expect(captionColor(tester), paper);

    bg.value = const Color(0xFF1E1E1E);
    await tester.pumpAndSettle();
    expect(captionColor(tester), const Color(0xFF1E1E1E));
    expect(tester.takeException(), isNull);
  });
}

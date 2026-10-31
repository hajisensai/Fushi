import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';
import 'package:fushi/src/utils/window_caption_channel.dart';
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
    // 上报通道的生命周期与宿主无关；沉浸页的版面各宿主一致（铺满整窗、
    // 顶栏悬停浮出），见文件末尾按宿主分的组。
    FushiDesktopTitleBar.debugHostPlatform = () => TargetPlatform.macOS;
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
    FushiDesktopTitleBar.debugHostPlatform = () => defaultTargetPlatform;
    WindowCaptionChannel.captionMaxButtonHovered.value = false;
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

  /// 页面上报的底色（沉浸页标题行透明，按钮组 / 柔光从它派生）。
  Color? reportedBackground(WidgetTester tester) =>
      FushiDesktopTitleBar.pageColors.value?.background;

  Widget reader() => const FushiTitleBarColorScope(
    colors: readerColors,
    child: Scaffold(backgroundColor: paper),
  );

  testWidgets('没有页面上报时顶栏透明，浮在页面上', (WidgetTester tester) async {
    final ColorScheme scheme = await pumpShell(tester, const Scaffold());
    expect(captionColor(tester), Colors.transparent);
    expect(titleColor(tester), isNull);
    expect(
      scheme.surface,
      isNot(paper),
      reason: '前置条件：种子色生成的 surface 与阅读器纸色不同，否则本测试是空壳',
    );
  });

  testWidgets('阅读器上报纸色后上报纸色 / 前景色，关书后回落', (WidgetTester tester) async {
    await pumpShell(tester, const Scaffold());

    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => reader()),
    );
    await tester.pumpAndSettle();
    expect(reportedBackground(tester), paper);
    expect(titleColor(tester), ink);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(reportedBackground(tester), isNull);
    expect(FushiDesktopTitleBar.pageColors.value, isNull);
  });

  testWidgets('被另一整页盖住时撤回、回到阅读器时恢复；弹窗不撤回', (WidgetTester tester) async {
    await pumpShell(tester, reader());
    expect(reportedBackground(tester), paper);

    // 弹窗（PopupRoute）不推动 PageRoute 的 secondaryAnimation：顶栏不闪色。
    showDialog<void>(
      context: navigatorKey.currentContext!,
      builder: (_) => const AlertDialog(content: Text('dialog')),
    );
    await tester.pumpAndSettle();
    expect(reportedBackground(tester), paper);
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    // 整页（统计中心等）盖上来：由盖上来的页面决定，阅读器撤回。
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
    expect(reportedBackground(tester), isNull);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(reportedBackground(tester), paper);
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
    expect(reportedBackground(tester), paper);

    bg.value = const Color(0xFF1E1E1E);
    await tester.pumpAndSettle();
    expect(reportedBackground(tester), const Color(0xFF1E1E1E));
    expect(tester.takeException(), isNull);
  });

  // 沉浸页铺满整窗，顶栏悬停才浮出（用户 2026-10-30「顶栏条只有在应用外才
  // 显示……都要占满」「目的只是为了更多显示面积」；同日「mac 也要和 windows
  // 一样……顶部胶囊位置不变」）。macOS 的系统红绿灯随标题行显隐。
  for (final TargetPlatform host in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.macOS,
  ]) {
    group('${host.name} 沉浸页', () {
      setUp(() => FushiDesktopTitleBar.debugHostPlatform = () => host);

      // 顶边停留触发时长（与组件内 _kImmersiveRevealDwell 一致）。
      const Duration dwell = Duration(milliseconds: 400);

      double captionOpacity(WidgetTester tester) => tester
          .widget<AnimatedOpacity>(
            find
                .ancestor(
                  of: find.byType(DragToMoveArea),
                  matching: find.byType(AnimatedOpacity),
                )
                .first,
          )
          .opacity;

      testWidgets('页面从窗口顶端铺起，padding 仍为顶栏让位；标题行透明', (
        WidgetTester tester,
      ) async {
        await pumpShell(tester, reader());

        final Finder page = find.byType(Scaffold).last;
        expect(tester.getTopLeft(page).dy, 0, reason: '沉浸页不再被顶栏下推');
        expect(
          MediaQuery.paddingOf(tester.element(page)).top,
          greaterThanOrEqualTo(FushiDesktopTitleBar.height),
          reason: '页面的悬浮胶囊要按 padding 排在窗口按钮下面',
        );
        expect(FushiDesktopTitleBar.pageColors.value, readerColors);
        // macOS：浮出时铺一层不可见（1/255）的页面底色，让这一条在 WKWebView
        // 上方归 Flutter 命中、拖得动窗口；Windows 全透明。
        expect(
          captionColor(tester),
          host == TargetPlatform.macOS
              ? paper.withAlpha(1)
              : Colors.transparent,
        );
      });

      testWidgets('指针进入顶栏才显示，离开淡出；原生最大化键悬停也算', (WidgetTester tester) async {
        await pumpShell(tester, reader());
        expect(captionOpacity(tester), 0);

        final TestGesture mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: const Offset(200, 300));
        await mouse.moveTo(const Offset(200, 8));
        await tester.pump(dwell);
        await tester.pumpAndSettle();
        expect(captionOpacity(tester), 1);

        await mouse.moveTo(const Offset(200, 300));
        await tester.pumpAndSettle();
        expect(captionOpacity(tester), 0);

        // 最大化键是 runner 的 HTMAXBUTTON 原生命中区：Flutter 只收到离开，
        // 悬停真值由原生回传，不并进来指针一停到最大化键整条就隐去。
        WindowCaptionChannel.captionMaxButtonHovered.value = true;
        await tester.pumpAndSettle();
        expect(captionOpacity(tester), 1);
        WindowCaptionChannel.captionMaxButtonHovered.value = false;
        await tester.pumpAndSettle();
        expect(captionOpacity(tester), 0);
      });

      testWidgets('从下面移进带子 / 划过顶边不浮出（顶部正文照常可点），在顶边停留才浮出', (
        WidgetTester tester,
      ) async {
        await pumpShell(tester, reader());
        final TestGesture mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: const Offset(200, 300));
        await mouse.moveTo(const Offset(200, 20));
        await tester.pumpAndSettle();
        expect(captionOpacity(tester), 0, reason: '带子里的正文要能点击查词');

        // 划过顶边（手滑出窗口再划回来）不浮出：没停够就离开了顶边。
        await mouse.moveTo(const Offset(200, 3));
        await tester.pump(const Duration(milliseconds: 150));
        await mouse.moveTo(const Offset(200, 20));
        await tester.pump(dwell);
        await tester.pumpAndSettle();
        expect(captionOpacity(tester), 0, reason: '路过顶边不算想要顶栏');

        await mouse.moveTo(const Offset(200, 3));
        await tester.pump(dwell);
        await tester.pumpAndSettle();
        expect(captionOpacity(tester), 1);

        // 浮出后在带子里往下移（去拖动 / 点窗口按钮）保持显示。
        await mouse.moveTo(const Offset(200, 24));
        await tester.pumpAndSettle();
        expect(captionOpacity(tester), 1);
      });

      testWidgets('触摸没有悬停：带子里按下浮出，带子外按下收起', (WidgetTester tester) async {
        await pumpShell(tester, reader());
        expect(captionOpacity(tester), 0);

        final TestGesture touch = await tester.startGesture(
          const Offset(200, 8),
          kind: PointerDeviceKind.touch,
        );
        await touch.up();
        await tester.pumpAndSettle();
        expect(captionOpacity(tester), 1, reason: '纯触屏也要够得着窗口按钮');

        // 浮出后再点带子里（窗口按钮所在处）不收起。
        final TestGesture again = await tester.startGesture(
          const Offset(300, 10),
          kind: PointerDeviceKind.touch,
        );
        await again.up();
        await tester.pumpAndSettle();
        expect(captionOpacity(tester), 1);

        final TestGesture outside = await tester.startGesture(
          const Offset(200, 300),
          kind: PointerDeviceKind.touch,
        );
        await outside.up();
        await tester.pumpAndSettle();
        expect(captionOpacity(tester), 0);
      });

      testWidgets('普通页（未上报配色）顶栏常显', (WidgetTester tester) async {
        await pumpShell(tester, const Scaffold());
        expect(captionOpacity(tester), 1);
      });
    });
  }
}

// BUG-2953 第二段：查词浮层自带导航层（[LookupOverlayNavigator]）里开着菜单时，
// 「返回」只关菜单，再按一次才关浮层——与菜单还在根 Navigator 上时的行为一致。
//
// 菜单住进内层 Navigator 后，所有返回入口仍只认根 Navigator：系统返回键经
// `WidgetsApp.didPopRoute` → 根 `maybePop()` → 页面 `PopScope`（视频页关浮层），浮层连同
// 菜单一起没了。修法是所有返回入口先问 [LookupOverlayNavigator.activeMenuNavigator]：
// 系统返回键靠 runApp 之前注册的 observer、预测性返回靠根栈顶的 canPop:false 守卫、
// Esc / Alt+← / 手柄 B / 鼠标返回键靠 global_navigation / gamepad_service 的根兜底。
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/lookup_overlay_navigator.dart';
import 'package:fushi/src/shortcuts/global_navigation.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';

const Color _kPopupColor = Color(0xFF224466);

class _Probe {
  int pagePopInvoked = 0;
  String? selected;
}

/// 镜像视频页：根 Overlay 手动 insert 浮层 entry（包导航层），页面 `PopScope`
/// 拦返回并先关浮层。[guardPop] 为 false 时不挂 PopScope（页面可直接被弹出）。
class _HostPage extends StatefulWidget {
  const _HostPage({required this.probe, required this.guardPop});

  final _Probe probe;
  final bool guardPop;

  @override
  State<_HostPage> createState() => _HostPageState();
}

class _HostPageState extends State<_HostPage> {
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _entry != null) return;
      final OverlayEntry entry = OverlayEntry(builder: _buildPopupOverlay);
      _entry = entry;
      Overlay.of(context, rootOverlay: true).insert(entry);
    });
  }

  void _closePopup() {
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
  }

  Future<void> _showMenu(
    BuildContext popupContext,
    Offset globalPosition,
  ) async {
    final RenderBox overlayBox =
        Overlay.of(popupContext).context.findRenderObject()! as RenderBox;
    final Offset anchor = overlayBox.globalToLocal(globalPosition);
    final Size size = overlayBox.size;
    widget.probe.selected = await showFushiMenu<String>(
      context: popupContext,
      position: RelativeRect.fromLTRB(
        anchor.dx,
        anchor.dy,
        size.width - anchor.dx,
        size.height - anchor.dy,
      ),
      items: const <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: 'copy', child: Text('COPY')),
      ],
    );
  }

  Widget _buildPopupOverlay(BuildContext overlayContext) {
    return LookupOverlayNavigator(
      child: Stack(
        children: <Widget>[
          Positioned(
            left: 100,
            top: 100,
            width: 400,
            height: 300,
            child: Builder(
              builder: (BuildContext popupContext) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onSecondaryTapDown: (TapDownDetails d) =>
                    _showMenu(popupContext, d.globalPosition),
                child: const ColoredBox(color: _kPopupColor),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _closePopup();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const Widget body = Scaffold(body: Center(child: Text('host-page')));
    if (!widget.guardPop) return body;
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) return;
        widget.probe.pagePopInvoked++;
        // 视频页 _dismissTopForegroundLayer 的语义：浮层开着先关浮层。
        _closePopup();
      },
      child: body,
    );
  }
}

Finder get _popupBox => find.byWidgetPredicate(
  (Widget w) => w is ColoredBox && w.color == _kPopupColor,
);

Future<_Probe> _pumpHost(
  WidgetTester tester, {
  bool guardPop = true,
  bool globalNavigation = false,
}) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final _Probe probe = _Probe();
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
  final FushiShortcutRegistry registry = FushiShortcutRegistry()
    ..loadDefaults(TargetPlatform.windows);
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navKey,
      builder: globalNavigation
          ? (BuildContext context, Widget? child) => wrapWithGlobalNavigation(
              navigatorKey: navKey,
              registry: registry,
              child: child!,
            )
          : null,
      home: const Scaffold(body: Center(child: Text('root-home'))),
    ),
  );
  // 宿主页压在根页之上（视频页同形：根 Navigator 可弹出）。
  navKey.currentState!.push(
    MaterialPageRoute<void>(
      builder: (_) => _HostPage(probe: probe, guardPop: guardPop),
    ),
  );
  await tester.pumpAndSettle();
  expect(_popupBox, findsOneWidget);
  return probe;
}

Future<void> _openMenu(WidgetTester tester) async {
  final TestGesture gesture = await tester.startGesture(
    const Offset(300, 250),
    buttons: kSecondaryMouseButton,
    kind: PointerDeviceKind.mouse,
  );
  await gesture.up();
  await tester.pumpAndSettle();
  expect(find.text('COPY'), findsOneWidget);
  expect(LookupOverlayNavigator.activeMenuNavigator, isNotNull);
}

Future<void> _systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

void main() {
  // 生产在 runApp 之前装（main.dart）；测试在任何 pumpWidget 之前装，顺序同构。
  setUpAll(LookupOverlayNavigator.installSystemBackInterceptor);

  testWidgets('system back with the menu open closes only the menu, '
      'the next back closes the popup', (WidgetTester tester) async {
    final _Probe probe = await _pumpHost(tester);
    await _openMenu(tester);

    await _systemBack(tester);
    expect(find.text('COPY'), findsNothing, reason: '第一次返回关菜单');
    expect(_popupBox, findsOneWidget, reason: '浮层不能跟着菜单一起关');
    expect(probe.pagePopInvoked, 0, reason: '页面 PopScope 不该被触发');
    expect(probe.selected, isNull);
    expect(LookupOverlayNavigator.activeMenuNavigator, isNull);

    await _systemBack(tester);
    expect(probe.pagePopInvoked, 1, reason: '第二次返回才轮到页面关浮层');
    expect(_popupBox, findsNothing);
    expect(find.text('host-page'), findsOneWidget, reason: '页面本身还在');
  });

  testWidgets('system back without a menu keeps the page back logic', (
    WidgetTester tester,
  ) async {
    final _Probe probe = await _pumpHost(tester);
    expect(LookupOverlayNavigator.activeMenuNavigator, isNull);

    await _systemBack(tester);
    expect(probe.pagePopInvoked, 1);
    expect(_popupBox, findsNothing);
  });

  testWidgets('predictive back: the top root route cannot gesture-pop while '
      'the menu is open (guard removed once it closes)', (
    WidgetTester tester,
  ) async {
    await _pumpHost(tester, guardPop: false);
    final ModalRoute<Object?> hostRoute = ModalRoute.of(
      tester.element(find.text('host-page')),
    )!;
    expect(hostRoute.popGestureEnabled, isTrue);

    await _openMenu(tester);
    expect(hostRoute.popDisposition, RoutePopDisposition.doNotPop);
    expect(hostRoute.popGestureEnabled, isFalse, reason: '菜单开着时页面不能被侧滑手势跟手拖走');

    // 无 PopScope 的页面也只关菜单（手势提交后框架退化为 handlePopRoute）。
    await _systemBack(tester);
    expect(find.text('COPY'), findsNothing);
    expect(find.text('host-page'), findsOneWidget);
    expect(_popupBox, findsOneWidget);
    expect(hostRoute.popDisposition, RoutePopDisposition.pop);
    expect(hostRoute.popGestureEnabled, isTrue);
  });

  testWidgets('global back key (Alt+←) and Escape close the menu first', (
    WidgetTester tester,
  ) async {
    final _Probe probe = await _pumpHost(tester, globalNavigation: true);

    await _openMenu(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(find.text('COPY'), findsNothing);
    expect(_popupBox, findsOneWidget);
    expect(probe.pagePopInvoked, 0);

    await _openMenu(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('COPY'), findsNothing);
    expect(_popupBox, findsOneWidget);
    expect(probe.pagePopInvoked, 0);

    // 没有菜单时 Esc 照旧交给页面（关浮层）。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(probe.pagePopInvoked, 1);
    expect(_popupBox, findsNothing);
  });

  test('every root back entry asks the lookup menu first', () {
    final String main = File('lib/main.dart').readAsStringSync();
    final int install = main.indexOf(
      'LookupOverlayNavigator.installSystemBackInterceptor();',
    );
    expect(install, isNonNegative, reason: 'main 必须安装系统返回拦截');
    expect(
      install,
      lessThan(main.indexOf('    runApp(')),
      reason: '必须在 runApp（WidgetsApp 注册 observer）之前安装',
    );

    final String nav = File(
      'lib/src/shortcuts/global_navigation.dart',
    ).readAsStringSync();
    for (final String fn in <String>[
      'KeyEventResult _handleGlobalBack(',
      'KeyEventResult _handleEscapeWithoutRegistry(',
      'bool _executeGlobalMouseAction(',
    ]) {
      final int start = nav.indexOf(fn);
      expect(start, isNonNegative, reason: fn);
      final int ask = nav.indexOf(
        'LookupOverlayNavigator.popActiveMenu()',
        start,
      );
      final int rootPop = nav.indexOf('maybePop()', start);
      expect(ask, isNonNegative, reason: '$fn 必须先问查词菜单');
      expect(ask, lessThan(rootPop), reason: '$fn：先关菜单，再根 maybePop');
    }

    final String gamepad = File(
      'lib/src/shortcuts/gamepad_service.dart',
    ).readAsStringSync();
    final int caseB = gamepad.indexOf('case GamepadButton.b:');
    final int ask = gamepad.indexOf(
      'LookupOverlayNavigator.popActiveMenu()',
      caseB,
    );
    final int rootPop = gamepad.indexOf(
      'navigatorKey.currentState?.maybePop()',
      caseB,
    );
    expect(caseB, isNonNegative);
    expect(ask, isNonNegative, reason: '手柄 B 兜底必须先问查词菜单');
    expect(ask, lessThan(rootPop));
  });
}

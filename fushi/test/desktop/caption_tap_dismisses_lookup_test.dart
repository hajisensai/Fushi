import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kDoubleTapMinTime, kDoubleTapTimeout;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/source_guard.dart';

/// BUG-4475：有声书歌词模式（及其它隐形拖动条页）里查词弹窗打开时，点窗口最顶部
/// 关不掉弹窗。
///
/// 标题行叠在整个 Navigator 之上，隐形拖动条的 `DragToMoveArea` 常驻可命中，
/// 页面里弹窗的 dismiss barrier 在那 32px 里收不到指针。修法：标题行拖动区的
/// **单击**转发给 [FushiDesktopTitleBar.addCaptionTapListener] 订阅者，查词页
/// （base_source_page）按「点在弹窗外」走 barrier 同一钩子；拖动 / 双击仍归窗口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<String> windowCalls = <String>[];

  setUp(() {
    windowCalls.clear();
    FushiDesktopTitleBar.debugIsEnabled = true;
    FushiDesktopTitleBar.debugHostPlatform = () => TargetPlatform.windows;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          MethodCall call,
        ) async {
          windowCalls.add(call.method);
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

  const Offset captionPoint = Offset(400, 18);

  Future<List<Offset>> pumpDragBandPage(
    WidgetTester tester, {
    required VoidCallback onPageTap,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 760);
    addTearDown(tester.view.reset);
    final List<Offset> taps = <Offset>[];
    void listener(Offset p) => taps.add(p);
    FushiDesktopTitleBar.addCaptionTapListener(listener);
    addTearDown(() => FushiDesktopTitleBar.removeCaptionTapListener(listener));
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            FushiDesktopTitleBar(title: const Text('Fushi'), child: child!),
        home: FushiTitleBarColorScope(
          colors: const (
            background: Color(0xFF402020),
            foreground: Color(0xFFFFFFFF),
          ),
          child: FushiTitleBarDragBandScope(
            // 页面全屏层（相当于查词 barrier）：拖动条底下它收不到点击。
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onPageTap,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(FushiDesktopTitleBar.captionDragBand.value, isTrue, reason: '前置');
    return taps;
  }

  testWidgets('隐形拖动条上单击 → 转发全局坐标给订阅者（页面层本身收不到）', (WidgetTester tester) async {
    int pageTaps = 0;
    final List<Offset> taps = await pumpDragBandPage(
      tester,
      onPageTap: () => pageTaps++,
    );

    await tester.tapAt(captionPoint, kind: PointerDeviceKind.mouse);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(pageTaps, 0, reason: '前置：拖动条盖住了页面层，这正是 bug 的成因');
    expect(taps, <Offset>[captionPoint]);
    expect(windowCalls, isNot(contains('startDragging')));
    expect(windowCalls, isNot(contains('maximize')));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('拖动仍拖窗口、双击仍最大化，都不算单击', (WidgetTester tester) async {
    final List<Offset> taps = await pumpDragBandPage(tester, onPageTap: () {});

    final TestGesture mouse = await tester.startGesture(
      captionPoint,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(60, 0));
    await mouse.moveBy(const Offset(60, 0));
    await mouse.up();
    await mouse.removePointer();
    await tester.pumpAndSettle();
    expect(windowCalls, contains('startDragging'));

    await tester.tapAt(captionPoint, kind: PointerDeviceKind.mouse);
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(captionPoint, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(windowCalls, contains('maximize'));

    expect(taps, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  test('查词页订阅标题行单击，弹窗可见且是当前路由时走 dismiss barrier 钩子', () {
    final String src = maskComments(
      File('lib/src/pages/base_source_page.dart').readAsStringSync(),
    );
    expect(src, contains('FushiDesktopTitleBar.addCaptionTapListener('));
    expect(src, contains('FushiDesktopTitleBar.removeCaptionTapListener('));
    final int start = src.indexOf('void _onCaptionTap(Offset globalPosition)');
    expect(start, greaterThanOrEqualTo(0));
    final String body = src.substring(start, src.indexOf('\n  }', start));
    expect(body, contains('isDictionaryShown'));
    expect(body, contains('isCurrent'));
    expect(body, contains('onDismissBarrierTap(globalPosition)'));
  });
}

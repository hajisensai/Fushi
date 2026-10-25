import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show PointerHoverEvent;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';
import 'package:fushi/src/utils/adaptive/nav_bar_style.dart';
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_mode_strip_bar.dart';
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_overflow_spec.dart';
import 'package:fushi/src/utils/misc/stale_pointer_guard.dart';
import 'package:material_ui/material_ui.dart';

// 2026-10-25 用户（Windows）：相机模式条「拖过快会卡住」「切不了 ui 了」。
// 根因：鼠标在窗口外松开时引擎没送来抬起，横向拖动识别器一直以为指针按着，
// 底栏停在半路、后续拖动只被当成同一次拖动的第二根手指。全局指针守卫
// （installStalePointerGuard）在同一设备的 hover / 新按下时补发取消。

const List<IconData> _icons = <IconData>[
  Icons.home_outlined,
  Icons.book_outlined,
  Icons.image_outlined,
  Icons.movie_outlined,
  Icons.gamepad_outlined,
  Icons.explore_outlined,
  Icons.sync,
  Icons.public,
  Icons.tune,
  Icons.search,
];

Future<ValueNotifier<int>> _pumpHost(WidgetTester tester) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final ValueNotifier<int> index = ValueNotifier<int>(0);
  await tester.pumpWidget(
    MaterialApp(
      home: FushiFocusRoot(
        child: ValueListenableBuilder<int>(
          valueListenable: index,
          builder: (BuildContext context, int current, Widget? _) => Scaffold(
            body: const SizedBox.expand(),
            bottomNavigationBar: adaptiveBottomBar(
              context: context,
              currentIndex: current,
              onTap: (int i) => index.value = i,
              onDragSelect: (int i) => index.value = i,
              items: <AdaptiveNavItem>[
                for (int i = 0; i < _icons.length; i++)
                  AdaptiveNavItem(icon: _icons[i], label: 'M$i'),
              ],
              showLabels: false,
              barStyle: AdaptiveNavBarStyle.modeStrip,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return index;
}

/// 按 6 帧拖过 [dx]，最后抬起。
Future<void> _fastDrag(
  WidgetTester tester,
  Finder target,
  double dx,
  PointerDeviceKind kind,
) async {
  final TestGesture g = await tester.startGesture(
    tester.getCenter(target),
    kind: kind,
  );
  for (int i = 0; i < 6; i++) {
    await g.moveBy(Offset(dx / 6, 0));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up();
}

/// 鼠标拖到一半、抬起丢了（窗口外松开）。
Future<void> _lostMouseDrag(WidgetTester tester, Finder strip) async {
  final TestGesture lost = await tester.startGesture(
    tester.getCenter(strip),
    kind: PointerDeviceKind.mouse,
  );
  for (int i = 0; i < 6; i++) {
    await lost.moveBy(const Offset(-50, 0));
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 当前项停在静止位置：没有残留拖动位移（不卡在半路）。2026-10-25 起条带
/// 首尾贴边、两端不留白（[navModeStripTrackOffset]），中间的项照旧居中，
/// 靠两端的项贴边，所以按同一份几何算期望位置，而不是一律比条带中线。
void _expectSettled(WidgetTester tester, ValueNotifier<int> index) {
  final Finder stripFinder = find.byType(NavModeStripBar);
  final Rect strip = tester.getRect(stripFinder);
  final NavOverflowSpec spec = tester.widget<NavModeStripBar>(stripFinder).spec;
  final int pos = spec.indices.indexOf(index.value);
  final int count = spec.indices.length;
  final double slot = navModeStripSlotWidth(spec.width, count);
  final double expected =
      strip.left +
      navModeStripTrackOffset(
        width: spec.width,
        count: count,
        sel: pos.toDouble(),
        drag: 0,
      ) +
      pos * slot +
      slot / 2;
  final Rect icon = tester.getRect(find.byIcon(_icons[index.value]).first);
  expect(
    (icon.center.dx - expected).abs(),
    lessThan(2),
    reason: '当前项 ${index.value} 在 ${icon.center.dx}，静止位置 $expected',
  );
}

void main() {
  setUpAll(installStalePointerGuard);

  for (final PointerDeviceKind kind in <PointerDeviceKind>[
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
  ]) {
    testWidgets('[$kind] 连续快速甩动后当前项停回静止位置', (WidgetTester tester) async {
      final ValueNotifier<int> index = await _pumpHost(tester);
      final Finder strip = find.byType(NavModeStripBar);
      for (final double dx in <double>[-300, -300, 250, -200, 300, -400]) {
        await tester.fling(strip, Offset(dx, 0), 3000, deviceKind: kind);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      _expectSettled(tester, index);
    });

    testWidgets('[$kind] 一次拖很远（超过两端）后停回静止位置', (WidgetTester tester) async {
      final ValueNotifier<int> index = await _pumpHost(tester);
      final Finder strip = find.byType(NavModeStripBar);
      await _fastDrag(tester, strip, -900, kind);
      await tester.pumpAndSettle();
      _expectSettled(tester, index);
      await _fastDrag(tester, strip, 900, kind);
      await tester.pumpAndSettle();
      _expectSettled(tester, index);
    });

    testWidgets('[$kind] 拖动中指针被取消后停回静止位置', (WidgetTester tester) async {
      final ValueNotifier<int> index = await _pumpHost(tester);
      final Finder strip = find.byType(NavModeStripBar);
      final TestGesture g = await tester.startGesture(
        tester.getCenter(strip),
        kind: kind,
      );
      for (int i = 0; i < 6; i++) {
        await g.moveBy(const Offset(-50, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.cancel();
      await tester.pumpAndSettle();
      _expectSettled(tester, index);
    });
  }

  testWidgets('鼠标抬起丢了：随后的 hover 收尾拖动，当前项停回静止位置且还能再拖', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<int> index = await _pumpHost(tester);
    final Finder strip = find.byType(NavModeStripBar);
    await _lostMouseDrag(tester, strip);
    // 同一只鼠标回到窗口里移动（无按键 = hover）：抬起其实早就发生了。
    // 测试里鼠标的设备号固定是 1（与真实 Windows 一样同一只鼠标同一个设备号）。
    await tester.sendEventToBinding(
      PointerHoverEvent(
        device: 1,
        kind: PointerDeviceKind.mouse,
        position: tester.getCenter(strip),
      ),
    );
    await tester.pumpAndSettle();
    _expectSettled(tester, index);
    final int before = index.value;
    await _fastDrag(tester, strip, 120, PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(index.value, isNot(before), reason: '收尾后新的拖动照常切模块');
    _expectSettled(tester, index);
  });

  testWidgets('鼠标抬起丢了：直接再按下拖动，松手后当前项停回静止位置', (WidgetTester tester) async {
    final ValueNotifier<int> index = await _pumpHost(tester);
    final Finder strip = find.byType(NavModeStripBar);
    await _lostMouseDrag(tester, strip);
    await tester.pump(const Duration(seconds: 1));
    await _fastDrag(tester, strip, 120, PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    _expectSettled(tester, index);
  });
}

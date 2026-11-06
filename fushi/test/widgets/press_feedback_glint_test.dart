import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_grid.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';

/// 合集里长按没有触感、轻触 / 长按看不到封面光面扫光（用户 2026-10-27）。
///
/// - 合集成员拖排网格 / 视频合集集卡网格走 [FushiReorderableGrid] 的裸识别器，
///   卡片包在 IgnorePointer 里，没有库页 `InkWell` 自带的 `Feedback.forLongPress`；
/// - 封面扫光 [ShelfCoverSheen] 原先只认悬停，触屏上永远不出现。
void main() {
  group('FushiReorderableGrid 触摸反馈', () {
    late List<String> haptics;

    setUp(() {
      haptics = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (
            MethodCall call,
          ) async {
            if (call.method == 'HapticFeedback.vibrate') {
              haptics.add('${call.method}:${call.arguments}');
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    Future<void> pumpGrid(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: FushiReorderableGrid(
                  itemCount: 3,
                  crossAxisCount: 3,
                  childAspectRatio: 1,
                  keyForIndex: (int i) => ValueKey<int>(i),
                  onReorder: (int from, int to) {},
                  onActivateItem: (int i) {},
                  onContextMenu: (int i, Offset p) {},
                  itemBuilder: (BuildContext context, int i) =>
                      Center(child: Text('$i')),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('触摸长按一被识别就震（与库页 InkWell 长按同一份反馈）', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await pumpGrid(tester);
        final TestGesture g = await tester.startGesture(
          tester.getCenter(find.text('0')),
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
        expect(haptics, hasLength(1), reason: '长按识别时就该有触感，不等松手');
        await g.up();
        await tester.pumpAndSettle();
        expect(haptics, hasLength(1));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('轻点不震', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await pumpGrid(tester);
        await tester.tap(find.text('1'));
        await tester.pumpAndSettle();
        expect(haptics, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('网格单元自带按压脉冲：IgnorePointer 里的卡片也收得到', (
      WidgetTester tester,
    ) async {
      final List<int> seen = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: FushiReorderableGrid(
                  itemCount: 1,
                  crossAxisCount: 3,
                  childAspectRatio: 1,
                  keyForIndex: (int i) => ValueKey<int>(i),
                  onReorder: (int from, int to) {},
                  onActivateItem: (int i) {},
                  itemBuilder: (BuildContext context, int i) => IgnorePointer(
                    child: Builder(
                      builder: (BuildContext context) {
                        seen.add(FushiPressScale.pulseOf(context));
                        return const Center(child: Text('card'));
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('card'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(seen.last, 1);
    });
  });

  group('FushiPressScale 按压脉冲', () {
    Future<List<int>> pumpProbe(
      WidgetTester tester, {
      bool nested = false,
    }) async {
      final List<int> seen = <int>[];
      final Widget probe = Builder(
        builder: (BuildContext context) {
          seen.add(FushiPressScale.pulseOf(context));
          return const ColoredBox(
            color: Color(0xFF000000),
            child: SizedBox(width: 100, height: 100),
          );
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: FushiPressScale(
              behavior: nested
                  ? HitTestBehavior.opaque
                  : HitTestBehavior.deferToChild,
              child: nested
                  // 内层那份收不到指针（合集网格里卡片的情形），外层代收。
                  ? IgnorePointer(child: FushiPressScale(child: probe))
                  : probe,
            ),
          ),
        ),
      );
      return seen;
    }

    testWidgets('快速轻触补发一次', (WidgetTester tester) async {
      final List<int> seen = await pumpProbe(tester);
      final TestGesture g = await tester.startGesture(
        tester.getCenter(find.byType(SizedBox).last),
      );
      await tester.pump(const Duration(milliseconds: 30));
      await g.up();
      await tester.pumpAndSettle();
      expect(seen.last, 1);
    });

    testWidgets('按住超过按下时限只发一次（长按）', (WidgetTester tester) async {
      final List<int> seen = await pumpProbe(tester);
      final TestGesture g = await tester.startGesture(
        tester.getCenter(find.byType(SizedBox).last),
      );
      await tester.pump(kPressTimeout + const Duration(milliseconds: 10));
      expect(seen.last, 1);
      await tester.pump(kLongPressTimeout);
      await g.up();
      await tester.pumpAndSettle();
      expect(seen.last, 1);
    });

    testWidgets('滑走（滚动起手）不发', (WidgetTester tester) async {
      final List<int> seen = await pumpProbe(tester);
      final Offset c = tester.getCenter(find.byType(SizedBox).last);
      final TestGesture g = await tester.startGesture(c);
      await g.moveBy(const Offset(0, kTouchSlop + 4));
      await tester.pump(kPressTimeout * 2);
      await g.up();
      await tester.pumpAndSettle();
      expect(seen.last, 0);
    });

    testWidgets('外层脉冲透传到内层', (WidgetTester tester) async {
      final List<int> seen = await pumpProbe(tester, nested: true);
      await tester.tapAt(tester.getCenter(find.byType(ColoredBox).last));
      await tester.pumpAndSettle();
      expect(seen.last, 1);
    });
  });

  group('ShelfCoverSheen 轻触扫光', () {
    Finder band() => find.descendant(
      of: find.byType(ShelfCoverSheen),
      matching: find.byType(CustomPaint),
    );

    Future<void> pumpSheen(WidgetTester tester, {bool glint = true}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: FushiPressScale(
              child: ColoredBox(
                color: const Color(0xFF000000),
                child: SizedBox(
                  width: 100,
                  height: 150,
                  child: ShelfCoverSheen(active: false, glint: glint),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('轻触扫过一遍，扫完悄悄归位', (WidgetTester tester) async {
      await pumpSheen(tester);
      expect(band(), findsNothing);
      await tester.tap(find.byType(ShelfCoverSheen), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(band(), findsOneWidget, reason: '光带正扫过封面');
      await tester.pumpAndSettle();
      expect(band(), findsNothing, reason: '扫完停在封面外，不画');
      // 归位后再点还能再扫一遍。
      await tester.tap(find.byType(ShelfCoverSheen), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(band(), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('glint: false（叠层后几本）不响应按压', (WidgetTester tester) async {
      await pumpSheen(tester, glint: false);
      await tester.tap(find.byType(ShelfCoverSheen), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(band(), findsNothing);
    });
  });
}

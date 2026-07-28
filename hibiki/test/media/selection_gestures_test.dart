import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/selection/media_selection_controller.dart';
import 'package:hibiki/src/media/selection/selection_gestures.dart';

/// 多选手势层：长按扫选的命中反查、启用门控，以及修饰键判定。
///
/// 这些是「长按 = 进多选 / 扫选」这套手势归属重划里最容易悄悄坏掉的部分——
/// 命中测试走真实渲染树，改布局、加遮挡层都可能让它反查不到卡片。
void main() {
  /// 竖排 5 张卡的最小库页：每张贴 [SelectionSlotTarget] 身份标记，整体包在
  /// [SelectionDragArea] 里。
  Widget buildHarness({
    required MediaSelectionController controller,
    required bool enabled,
    required VoidCallback onChanged,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SelectionDragArea(
          enabled: enabled,
          onDragBegin: (SelectionSlot slot) {
            controller.beginRangeDrag(slot);
            onChanged();
          },
          onDragUpdate: (SelectionSlot slot) {
            controller.updateRangeDrag(slot);
            onChanged();
          },
          onDragEnd: () {
            controller.endRangeDrag();
            onChanged();
          },
          child: Column(
            children: <Widget>[
              for (int i = 0; i < 5; i++)
                SelectionSlotTarget(
                  slot: SelectionSlot.loose('card-$i'),
                  child: SizedBox(
                    key: ValueKey<String>('card-$i'),
                    height: 60,
                    width: 200,
                    child: ColoredBox(color: Colors.blue.shade100),
                  ),
                ),
              // 尾部留白：长按落在这里不该起手扫选。
              const SizedBox(key: ValueKey<String>('blank'), height: 120),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> longPressDrag(
    WidgetTester tester, {
    required String from,
    String? to,
  }) async {
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey<String>(from))),
    );
    // 过长按判定时限，长按识别器才宣布胜出。
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    if (to != null) {
      await gesture.moveTo(
        tester.getCenter(find.byKey(ValueKey<String>(to))),
      );
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
  }

  testWidgets('长按起手后滑动，刷出起点到落点的整段', (WidgetTester tester) async {
    final MediaSelectionController controller = MediaSelectionController();
    controller.setVisibleOrder(
      loose: <String>['card-0', 'card-1', 'card-2', 'card-3', 'card-4'],
      collections: const <int>[],
    );
    await tester.pumpWidget(buildHarness(
      controller: controller,
      enabled: true,
      onChanged: () {},
    ));

    await longPressDrag(tester, from: 'card-0', to: 'card-2');

    expect(controller.looseKeys, <String>{'card-0', 'card-1', 'card-2'});
    expect(controller.isRangeDragging, isFalse);
  });

  testWidgets('反向扫选同样成段', (WidgetTester tester) async {
    final MediaSelectionController controller = MediaSelectionController();
    controller.setVisibleOrder(
      loose: <String>['card-0', 'card-1', 'card-2', 'card-3', 'card-4'],
      collections: const <int>[],
    );
    await tester.pumpWidget(buildHarness(
      controller: controller,
      enabled: true,
      onChanged: () {},
    ));

    await longPressDrag(tester, from: 'card-3', to: 'card-1');

    expect(controller.looseKeys, <String>{'card-1', 'card-2', 'card-3'});
  });

  testWidgets('长按落在空白处不起手，滑过卡片也不选中', (WidgetTester tester) async {
    final MediaSelectionController controller = MediaSelectionController();
    controller.setVisibleOrder(
      loose: <String>['card-0', 'card-1', 'card-2', 'card-3', 'card-4'],
      collections: const <int>[],
    );
    await tester.pumpWidget(buildHarness(
      controller: controller,
      enabled: true,
      onChanged: () {},
    ));

    await longPressDrag(tester, from: 'blank', to: 'card-2');

    expect(controller.looseKeys, isEmpty);
  });

  testWidgets('非多选态（enabled=false）不接管长按', (WidgetTester tester) async {
    final MediaSelectionController controller = MediaSelectionController();
    controller.setVisibleOrder(
      loose: <String>['card-0', 'card-1', 'card-2', 'card-3', 'card-4'],
      collections: const <int>[],
    );
    await tester.pumpWidget(buildHarness(
      controller: controller,
      enabled: false,
      onChanged: () {},
    ));

    expect(find.byType(GestureDetector), findsNothing);
    await longPressDrag(tester, from: 'card-0', to: 'card-2');
    expect(controller.looseKeys, isEmpty);
  });

  testWidgets('扫选期间每跨一张卡才回调一次（同卡内的高频移动被去重）',
      (WidgetTester tester) async {
    final MediaSelectionController controller = MediaSelectionController();
    controller.setVisibleOrder(
      loose: <String>['card-0', 'card-1', 'card-2', 'card-3', 'card-4'],
      collections: const <int>[],
    );
    int changes = 0;
    await tester.pumpWidget(buildHarness(
      controller: controller,
      enabled: true,
      onChanged: () => changes++,
    ));

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('card-0'))),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    // 在同一张卡内挪动三次：begin 之后不应再产生 update 回调。
    final Offset within = tester.getCenter(
      find.byKey(const ValueKey<String>('card-0')),
    );
    await gesture.moveTo(within + const Offset(0, 4));
    await tester.pump();
    await gesture.moveTo(within + const Offset(0, 8));
    await tester.pump();
    await gesture.moveTo(within + const Offset(0, 12));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    // begin + end 各一次，中间零次 update。
    expect(changes, 2);
    expect(controller.looseKeys, <String>{'card-0'});
  });

  group('修饰键判定', () {
    testWidgets('按住 Shift 时点击 = 区间扩选，否则普通切换',
        (WidgetTester tester) async {
      expect(selectionTapKind(), SelectionTapKind.toggle);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      expect(selectionTapKind(), SelectionTapKind.extend);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(selectionTapKind(), SelectionTapKind.toggle);
    });

    testWidgets('Windows/Linux 用 Ctrl 进多选，⌘ 不算',
        (WidgetTester tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Builder(builder: (BuildContext context) {
          ctx = context;
          return const SizedBox();
        }),
      ));

      expect(selectionEntryModifierPressed(ctx), isFalse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      expect(selectionEntryModifierPressed(ctx), isTrue);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      expect(selectionEntryModifierPressed(ctx), isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    });

    testWidgets('macOS 用 ⌘ 进多选，Ctrl 不算', (WidgetTester tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: Builder(builder: (BuildContext context) {
          ctx = context;
          return const SizedBox();
        }),
      ));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      expect(selectionEntryModifierPressed(ctx), isTrue);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      expect(selectionEntryModifierPressed(ctx), isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    });
  });

  group('平台分流', () {
    testWidgets('触屏平台长按归多选，桌面归菜单', (WidgetTester tester) async {
      Future<bool> touchOn(TargetPlatform platform) async {
        late BuildContext ctx;
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(platform: platform),
          home: Builder(builder: (BuildContext context) {
            ctx = context;
            return const SizedBox();
          }),
        ));
        // MaterialApp 的 AnimatedTheme 在主题间插值，而 `ThemeData.lerp` 的
        // platform 是 `t < 0.5 ? a : b` 的硬切——同一个 tester 里连续换主题时，
        // 首帧读到的仍是上一个平台。必须让动画跑完再读。
        await tester.pumpAndSettle();
        return isTouchSelectionPlatform(ctx);
      }

      expect(await touchOn(TargetPlatform.android), isTrue);
      expect(await touchOn(TargetPlatform.iOS), isTrue);
      expect(await touchOn(TargetPlatform.fuchsia), isTrue);
      expect(await touchOn(TargetPlatform.windows), isFalse);
      expect(await touchOn(TargetPlatform.macOS), isFalse);
      expect(await touchOn(TargetPlatform.linux), isFalse);
    });
  });
}

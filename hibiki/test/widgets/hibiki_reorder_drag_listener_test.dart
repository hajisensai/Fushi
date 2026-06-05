import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_reorder_drag_listener.dart';

/// 守卫 [HibikiReorderDragListener] 的「按平台选即时/延迟起拖」分支——
/// 修「Win 等桌面端鼠标必须长按 ~500ms 才能拖动重排」的回归防线。
void main() {
  Future<void> pumpUnder(WidgetTester tester, TargetPlatform platform) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: ReorderableListView(
            // 关掉 SDK 默认手柄，确保下面只剩 HibikiReorderDragListener 产生的监听器。
            buildDefaultDragHandles: false,
            onReorder: (int oldIndex, int newIndex) {},
            children: const <Widget>[
              HibikiReorderDragListener(
                key: ValueKey<String>('row0'),
                index: 0,
                child: SizedBox(height: 40, child: Text('row0')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  ]) {
    testWidgets('desktop ($platform): immediate ReorderableDragStartListener',
        (WidgetTester tester) async {
      await pumpUnder(tester, platform);
      // 桌面端用即时识别器（按下即拖），不用延迟（长按）识别器。
      // find.byType 精确匹配 runtimeType，Delayed 子类不会误命中父类。
      expect(find.byType(ReorderableDragStartListener), findsOneWidget);
      expect(find.byType(ReorderableDelayedDragStartListener), findsNothing);
    });
  }

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.fuchsia,
  ]) {
    testWidgets(
        'touch ($platform): delayed ReorderableDelayedDragStartListener',
        (WidgetTester tester) async {
      await pumpUnder(tester, platform);
      // 移动/触摸端保留长按起拖。
      expect(find.byType(ReorderableDelayedDragStartListener), findsOneWidget);
    });
  }
}

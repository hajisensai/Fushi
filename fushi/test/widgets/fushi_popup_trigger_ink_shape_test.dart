import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/library_filter_dropdown.dart';
import 'package:fushi/utils.dart';

// 2026-10-05 用户反馈：书架「阅读状态」筛选 chip 悬停 / 点击时的灰色反馈范围
// 与高亮胶囊对不上。根因在共享触发器 [FushiPopupMenuButton] 的 MD3 路径：框架
// PopupMenuButton 把 InkWell 包在 child 外，状态层是 child 的外接矩形、且画在
// child 之下（实底胶囊盖住中间，只在四角露出灰）。修复后状态层按触发器声明的
// 形状裁剪、叠在触发器之上。
void main() {
  Future<void> pumpTrigger(WidgetTester tester, {required bool active}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: LibraryFilterDropdown<int>(
              value: active ? 1 : null,
              options: const <int>[1, 2],
              labelOf: (int v) => 'Option $v',
              title: 'Status',
              allLabel: 'All',
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final Finder ink = find.byKey(
    const ValueKey<String>('fushi-popup-trigger-ink'),
  );

  for (final bool active in <bool>[false, true]) {
    testWidgets('筛选 chip（active=$active）：状态层与胶囊同尺寸同形状、叠在其上', (
      WidgetTester tester,
    ) async {
      await pumpTrigger(tester, active: active);
      expect(tester.takeException(), isNull);
      expect(ink, findsOneWidget);

      final Finder chip = find.byType(LibraryFilterChip);
      expect(tester.getRect(ink), tester.getRect(chip));

      final InkWell inkWell = tester.widget<InkWell>(ink);
      expect(inkWell.customBorder, isA<StadiumBorder>());
      final Material clip = tester.widget<Material>(
        find.ancestor(of: ink, matching: find.byType(Material)).first,
      );
      expect(clip.shape, isA<StadiumBorder>());
      expect(clip.clipBehavior, isNot(Clip.none));
      expect(clip.type, MaterialType.transparency);

      // 状态层在触发器之上（Stack 里排在 chip 之后），不会被实底胶囊盖住。
      final Stack stack = tester.widget<Stack>(
        find.ancestor(of: chip, matching: find.byType(Stack)).first,
      );
      expect(stack.children.first, isA<LibraryFilterChip>());

      // 悬停不抛错，点击照常打开菜单。
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(chip));
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.text('All'), findsWidgets);
    });
  }

  testWidgets('FushiMenuLabelTrigger 声明全圆角形状', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: FushiPopupMenuButton<int>.labeled(
              label: 'Transfer',
              itemBuilder: (_) => const <PopupMenuEntry<int>>[
                PopupMenuItem<int>(value: 1, child: Text('One')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(ink, findsOneWidget);
    expect(tester.widget<InkWell>(ink).customBorder, isA<StadiumBorder>());
    expect(
      tester.getSize(ink),
      tester.getSize(find.byType(FushiMenuLabelTrigger)),
    );
  });

  // 同一 primitive 层的其它触发器：chip / 描边按钮作菜单 child 时，状态层与
  // 它们的可视胶囊同框同形（布局边界去掉 48dp 点击区外边距）。
  Future<void> pumpChild(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          chipTheme: const ChipThemeData(shape: StadiumBorder()),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(shape: const StadiumBorder()),
          ),
        ),
        home: Scaffold(
          body: Center(
            child: FushiOverflowMenu<int>(
              tooltip: 'Sort',
              onSelected: (_) {},
              items: const <PopupMenuEntry<int>>[
                PopupMenuItem<int>(value: 1, child: Text('One')),
              ],
              child: child,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('FushiChip 触发器：状态层与 chip 同框同形', (WidgetTester tester) async {
    await pumpChild(
      tester,
      const FushiChip(
        label: Text('Sort: name'),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
    expect(ink, findsOneWidget);
    expect(tester.widget<InkWell>(ink).customBorder, isA<StadiumBorder>());
    expect(tester.getRect(ink), tester.getRect(find.byType(Chip)));
  });

  testWidgets('FushiOutlinedButton 触发器：状态层与按钮同框同形', (
    WidgetTester tester,
  ) async {
    await pumpChild(
      tester,
      FushiOutlinedButton.icon(
        onPressed: null,
        style: kFushiMenuTriggerButtonStyle,
        icon: const Icon(Icons.sort, size: 18),
        label: const Text('Sort: name'),
      ),
    );
    expect(ink, findsOneWidget);
    expect(tester.widget<InkWell>(ink).customBorder, isA<StadiumBorder>());
    expect(tester.getRect(ink), tester.getRect(find.byType(OutlinedButton)));
  });
}

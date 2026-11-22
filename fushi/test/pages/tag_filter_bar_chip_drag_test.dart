import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tags/tag_chip_draggable.dart';
import 'package:fushi/src/pages/implementations/tag_filter_bar.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-5066（承 BUG-4899）接入层：库页标签条（[FushiTagFilterBar]，书架 / 视频 /
/// 游戏共用）的标签 chip 左侧不再有「⋮⋮」拖动柄；chip 本身按指针类型起拖——
/// 鼠标按住即拖、单击照常筛选，触屏长按拖。
Widget _host(Widget child) => ProviderScope(
  child: TranslationProvider(
    child: MaterialApp(home: Scaffold(body: child)),
  ),
);

List<BookTagRow> _tags() => <BookTagRow>[
  for (int i = 0; i < 3; i++)
    BookTagRow(
      id: i,
      name: '标签$i',
      colorValue: 0xFF2196F3,
      sortOrder: i,
      createdAt: 0,
    ),
];

FushiTagFilterBar _bar({
  bool selectionMode = false,
  void Function(int id)? onToggleFilter,
  List<(int, int)>? reorders,
}) => FushiTagFilterBar(
  tags: _tags(),
  part: FushiTagFilterBarPart.tags,
  selectionMode: selectionMode,
  onToggleFilter: onToggleFilter ?? (_) {},
  onReorder: (int oldIndex, int newIndex) async {
    reorders?.add((oldIndex, newIndex));
  },
);

void main() {
  setUpAll(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('标签左侧没有拖动柄：可拖的就是 chip 本身；多选模式下不可拖', (WidgetTester tester) async {
    await tester.pumpWidget(_host(_bar()));
    await tester.pumpAndSettle();
    expect(find.byType(FushiTagChipDraggable<BookTagRow>), findsNWidgets(3));
    for (int i = 0; i < 3; i++) {
      final Finder draggable = find.byKey(
        ValueKey<String>('library_tag_draggable_$i'),
      );
      expect(
        find.descendant(of: draggable, matching: find.text('标签$i')),
        findsOneWidget,
      );
      // 可拖区域与 chip 左缘对齐：chip 前面没有多出来的柄。
      expect(
        tester.getTopLeft(draggable).dx,
        tester
            .getTopLeft(
              find
                  .ancestor(
                    of: find.text('标签$i'),
                    matching: find.byType(DragTarget<BookTagRow>),
                  )
                  .first,
            )
            .dx,
      );
    }

    await tester.pumpWidget(_host(_bar(selectionMode: true)));
    await tester.pumpAndSettle();
    expect(find.byType(FushiTagChipDraggable<BookTagRow>), findsNothing);
  });

  testWidgets('鼠标在 chip 上按住即拖，放到另一枚标签上触发重排', (WidgetTester tester) async {
    final List<(int, int)> reorders = <(int, int)>[];
    final List<int> toggled = <int>[];
    await tester.pumpWidget(
      _host(_bar(reorders: reorders, onToggleFilter: toggled.add)),
    );
    await tester.pumpAndSettle();

    final TestGesture mouse = await tester.startGesture(
      tester.getCenter(find.text('标签0')),
      kind: PointerDeviceKind.mouse,
    );
    // 鼠标精确指针：1 px 之外即开始拖，不等长按计时。
    await mouse.moveBy(const Offset(4, 0));
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.text('标签2')));
    await tester.pump();
    await mouse.up();
    await tester.pumpAndSettle();

    expect(reorders, <(int, int)>[(0, 2)]);
    expect(toggled, isEmpty);
  });

  testWidgets('鼠标单击 chip 照常切换筛选，不触发重排', (WidgetTester tester) async {
    final List<(int, int)> reorders = <(int, int)>[];
    final List<int> toggled = <int>[];
    await tester.pumpWidget(
      _host(_bar(reorders: reorders, onToggleFilter: toggled.add)),
    );
    await tester.pumpAndSettle();

    await tester.tapAt(
      tester.getCenter(find.text('标签1')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(toggled, <int>[1]);
    expect(reorders, isEmpty);
  });

  testWidgets('触屏长按 chip 后拖到另一枚标签上触发重排', (WidgetTester tester) async {
    final List<(int, int)> reorders = <(int, int)>[];
    await tester.pumpWidget(_host(_bar(reorders: reorders)));
    await tester.pumpAndSettle();

    final TestGesture touch = await tester.startGesture(
      tester.getCenter(find.text('标签2')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await touch.moveTo(tester.getCenter(find.text('标签0')));
    await tester.pump();
    await touch.up();
    await tester.pumpAndSettle();

    expect(reorders, <(int, int)>[(2, 0)]);
  });
}

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tags/tag_drag_handle.dart';
import 'package:fushi/src/pages/implementations/tag_filter_bar.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-4899 接入层：库页标签条（[FushiTagFilterBar]，书架 / 视频 / 游戏共用）每枚
/// 标签左侧都有「⋮⋮」拖动柄；鼠标在柄上按下即拖，放到另一枚标签上触发
/// `onReorder`，标签条不被横滚抢走。
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

void main() {
  setUpAll(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('每枚标签都有拖动柄；多选模式下不显示', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        FushiTagFilterBar(
          tags: _tags(),
          part: FushiTagFilterBarPart.tags,
          onToggleFilter: (_) {},
          onReorder: (_, __) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FushiTagDragHandle<BookTagRow>), findsNWidgets(3));

    await tester.pumpWidget(
      _host(
        FushiTagFilterBar(
          tags: _tags(),
          part: FushiTagFilterBarPart.tags,
          selectionMode: true,
          onToggleFilter: (_) {},
          onReorder: (_, __) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FushiTagDragHandle<BookTagRow>), findsNothing);
  });

  testWidgets('鼠标在柄上按下即拖，放到另一枚标签上触发重排', (WidgetTester tester) async {
    final List<(int, int)> reorders = <(int, int)>[];
    await tester.pumpWidget(
      _host(
        FushiTagFilterBar(
          tags: _tags(),
          part: FushiTagFilterBarPart.tags,
          onToggleFilter: (_) {},
          onReorder: (int oldIndex, int newIndex) async {
            reorders.add((oldIndex, newIndex));
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Offset start = tester.getCenter(
      find.byKey(const ValueKey<String>('library_tag_drag_handle_0')),
    );
    final Offset target = tester.getCenter(find.text('标签2'));
    final TestGesture mouse = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    // 鼠标精确指针：1 px 之外即开始拖，不等长按计时。
    await mouse.moveBy(const Offset(4, 0));
    await tester.pump();
    await mouse.moveTo(target);
    await tester.pump();
    await mouse.up();
    await tester.pumpAndSettle();

    expect(reorders, <(int, int)>[(0, 2)]);
  });
}

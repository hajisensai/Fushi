import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/shelf_reorder_page.dart';

/// TODO-947 P3 带框成员视图守卫：
///  - seriesFrame 非空时渲染系列名 + 边框。
///  - 拖成员出框（浮层中心出网格边界）→ onRemove(该成员)。
///  - onRemove 返回 seriesEmptied=true → 页面 pop 回上层（系列清空）。
///  - onRemove 返回 seriesEmptied=false → 成员从网格摘除，页面保留。
Future<void> _dragOut(WidgetTester tester, Key card, Offset target) async {
  final Offset start = tester.getCenter(find.byKey(card));
  final TestGesture g =
      await tester.startGesture(start, kind: PointerDeviceKind.mouse);
  await tester.pump();
  await g.moveTo(Offset.lerp(start, target, 0.5)!);
  await tester.pump();
  await g.moveTo(target);
  await tester.pump();
  await g.up();
  await tester.pumpAndSettle();
}

ShelfReorderItem _member(String key) => ShelfReorderItem(
      mediaType: 'epub',
      entryKey: key,
      card: SizedBox(
        key: ValueKey<String>('card_$key'),
        child: Center(child: Text(key)),
      ),
    );

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget host(Widget page) => TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.push<void>(
                    ctx,
                    MaterialPageRoute<void>(builder: (_) => page),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('seriesFrame 渲染系列名 + 拖成员出框调用 onRemove（未清空则摘除成员保留页）',
      (WidgetTester tester) async {
    final List<String> removedKeys = <String>[];
    await tester.pumpWidget(host(ShelfReorderPage(
      title: 'MySeries',
      initialItems: <ShelfReorderItem>[_member('A'), _member('B')],
      cellExtent: 180,
      childAspectRatio: 160 / 260,
      onPersist: (_) async {},
      seriesFrame: const ShelfReorderSeriesFrame(seriesName: 'MySeries'),
      onRemove: (ShelfReorderItem item) async {
        removedKeys.add(item.entryKey);
        return const ShelfRemoveResult(removed: true, seriesEmptied: false);
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 框：系列名可见（header）。
    expect(find.text('MySeries'), findsWidgets, reason: 'seriesFrame 渲染系列名');
    expect(find.byKey(const ValueKey<String>('card_A')), findsOneWidget);

    // 把 A 拖到框上方（header 之上、网格边界之外）→ 移出候选 → onRemove(A)。
    await _dragOut(
        tester, const ValueKey<String>('card_A'), const Offset(200, 8));
    expect(removedKeys, <String>['A'], reason: '拖出框移出 A');
    // 未清空：A 从网格摘除，B 保留，页面仍在（系列名可见）。
    expect(find.byKey(const ValueKey<String>('card_A')), findsNothing,
        reason: '移出后 A 从网格摘除');
    expect(find.byKey(const ValueKey<String>('card_B')), findsOneWidget);
    expect(find.text('MySeries'), findsWidgets, reason: '未清空系列，页面保留');
  });

  testWidgets('拖出框移出最后一个成员：onRemove 返回 seriesEmptied → 页面 pop 回上层',
      (WidgetTester tester) async {
    await tester.pumpWidget(host(ShelfReorderPage(
      title: 'Solo',
      initialItems: <ShelfReorderItem>[_member('A')],
      cellExtent: 180,
      childAspectRatio: 160 / 260,
      onPersist: (_) async {},
      seriesFrame: const ShelfReorderSeriesFrame(seriesName: 'Solo'),
      onRemove: (ShelfReorderItem item) async =>
          const ShelfRemoveResult(removed: true, seriesEmptied: true),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Solo'), findsWidgets);

    await _dragOut(
        tester, const ValueKey<String>('card_A'), const Offset(200, 8));
    // 系列清空 → 页面 pop：回到 host（'open' 按钮再次可见，框标题消失）。
    expect(find.text('open'), findsOneWidget, reason: '系列清空后页面 pop 回上层');
    expect(find.text('Solo'), findsNothing, reason: '带框成员页已退出');
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/series_shelf_card.dart';
import 'package:hibiki/src/pages/implementations/shelf_reorder_page.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';

/// 原 TODO-947 P3「成员子页框」守卫（seriesFrame 参数 + 拖成员出框移出 + 清空 pop）。
/// UI v2 Phase E 统一合集模型重做后该模式已整体删除：[ShelfReorderPage] 不再有
/// seriesFrame / onEnterSeries 参数，也没有「拖出框」手势——移出的唯一入口是每格
/// 右下角的 overlay 按钮（仅 groupId != null 的成员格挂）。本文件改写为对新等价
/// 行为的守护：
///  - overlay 移出按钮把正确的成员条目传给 onRemove（tooltip = 「移出合集」文案）；
///  - onRemove 确认（removed=true）→ 成员就地降级散卡（不消失、脱框、页面不 pop）；
///  - onRemove 取消（removed=false）→ 条目原样保留（框 / 按钮不变）；
///  - 最后一个成员移出（groupEmptied=true，空合集由 DB 层自动删）→ 页面不 pop，
///    条目以散卡留在整理列表（旧「子页框清空即退出」语义随子页框一并消亡）。
ShelfReorderItem _member(String key, {required bool header}) =>
    ShelfReorderItem(
      mediaType: 'epub',
      entryKey: key,
      groupId: 7,
      card: SizedBox(
        key: ValueKey<String>('card_$key'),
        child: Center(child: Text(key)),
      ),
      groupFrame: GroupFrameData(
        color: const Color(0xFF4F8DFD),
        showHeader: header,
        groupName: 'MyCollection',
        memberCount: 2,
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

  testWidgets('overlay 移出按钮：onRemove 确认后成员就地降级散卡（不消失、脱框、页面不 pop）',
      (WidgetTester tester) async {
    final List<String> removedKeys = <String>[];
    await tester.pumpWidget(host(ShelfReorderPage(
      title: 'Edit order',
      initialItems: <ShelfReorderItem>[
        _member('A', header: true),
        _member('B', header: false),
      ],
      cellExtent: 180,
      childAspectRatio: 160 / 260,
      onPersist: (_) async {},
      onRemove: (ShelfReorderItem item) async {
        removedKeys.add(item.entryKey);
        return const ShelfRemoveResult(removed: true, groupEmptied: false);
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 分组框 + 合集名 header（仅首成员）+ 每个成员格一个移出按钮。
    expect(find.byType(SeriesReorderFrame), findsNWidgets(2),
        reason: '合集成员逐本套同色分组框');
    expect(find.text('MyCollection'), findsOneWidget, reason: '首成员叠合集名 header');
    expect(find.byIcon(Icons.remove_circle_outline), findsNWidgets(2),
        reason: '每个成员格挂移出按钮');

    // 按钮 tooltip 用合集文案（en: Remove from collection）。
    final HibikiIconButton removeBtn = tester.widget<HibikiIconButton>(find
        .widgetWithIcon(HibikiIconButton, Icons.remove_circle_outline)
        .first);
    expect(removeBtn.tooltip, t.collection_remove_member,
        reason: '移出按钮 tooltip 用「移出合集」文案');

    // 点 A 格的移出按钮 → onRemove(A)。
    await tester.tap(find.byIcon(Icons.remove_circle_outline).first);
    await tester.pumpAndSettle();
    expect(removedKeys, <String>['A'], reason: 'overlay 按钮移出 A');

    // A 就地降级散卡：卡还在、脱框、不再挂按钮；B 不受影响；页面不 pop。
    expect(find.byKey(const ValueKey<String>('card_A')), findsOneWidget,
        reason: '移出后 A 不消失，就地变回无框散卡');
    expect(find.byType(SeriesReorderFrame), findsOneWidget,
        reason: 'A 脱框，B 仍套框');
    expect(find.byIcon(Icons.remove_circle_outline), findsOneWidget,
        reason: '散卡不再挂移出按钮');
    expect(find.byKey(const ValueKey<String>('card_B')), findsOneWidget);
    expect(find.byType(ShelfReorderPage), findsOneWidget, reason: '页面保留');
  });

  testWidgets('onRemove 取消（removed=false）→ 条目原样保留（框 / 按钮不变）',
      (WidgetTester tester) async {
    final List<String> asked = <String>[];
    await tester.pumpWidget(host(ShelfReorderPage(
      title: 'Edit order',
      initialItems: <ShelfReorderItem>[_member('A', header: true)],
      cellExtent: 180,
      childAspectRatio: 160 / 260,
      onPersist: (_) async {},
      onRemove: (ShelfReorderItem item) async {
        asked.add(item.entryKey);
        return const ShelfRemoveResult(removed: false, groupEmptied: false);
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.remove_circle_outline));
    await tester.pumpAndSettle();
    expect(asked, <String>['A'], reason: 'onRemove 被调用（由调用方弹确认框）');
    // 取消：条目原样保留——仍套框、仍挂按钮。
    expect(find.byType(SeriesReorderFrame), findsOneWidget,
        reason: '取消移出后分组框不变');
    expect(find.byIcon(Icons.remove_circle_outline), findsOneWidget,
        reason: '取消移出后按钮不变');
    expect(find.byKey(const ValueKey<String>('card_A')), findsOneWidget);
  });

  testWidgets('移出最后一个成员（groupEmptied=true）→ 页面不 pop，条目以散卡留在列表',
      (WidgetTester tester) async {
    await tester.pumpWidget(host(ShelfReorderPage(
      title: 'Edit order',
      initialItems: <ShelfReorderItem>[_member('A', header: true)],
      cellExtent: 180,
      childAspectRatio: 160 / 260,
      onPersist: (_) async {},
      onRemove: (ShelfReorderItem item) async =>
          const ShelfRemoveResult(removed: true, groupEmptied: true),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.remove_circle_outline));
    await tester.pumpAndSettle();

    // 合集清空（DB 层已自动删空合集）；新模型无成员子页，整理页留在原地继续整理。
    expect(find.byType(ShelfReorderPage), findsOneWidget,
        reason: '清空合集不再 pop 整理页（子页框模式已删）');
    expect(find.text('open'), findsNothing, reason: '未回到上层页面');
    expect(find.byKey(const ValueKey<String>('card_A')), findsOneWidget,
        reason: '最后一个成员移出后以散卡留在列表');
    expect(find.byType(SeriesReorderFrame), findsNothing, reason: '脱框');
    expect(find.byIcon(Icons.remove_circle_outline), findsNothing,
        reason: '散卡无移出按钮');
  });
}

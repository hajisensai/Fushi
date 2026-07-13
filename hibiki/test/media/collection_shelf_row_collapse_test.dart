import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/collections/collection_shelf_row.dart';

/// 合集横排行折叠（用户：「合集加个折叠」）：
///  - collapsed=false：行头 + 横向成员列表都在；
///  - collapsed=true：只剩行头（成员列表整个不建，不是隐藏），行头照常可点详情；
///  - 行头旋转 chevron 触发 onToggleCollapsed（持久化由调用方负责，见页面级
///    `home_video_collapse_test.dart`）；未传回调则不渲染开关（行恒展开）。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Widget wrap(Widget child) => TranslationProvider(
        child: MaterialApp(
          home: Scaffold(body: Column(children: <Widget>[child])),
        ),
      );

  Widget row({
    required bool collapsed,
    VoidCallback? onToggleCollapsed,
    VoidCallback? onOpenDetail,
  }) =>
      CollectionShelfRow(
        title: '某系列',
        countLabel: '3 项',
        itemCount: 3,
        itemWidth: 100,
        rowHeight: 160,
        collapsed: collapsed,
        onToggleCollapsed: onToggleCollapsed,
        onOpenDetail: onOpenDetail ?? () {},
        itemBuilder: (BuildContext _, int i) =>
            Text('成员$i', key: ValueKey<String>('member_$i')),
      );

  testWidgets('展开态：行头与成员卡都渲染', (WidgetTester tester) async {
    await tester
        .pumpWidget(wrap(row(collapsed: false, onToggleCollapsed: () {})));
    expect(find.text('某系列'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('member_0')), findsOneWidget);
  });

  testWidgets('折叠态：成员列表整个不建，行只剩行头（行头点击仍进详情）', (WidgetTester tester) async {
    int detailOpens = 0;
    await tester.pumpWidget(wrap(row(
      collapsed: true,
      onToggleCollapsed: () {},
      onOpenDetail: () => detailOpens++,
    )));
    expect(find.text('某系列'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('member_0')), findsNothing,
        reason: '折叠 = 不建成员列表（省一整行高度），不是 Offstage 隐藏');
    expect(find.byType(ListView), findsNothing);

    await tester.tap(find.text('某系列'));
    await tester.pump();
    expect(detailOpens, 1, reason: '折叠态行头照常可点进详情');
  });

  testWidgets('行头 chevron 触发 onToggleCollapsed；tooltip 随态切换',
      (WidgetTester tester) async {
    int toggles = 0;
    await tester.pumpWidget(wrap(row(
      collapsed: false,
      onToggleCollapsed: () => toggles++,
    )));
    expect(find.byTooltip(t.collection_collapse), findsOneWidget);
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pump();
    expect(toggles, 1);

    await tester.pumpWidget(wrap(row(
      collapsed: true,
      onToggleCollapsed: () => toggles++,
    )));
    await tester.pumpAndSettle();
    expect(find.byTooltip(t.collection_expand), findsOneWidget,
        reason: '折叠态 tooltip 变「展开」');
  });

  testWidgets('未传 onToggleCollapsed：不渲染折叠开关（行恒展开）',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(row(collapsed: false)));
    expect(find.byIcon(Icons.expand_more), findsNothing);
  });
}

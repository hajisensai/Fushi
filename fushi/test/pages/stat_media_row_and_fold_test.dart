import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';

/// 三个域统计页收敛到游戏页骨架（用户 2026-09-08「统计全改成游戏那种」）后的两个
/// 共享件：
///  * [buildStatMediaRow]：标题 / meta / meta2 / 右侧主值都上屏；有 onTap 才画 chevron；
///    长按走 onDelete、点按走 onTap；
///  * [StatAnalysisFold]：默认收起（子区块不上屏），点标题展开、再点收起。
Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('media row：标题 / meta / meta2 / 主值上屏，点按与长按各走各的回调', (
    WidgetTester tester,
  ) async {
    int taps = 0;
    int deletes = 0;
    await _pump(
      tester,
      Builder(
        builder: (BuildContext context) => buildStatMediaRow(
          context,
          icon: Icons.menu_book,
          title: 'TITLE',
          collectionName: 'COLL',
          meta: 'META1',
          meta2: 'META2',
          trailing: '1h 2m',
          onTap: () => taps++,
          onDelete: () => deletes++,
        ),
      ),
    );
    for (final String s in <String>['TITLE', 'COLL', 'META1', 'META2', '1h 2m']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    await tester.tap(find.text('TITLE'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(deletes, 0);
    await tester.longPress(find.text('TITLE'));
    await tester.pumpAndSettle();
    expect(deletes, 1);
    expect(taps, 1);
  });

  testWidgets('media row：无 onTap 不画 chevron；无 meta2 不多画一行', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      Builder(
        builder: (BuildContext context) => buildStatMediaRow(
          context,
          icon: Icons.movie,
          title: 'T',
          meta: 'M',
          trailing: '5 min',
        ),
      ),
    );
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byType(Text), findsNWidgets(3));
  });

  testWidgets('analysis fold：默认收起，点标题展开，再点收起', (WidgetTester tester) async {
    await _pump(
      tester,
      const StatAnalysisFold(children: <Widget>[Text('INSIDE')]),
    );
    expect(find.text(t.stat_analysis), findsOneWidget);
    expect(find.text('INSIDE'), findsNothing, reason: '默认收起');
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    await tester.tap(find.text(t.stat_analysis));
    await tester.pumpAndSettle();
    expect(find.text('INSIDE'), findsOneWidget);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);
    await tester.tap(find.text(t.stat_analysis));
    await tester.pumpAndSettle();
    expect(find.text('INSIDE'), findsNothing);
  });
}

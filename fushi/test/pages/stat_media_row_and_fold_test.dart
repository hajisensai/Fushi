import 'dart:typed_data';

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

  testWidgets('media row：有封面画封面、没封面画域图标，两者占同一个 2:3 槽', (
    WidgetTester tester,
  ) async {
    // 1×1 透明 PNG。
    final MemoryImage cover = MemoryImage(
      Uint8List.fromList(<int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
        0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
      ]),
    );
    await _pump(
      tester,
      Builder(
        builder: (BuildContext context) => Column(
          children: <Widget>[
            buildStatMediaRow(
              context,
              icon: Icons.menu_book,
              cover: cover,
              title: 'WITH',
              meta: 'M',
              trailing: '1 min',
            ),
            buildStatMediaRow(
              context,
              icon: Icons.movie,
              title: 'WITHOUT',
              meta: 'M',
              trailing: '1 min',
            ),
          ],
        ),
      ),
    );
    final Finder image = find.byWidgetPredicate(
      (Widget w) => w is Image && w.image == cover,
    );
    expect(image, findsOneWidget);
    expect(find.byIcon(Icons.movie), findsOneWidget);
    expect(find.byIcon(Icons.menu_book), findsNothing, reason: '有封面不再画占位图标');
    final Size slot = tester.getSize(image);
    expect(slot, const Size(kStatMediaCoverWidth, kStatMediaCoverWidth * 1.4));
    // 两行标题左缘对齐（封面槽定宽）。
    expect(
      tester.getTopLeft(find.text('WITH')).dx,
      tester.getTopLeft(find.text('WITHOUT')).dx,
    );
  });

  testWidgets('analysis fold：默认收起，点标题展开，再点收起', (WidgetTester tester) async {
    await _pump(
      tester,
      const StatAnalysisFold(children: <Widget>[Text('INSIDE')]),
    );
    expect(find.text(t.stat_analysis), findsOneWidget);
    expect(find.text('INSIDE'), findsNothing, reason: '默认收起');
    // 2026-10 重设计：chevron 恒为 expand_more，展开时经 AnimatedRotation 转半圈。
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    double turns() => tester
        .widget<AnimatedRotation>(find.byType(AnimatedRotation))
        .turns;
    expect(turns(), 0);
    await tester.tap(find.text(t.stat_analysis));
    await tester.pumpAndSettle();
    expect(find.text('INSIDE'), findsOneWidget);
    expect(turns(), 0.5);
    await tester.tap(find.text(t.stat_analysis));
    await tester.pumpAndSettle();
    expect(find.text('INSIDE'), findsNothing);
  });
}

// 设置页的边界语言守卫：**容器**（分组卡、搜索框）用填充分层，一条线都不画；
// **控件轮廓**（分段条、输入框）保持 MD3 规范的 `colorScheme.outline`；**分隔线**
// 用 `outlineVariant`。线因此各有明确职责，不再是同一层级上三种强度混排。
//
// 改前：分组卡在 surfaceContainer 填充之上又描一圈 outlineVariant（填充卡不该描
// 边），于是卡里的分段条那圈 outline 成了「框中框」；搜索框是全屏唯一的深色描边
// 方框；左栏选中项还在 secondaryContainer 填充上再叠一圈 primary 20% 的细边。
//
// eink 是唯一例外，且必须守住：eink scheme 把所有 surface container 塌缩成背景色，
// 填充分不出层，描边是那里唯一的边界信号。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

Widget _app({required bool eink, required Widget child}) {
  return MaterialApp(
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4CAF50)),
      extensions: <ThemeExtension<dynamic>>[FushiEinkTheme(eink)],
    ),
    home: Scaffold(body: child),
  );
}

BorderSide _cardSide(WidgetTester tester) {
  final AnimatedContainer container = tester.widget<AnimatedContainer>(
    find
        .descendant(
          of: find.byType(FushiCard),
          matching: find.byType(AnimatedContainer),
        )
        .first,
  );
  final ShapeDecoration decoration = container.decoration! as ShapeDecoration;
  return (decoration.shape as RoundedRectangleBorder).side;
}

Widget _section() {
  return AdaptiveSettingsSection(
    title: '界面',
    children: <Widget>[
      AdaptiveSettingsSwitchRow(
        title: '墨水屏模式',
        value: false,
        onChanged: (_) {},
      ),
    ],
  );
}

Border _pillBorder(WidgetTester tester) {
  final AnimatedContainer container = tester.widget<AnimatedContainer>(
    find
        .descendant(
          of: find.byType(FushiListItem),
          matching: find.byType(AnimatedContainer),
        )
        .first,
  );
  return (container.decoration! as BoxDecoration).border! as Border;
}

void main() {
  group('分组卡', () {
    testWidgets('非 eink：填充卡不叠描边', (WidgetTester tester) async {
      await tester.pumpWidget(_app(eink: false, child: _section()));
      expect(
        _cardSide(tester),
        BorderSide.none,
        reason: '分组卡有 surfaceContainer 填充，再描一圈是第二种边界信号',
      );
    });

    testWidgets('eink：仍自动补 1px 描边（填充塌缩，线是唯一边界）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_app(eink: true, child: _section()));
      final BorderSide side = _cardSide(tester);
      expect(side.style, BorderStyle.solid);
      expect(side.width, 1);
    });
  });

  group('分段条', () {
    test('分段条不覆盖 side：控件轮廓保持 MD3 规范的 colorScheme.outline', () {
      final String shared = File(
        'lib/src/utils/components/settings_shared.dart',
      ).readAsStringSync();
      // 分组卡不描边之后，分段条那圈就不再是「框中框」里的内框，而是屏上唯一的
      // 控件轮廓，按 MD3 规范留在 outline 那一档；把它跟着降到 outlineVariant 会
      // 让控件在填充卡上读不出边界（2026-09-10 像素对照）。
      expect(
        shared,
        contains('const kSettingsSegmentedStyle = ButtonStyle('),
        reason: '设置页分段条样式只调密度，不动 side/shape',
      );
      expect(
        shared,
        isNot(contains('side: WidgetStatePropertyAll')),
        reason: '一旦覆盖 side，分段条与其余输入框的轮廓就不再是同一档',
      );
    });
  });

  group('左栏选中 pill', () {
    testWidgets('非 eink：选中边透明，填充是唯一选中信号', (WidgetTester tester) async {
      await tester.pumpWidget(
        _app(
          eink: false,
          child: FushiListItem(
            title: const Text('外观与交互'),
            selected: true,
            selectedShape: FushiListItemSelectedShape.pill,
            onTap: () {},
          ),
        ),
      );
      expect(
        _pillBorder(tester).top.color,
        Colors.transparent,
        reason: 'secondaryContainer 填充已说明选中；边只保留 1px 几何占位',
      );
    });

    testWidgets('eink：选中边换成实描边色', (WidgetTester tester) async {
      await tester.pumpWidget(
        _app(
          eink: true,
          child: FushiListItem(
            title: const Text('外观与交互'),
            selected: true,
            selectedShape: FushiListItemSelectedShape.pill,
            onTap: () {},
          ),
        ),
      );
      expect(_pillBorder(tester).top.color, isNot(Colors.transparent));
    });
  });

  group('搜索框', () {
    test('设置主页搜索框用填充而不是描边', () {
      final String home = File(
        'lib/src/settings/settings_home_page.dart',
      ).readAsStringSync();
      expect(
        home,
        contains('filled: !eink'),
        reason: '搜索框与分组卡走同一套语言：填充分层，不描边',
      );
      expect(
        home,
        contains('borderSide: BorderSide.none'),
        reason: '只覆盖 border 会被全局 inputDecorationTheme 的 enabledBorder 顶掉',
      );
      expect(home, contains('enabledBorder: eink ? null : flatBorder'));
    });
  });
}

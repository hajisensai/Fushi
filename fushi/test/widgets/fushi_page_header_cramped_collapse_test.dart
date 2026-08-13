import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/utils.dart';

/// 2026-08-13 手机顶栏显示不全：页头（customTitle 分段导航形态）在「分段条自然宽
/// + 动作自然宽 > 行宽」时把可收纳动作折进 ⋯ 菜单，把宽度还给分段条；摆得下时
/// 一个都不收（用户定案：仅在左边位置不够时才变）。
void main() {
  Widget host({
    required double width,
    required List<Widget> actions,
    int segmentCount = 6,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: FushiPageHeader.customTitle(
              title: FushiSegmentedStrip<int>(
                segments: <ButtonSegment<int>>[
                  for (int i = 0; i < segmentCount; i++)
                    ButtonSegment<int>(value: i, label: Text('分段$i')),
                ],
                selected: 0,
                onChanged: (_) {},
              ),
              actions: actions,
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> buildActions(List<String> tapped) => <Widget>[
        for (int i = 0; i < 4; i++)
          FushiIconButton(
            icon: Icons.star_border,
            tooltip: 'action-$i',
            onTap: () => tapped.add('action-$i'),
          ),
      ];

  testWidgets('窄行放不下：动作收进 ⋯ 菜单，菜单项可触发原动作', (WidgetTester tester) async {
    final List<String> tapped = <String>[];
    await tester.pumpWidget(host(width: 360, actions: buildActions(tapped)));
    // 分段条 build 期上报自然宽 → 页头 post-frame setState 收纳，需再泵一帧。
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.more_vert), findsOneWidget,
        reason: '360dp 行宽放不下 6 段 + 4 动作，必须出现 ⋯ 溢出按钮');
    expect(find.byIcon(Icons.star_border), findsNothing,
        reason: '被收纳的动作不应再以图标形态占页头宽度');

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('action-2'), findsOneWidget,
        reason: '菜单项以动作的 tooltip 文案呈现');
    await tester.tap(find.text('action-2'));
    await tester.pumpAndSettle();
    expect(tapped, <String>['action-2'], reason: '菜单项必须触发原动作的 onTap');
  });

  testWidgets('行宽足够：一个动作都不收，无 ⋯ 按钮', (WidgetTester tester) async {
    final List<String> tapped = <String>[];
    await tester.pumpWidget(host(width: 760, actions: buildActions(tapped)));
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.more_vert), findsNothing,
        reason: '放得下时不收纳（仅在左边位置不够时才变）');
    expect(find.byIcon(Icons.star_border), findsNWidgets(4));
  });

  testWidgets('纯文字标题（非 customTitle 分段形态）永不收纳', (WidgetTester tester) async {
    final List<String> tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: FushiPageHeader(
                title: '一个很长很长很长很长很长很长的页面标题',
                actions: buildActions(tapped),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.more_vert), findsNothing,
        reason: '文字标题自身可省略号收缩，维持既有行为');
    expect(find.byIcon(Icons.star_border), findsNWidgets(4));
  });
}

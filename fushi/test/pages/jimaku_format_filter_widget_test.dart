import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/pages/implementations/jimaku_subtitle_dialog.dart';
import 'package:fushi/utils.dart';

/// 「获取字幕（Jimaku）」对话框的**类型筛选**（用户：「支持筛选类型，也就是 ass 的」）。
///
/// 纯函数层（[filterCandidatesByFormat] / [availableFormats]）在 `jimaku_filter_test.dart`
/// 里断言；这里驱动真对话框，锁住三条 UI 契约：类型 chip 真渲染、点它真过滤列表、
/// 只有一种类型时整区不出现（单选项筛选器是纯噪声）。
void main() {
  JimakuCandidate cand(String name) => JimakuCandidate(
        entryName: 'Some Anime Series',
        name: name,
      );

  Future<void> pumpDialog(
    WidgetTester tester,
    List<JimakuCandidate> candidates,
  ) async {
    // 宽屏两栏：筛选面板与结果列表同屏可见，chip 与候选行不用滚动即可命中。
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(builder: (BuildContext ctx) {
            return ElevatedButton(
              onPressed: () => showDialog<String>(
                context: ctx,
                builder: (_) => JimakuSubtitleDialog(
                  initialQuery: 'Some Anime',
                  initialApiKey: 'TEST_KEY',
                  onApiKeyChanged: (_) async {},
                  saveDirectory: '/tmp/jimaku',
                  debugInitialCandidates: candidates,
                ),
              ),
              child: const Text('open'),
            );
          }),
        ),
      ),
    );
    await tester.tap(find.text('open'), warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  /// 类型分区（`_chipSection` 的 Column）：最近的那个 Column 祖先就是它。
  /// 必须限定在这个分区里找 chip——「全部」在语言区也有一个同名 chip。
  Finder formatSection() => find
      .ancestor(
        of: find.text(t.video_jimaku_format),
        matching: find.byType(Column),
      )
      .first;

  Finder formatChip(String label) => find.descendant(
        of: formatSection(),
        matching: find.widgetWithText(ChoiceChip, label),
      );

  final List<JimakuCandidate> mixed = <JimakuCandidate>[
    cand('Show - 01.ja.srt'),
    cand('Show - 01.ja.ass'),
    cand('Show - 02.ja.ass'),
  ];

  testWidgets('混合类型时渲染 ASS / SRT 类型 chip', (WidgetTester tester) async {
    await pumpDialog(tester, mixed);
    expect(find.text(t.video_jimaku_format), findsOneWidget);
    expect(formatChip('ASS'), findsOneWidget);
    expect(formatChip('SRT'), findsOneWidget);
    expect(formatChip(t.video_jimaku_format_all), findsOneWidget);
    // 未选类型时三条候选都在。
    expect(find.text('Show - 01.ja.srt'), findsOneWidget);
    expect(find.text('Show - 01.ja.ass'), findsOneWidget);
    expect(find.text('Show - 02.ja.ass'), findsOneWidget);
  });

  testWidgets('点 ASS 只剩 ass 候选，点「全部」还原', (WidgetTester tester) async {
    await pumpDialog(tester, mixed);

    await tester.tap(formatChip('ASS'));
    await tester.pumpAndSettle();
    expect(find.text('Show - 01.ja.srt'), findsNothing,
        reason: '选了 ass 之后 srt 候选必须从列表里消失');
    expect(find.text('Show - 01.ja.ass'), findsOneWidget);
    expect(find.text('Show - 02.ja.ass'), findsOneWidget);

    await tester.tap(formatChip(t.video_jimaku_format_all));
    await tester.pumpAndSettle();
    expect(find.text('Show - 01.ja.srt'), findsOneWidget,
        reason: '「全部」必须把被筛掉的候选放回来');
  });

  testWidgets('只有一种类型时不渲染类型筛选区', (WidgetTester tester) async {
    await pumpDialog(tester, <JimakuCandidate>[
      cand('Show - 01.ja.srt'),
      cand('Show - 02.ja.srt'),
    ]);
    expect(find.text(t.video_jimaku_format), findsNothing,
        reason: '所有候选都是同一种类型时，类型筛选器无从筛起，不该占版面');
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/video/jimaku_client.dart';
import 'package:hibiki/src/pages/implementations/jimaku_subtitle_dialog.dart';

/// 矮屏（手机横屏 / 软键盘弹起时的可视高度）下验证 Jimaku 自动获取字幕对话框候选列表区。
///
/// 旧根因：候选列表放在 `AlertDialog.content` 的 `Column(mainAxisSize: min)` 里的
/// `Flexible` 中——AlertDialog 不给 content 固定高度，`Column.min` 下 `Flexible` 拿到
/// 0 剩余空间 → 列表被压成 0 高，既看不见又吞滚动（用户「太矮、滚不动」）。
///
/// 修后：整个对话框改用 `Dialog`（其 child 被约束到屏幕减 inset 的有界高度），候选列表用
/// `Flexible` 分到剩余空间 + 普通（非 shrinkWrap）ListView，矮屏可见、可滚、任何屏幕高度都
/// 不溢出。测试直接 pump 真实 [JimakuSubtitleDialog]（通过 `debugInitialCandidates` 预置结果
/// 免联网）。
void main() {
  List<JimakuCandidate> makeCandidates(int n) {
    return List<JimakuCandidate>.generate(
      n,
      (int i) => JimakuCandidate(
        entryName: 'Some Anime Series Title $i',
        file: JimakuFile(name: 'episode.$i.WEBRip.ja.srt', url: 'https://x/$i'),
      ),
      growable: false,
    );
  }

  /// pump 真实对话框（预置候选 + 已配 key），矮/高屏可调。
  Future<void> pumpDialog(
    WidgetTester tester, {
    required Size screen,
    int candidateCount = 40,
  }) async {
    tester.view.physicalSize = screen;
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
                  debugInitialCandidates: makeCandidates(candidateCount),
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

  Finder candidateScrollable() => find.descendant(
        of: find.byType(JimakuCandidateList),
        matching: find.byType(Scrollable),
      );

  // 矮屏：小屏手机竖屏 / 软键盘弹起后压低的可视高度（修后仍可见、可滚、不溢出）。
  const Size shortScreen = Size(360, 480);
  // 更极端的矮屏（横屏），用于复现旧布局把列表压成 0 高的根因。
  const Size collapseScreen = Size(360, 320);

  testWidgets(
      'regression: OLD AlertDialog Flexible layout collapses candidate list',
      (WidgetTester tester) async {
    // 复刻旧布局（已被废弃），锁定它在矮屏下确实把列表压成 0 高（根因）。
    tester.view.physicalSize = collapseScreen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(builder: (BuildContext ctx) {
            return ElevatedButton(
              onPressed: () => showDialog<void>(
                context: ctx,
                builder: (_) => AlertDialog(
                  title: const Text('Jimaku'),
                  content: SizedBox(
                    width: 380,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const TextField(),
                        const SizedBox(height: 8),
                        const TextField(),
                        const SizedBox(height: 12),
                        Flexible(
                          child: JimakuCandidateList(
                            candidates: makeCandidates(40),
                            filter: '',
                            busyName: null,
                            onDownload: (_) {},
                          ),
                        ),
                      ],
                    ),
                  ),
                  actions: <Widget>[
                    TextButton(onPressed: () {}, child: const Text('Cancel')),
                  ],
                ),
              ),
              child: const Text('open'),
            );
          }),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final Size listSize = tester.getSize(find.byType(JimakuCandidateList));
    expect(listSize.height, lessThan(1.0),
        reason: '旧 AlertDialog+Column.min+Flexible 在矮屏把候选列表压成 0 高（根因）');
    // 旧布局在该矮屏上还会触发 RenderFlex 溢出——这是同一根因的伴随症状，预期发生，
    // 取出以免污染本测试。
    expect(tester.takeException(), isNotNull,
        reason: '旧布局矮屏下伴随 RenderFlex 溢出（根因症状之一）');
  });

  testWidgets('fixed: real dialog list is visible and bounded on short screen',
      (WidgetTester tester) async {
    await pumpDialog(tester, screen: shortScreen);
    final Size listSize = tester.getSize(find.byType(JimakuCandidateList));
    expect(listSize.height, greaterThan(0.0), reason: '修后矮屏候选列表应仍可见（非 0 高）');
    expect(listSize.height, lessThan(480.0), reason: '高度有界、不溢出屏幕');
    expect(tester.takeException(), isNull, reason: '不应有 RenderFlex 溢出异常');
  });

  testWidgets('fixed: real dialog list actually scrolls when overflowing',
      (WidgetTester tester) async {
    await pumpDialog(tester, screen: shortScreen);
    final ScrollableState state = tester.state(candidateScrollable());
    final double before = state.position.pixels;
    expect(state.position.maxScrollExtent, greaterThan(0.0),
        reason: '候选超出可视区时应有可滚动余量');

    await tester.drag(candidateScrollable(), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(state.position.pixels, greaterThan(before), reason: '拖动后列表应真的滚下去');
  });

  testWidgets('fixed: list grows with available height',
      (WidgetTester tester) async {
    await pumpDialog(tester, screen: const Size(360, 480));
    final double shortH =
        tester.getSize(find.byType(JimakuCandidateList)).height;
    await pumpDialog(tester, screen: const Size(360, 800));
    final double tallH =
        tester.getSize(find.byType(JimakuCandidateList)).height;
    expect(tallH, greaterThan(shortH),
        reason: '可用高度更大时列表应更高（Flexible 分到更多剩余空间）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('feature: api key collapses to summary when key set + results',
      (WidgetTester tester) async {
    await pumpDialog(tester, screen: const Size(360, 700));
    // 已配 key + 有结果 → 折叠为摘要行（不再有 obscure 密码框），并出现「修改」按钮。
    expect(find.text(t.video_jimaku_api_key_set), findsOneWidget,
        reason: '配好 key 且有结果时 API key 输入区应折叠为摘要');
    expect(find.widgetWithText(TextButton, t.dialog_edit), findsOneWidget,
        reason: '折叠后应有「修改」按钮可展开');

    // 点「修改」→ 展开回完整密码框（labelText 出现）。
    await tester.tap(find.widgetWithText(TextButton, t.dialog_edit));
    await tester.pumpAndSettle();
    expect(find.text(t.video_jimaku_api_key_set), findsNothing,
        reason: '点「修改」后应展开输入区，摘要消失');
  });

  // TODO-673：番名都一样、只有集数（第01話/E01...）不同的真实场景下，结果项文件名
  // 若单行 ellipsis 截断就把区分集数的部分吃掉，用户分不清是第几集。修后文件名标题
  // 允许换行（maxLines>1 + softWrap），完整文件名（含集数）可渲染、可见。
  List<JimakuCandidate> makeSameSeriesEpisodes() {
    const String longSeries = 'デッドデッドデーモンズデデデデデストラクション';
    return <JimakuCandidate>[
      JimakuCandidate(
        entryName: 'Dead Dead Demons Dededede Destruction',
        file: JimakuFile(
            name: '$longSeries 第01話 [WEBRip 1080p].ja.srt', url: 'https://x/1'),
      ),
      JimakuCandidate(
        entryName: 'Dead Dead Demons Dededede Destruction',
        file: JimakuFile(
            name: '$longSeries 第02話 [WEBRip 1080p].ja.srt', url: 'https://x/2'),
      ),
    ];
  }

  testWidgets(
      'TODO-673: result title wraps (maxLines>1 + softWrap), episode visible',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: JimakuCandidateList(
              candidates: makeSameSeriesEpisodes(),
              filter: '',
              busyName: null,
              onDownload: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 标题 Text（文件名）必须换行：maxLines>1 且 softWrap，且不再用 ellipsis 截断
    // （否则集数被吃掉）。
    final Iterable<Text> titles = tester.widgetList<Text>(
      find.textContaining('第01話'),
    );
    expect(titles, isNotEmpty, reason: '含集数(第01話)的完整文件名应作为标题被渲染');
    final Text title = titles.first;
    expect(title.maxLines, isNotNull, reason: '标题应设置 maxLines（多行而非默认单行截断）');
    expect(title.maxLines!, greaterThan(1),
        reason: '标题 maxLines 应 >1 才能换行显示完整文件名');
    expect(title.softWrap, isTrue, reason: '标题应 softWrap 才能换行');
    expect(title.overflow, isNot(TextOverflow.ellipsis),
        reason: '标题不应再用 ellipsis 截断（会吃掉区分集数的部分）');

    // 第二集的集数同样可见——两集番名相同，唯一区分点（第02話）必须渲染出来。
    expect(find.textContaining('第02話'), findsOneWidget,
        reason: '第二集的集数(第02話)也应完整可见');
    expect(tester.takeException(), isNull);
  });
}

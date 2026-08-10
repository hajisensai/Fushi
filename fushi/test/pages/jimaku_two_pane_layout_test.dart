import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/pages/implementations/jimaku_subtitle_dialog.dart';

/// Jimaku 对话框两栏布局重构的回归测试。
///
/// 用户报的根因（手机滑动不了）：PR#145 加入的系列消歧 chip 区（`_buildSeriesChips`）
/// 放在外层 Column 的**固定槽位**——既不可滚也不 Flexible。AniList 命中多个系列（长
/// 罗马音标题换行五六行）时，这块固定高度把候选列表的 Flexible 挤成 0 高，而 chip 区
/// 自身也滚不动，整个对话框中段「卡死」。
///
/// 修后：系列选择移入一体滚动的筛选面板（宽屏左栏 / 窄屏上段 Flexible），结果列表
/// 独立成结果区（宽屏右栏 / 窄屏下段 Flexible）——面板内容再多也只在面板内滚，列表
/// 永远分得到非 0 高度且可滚。
void main() {
  test('BUG-1504: dialog and filter pane scale across viewport widths', () {
    expect(resolveJimakuDialogMaxWidth(360), 328);
    expect(resolveJimakuDialogMaxWidth(800), closeTo(752, 0.001));
    expect(resolveJimakuDialogMaxWidth(1280), closeTo(1152, 0.001));
    expect(resolveJimakuDialogMaxWidth(2048), closeTo(1843.2, 0.001));
    expect(resolveJimakuFilterPaneWidth(700), 300);
    expect(resolveJimakuFilterPaneWidth(1280), closeTo(358.4, 0.001));
    expect(resolveJimakuFilterPaneWidth(1800), 420);
  });

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

  /// 复刻用户截图场景的多系列命中：长罗马音标题 × 8。
  List<AniListMedia> makeSeriesMatches(int n) {
    return List<AniListMedia>.generate(
      n,
      (int i) => AniListMedia(
        id: 100 + i,
        romaji: 'Keikenzumi na Kimi to, Keiken Zero na Ore ga, '
            'Otsukiai suru Hanashi $i',
      ),
      growable: false,
    );
  }

  Future<void> pumpDialog(
    WidgetTester tester, {
    required Size screen,
    int candidateCount = 30,
    int seriesCount = 8,
  }) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
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
                  debugInitialSeriesMatches: makeSeriesMatches(seriesCount),
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

  testWidgets(
      'regression: many series matches on phone keep list visible + scrollable',
      (WidgetTester tester) async {
    // 手机竖屏 + 8 个长标题系列命中（用户截图场景）：旧布局把候选列表挤成 0 高且
    // 中段不可滚；修后列表仍可见、可滚、无 RenderFlex 溢出。
    await pumpDialog(tester, screen: const Size(360, 640));
    expect(tester.takeException(), isNull, reason: '多系列不应造成 RenderFlex 溢出');

    final Size listSize = tester.getSize(find.byType(JimakuCandidateList));
    expect(listSize.height, greaterThan(0.0), reason: '多系列时候选列表不能被挤成 0 高（旧根因）');

    final ScrollableState state = tester.state(candidateScrollable());
    expect(state.position.maxScrollExtent, greaterThan(0.0),
        reason: '候选列表应有可滚余量');
    final double before = state.position.pixels;
    await tester.drag(candidateScrollable(), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(state.position.pixels, greaterThan(before),
        reason: '手机上候选列表应真的能滚（用户报「手机滑动不了」）');
  });

  testWidgets('regression: series entries live inside a scrollable pane',
      (WidgetTester tester) async {
    // 系列条目在筛选面板（SingleChildScrollView）内——面板可滚，全部系列可达；
    // 不再是外层 Column 的固定槽位。
    await pumpDialog(tester, screen: const Size(360, 640));
    final Finder firstSeries =
        find.textContaining('Otsukiai suru Hanashi 0', skipOffstage: false);
    expect(firstSeries, findsOneWidget, reason: '系列条目应被构建');
    expect(
      find.ancestor(
        of: firstSeries,
        matching: find.byType(SingleChildScrollView),
      ),
      findsWidgets,
      reason: '系列条目必须位于可滚动的筛选面板内（而非固定槽位）',
    );
  });

  testWidgets('wide screen: filter pane left, results list right (two-pane)',
      (WidgetTester tester) async {
    await pumpDialog(tester, screen: const Size(1280, 800));
    expect(tester.takeException(), isNull);

    final Finder queryField = find.byWidgetPredicate(
        (Widget w) => w is TextField && w.controller?.text == 'Some Anime');
    expect(queryField, findsOneWidget);
    final Finder list = find.byType(JimakuCandidateList);
    expect(list, findsOneWidget);

    final Rect queryRect = tester.getRect(queryField);
    final Rect listRect = tester.getRect(list);
    expect(listRect.left, greaterThan(queryRect.right),
        reason: '宽屏下结果列表应在筛选面板右侧（两栏并排）');
    expect(listRect.top, lessThan(queryRect.bottom),
        reason: '两栏应大致同排（列表顶端不低于筛选面板首个输入框底端）');
    expect(tester.getSize(find.byType(Dialog)).width, greaterThan(900),
        reason: 'BUG-1504：桌面 Jimaku 框不应继续被 720dp 上限压成窄条');
  });

  test('BUG-1504: search paints loading frame before persistence and network',
      () {
    final String source =
        File('lib/src/pages/implementations/jimaku_subtitle_dialog.dart')
            .readAsStringSync();
    final int methodStart = source.indexOf('Future<void> _search() async {');
    final int methodEnd = source.indexOf(
      'Future<void> _selectSeries(',
      methodStart,
    );
    final String search = source.substring(methodStart, methodEnd);

    final int searchingState = search.indexOf('_searching = true;');
    final int paintFrame =
        search.indexOf('await WidgetsBinding.instance.endOfFrame;');
    final int persistKey =
        search.indexOf('await widget.onApiKeyChanged(apiKey);');
    final int createClient = search.indexOf('AniListClient(');
    expect(searchingState, greaterThanOrEqualTo(0));
    expect(paintFrame, greaterThan(searchingState));
    expect(persistKey, greaterThan(paintFrame));
    expect(createClient, greaterThan(persistKey));
  });

  testWidgets('narrow screen: single column (list below filter pane)',
      (WidgetTester tester) async {
    await pumpDialog(tester, screen: const Size(360, 640));
    final Finder queryField = find.byWidgetPredicate(
        (Widget w) => w is TextField && w.controller?.text == 'Some Anime');
    final Rect queryRect = tester.getRect(queryField);
    final Rect listRect = tester.getRect(find.byType(JimakuCandidateList));
    expect(listRect.left, lessThan(queryRect.right),
        reason: '窄屏下结果列表应与筛选面板同列（上下两段）');
  });

  testWidgets('search button lives in filter pane; cancel stays at bottom',
      (WidgetTester tester) async {
    // 配置项重排：搜索按钮跟随搜索输入组（手绘稿左栏 KEY→TITLE→SEARCH），
    // 底部动作区只留「取消」。
    await pumpDialog(tester, screen: const Size(1280, 800));
    final Finder searchBtn = find.byType(FilledButton);
    expect(searchBtn, findsOneWidget);
    final Finder queryField = find.byWidgetPredicate(
        (Widget w) => w is TextField && w.controller?.text == 'Some Anime');
    // 搜索按钮与番名输入框水平对齐（同在左栏），而非对话框右下角。
    final Rect btnRect = tester.getRect(searchBtn);
    final Rect queryRect = tester.getRect(queryField);
    expect(btnRect.left, closeTo(queryRect.left, 1.0),
        reason: '搜索按钮应在筛选面板内与输入框同栏');
  });
}

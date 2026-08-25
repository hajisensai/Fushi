import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
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
  test('BUG-1509: dialog and filter pane scale across viewport widths', () {
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
        name: 'episode.$i.WEBRip.ja.srt',
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
        reason: 'BUG-1509：桌面 Jimaku 框不应继续被 720dp 上限压成窄条');
  });

  test('BUG-1509: search paints loading frame before persistence and network',
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

  testWidgets('search button sits in the fixed bottom action bar with cancel',
      (WidgetTester tester) async {
    // 搜索是本框唯一主操作，必须在不随正文滚动的底部操作栏里——放进可滚动的
    // 筛选面板（上一版「跟随输入框」的排版）在矮视口下结构上不可达。
    await pumpDialog(tester, screen: const Size(1280, 800));
    final Finder searchBtn = find.byType(FilledButton);
    expect(searchBtn, findsOneWidget);
    final Finder cancelBtn = find.widgetWithText(TextButton, t.dialog_cancel);
    expect(cancelBtn, findsOneWidget);
    final Rect btnRect = tester.getRect(searchBtn);
    final Rect cancelRect = tester.getRect(cancelBtn);
    final Rect dialogRect = tester.getRect(find.byType(Dialog));
    expect(btnRect.center.dy, closeTo(cancelRect.center.dy, 1.0),
        reason: '搜索与取消同一行');
    expect(btnRect.left, greaterThan(cancelRect.right),
        reason: '主操作在取消右侧');
    expect(btnRect.bottom, lessThanOrEqualTo(dialogRect.bottom),
        reason: '操作栏在对话框内');
    expect(
      find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.byType(FilledButton),
      ),
      findsNothing,
      reason: '搜索按钮不得回到可滚动的筛选面板里',
    );
  });

  testWidgets(
      'regression: phone landscape + keyboard keeps search button reachable',
      (WidgetTester tester) async {
    // 用户截图：iPhone 横屏点集数框弹出数字键盘（iOS 数字键盘无回车键），对话框
    // 只剩百来 dp 高——筛选面板只露出一个输入框，旧版藏在面板里的搜索按钮滚出
    // 视野，整个框只看得见「取消」。修后搜索按钮固定在底栏、必须落在键盘上方且
    // 可点。
    const Size screen = Size(844, 390);
    const double keyboard = 200;
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.resetViewInsets);
    await pumpDialog(tester, screen: screen, candidateCount: 0, seriesCount: 0);
    expect(tester.takeException(), isNull);

    final Finder searchBtn = find.byType(FilledButton);
    expect(searchBtn, findsOneWidget);
    final Rect btnRect = tester.getRect(searchBtn);
    expect(btnRect.bottom, lessThanOrEqualTo(screen.height - keyboard),
        reason: '搜索按钮必须完整落在键盘上方');
    expect(btnRect.top, greaterThanOrEqualTo(0));
    expect(tester.widget<FilledButton>(searchBtn).onPressed, isNotNull);
    final RenderObject buttonRender = tester.renderObject(searchBtn);
    expect(
      tester
          .hitTestOnBinding(btnRect.center)
          .path
          .any((HitTestEntry e) => e.target == buttonRender),
      isTrue,
      reason: '搜索按钮必须真能被点中（没被遮、没被裁）',
    );
  });

  testWidgets(
      'regression: 320dp phone + keyboard, every locale: action bar never overflows',
      (WidgetTester tester) async {
    // 审查发现：底栏若用裸 Row，320dp 窄机（内容宽 240）下 en/de/ru 的「取消 +
    // 搜索」并排溢出 13~70px。OverflowBar 放不下改竖排——17 语种逐个过。
    final AppLocale previous = LocaleSettings.currentLocale;
    addTearDown(() => LocaleSettings.setLocale(previous));
    const Size screen = Size(320, 568);
    const double keyboard = 260;
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.resetViewInsets);
    for (final AppLocale locale in AppLocale.values) {
      LocaleSettings.setLocale(locale);
      await pumpDialog(tester, screen: screen, candidateCount: 0, seriesCount: 0);
      expect(tester.takeException(), isNull,
          reason: '$locale：操作栏不得 RenderFlex 溢出');
      final Rect btn = tester.getRect(find.byType(FilledButton));
      final Rect dialog = tester.getRect(find.byType(Dialog));
      expect(btn.right, lessThanOrEqualTo(dialog.right + 0.5),
          reason: '$locale：搜索按钮不得伸出对话框右缘');
      expect(btn.bottom, lessThanOrEqualTo(screen.height - keyboard + 0.5),
          reason: '$locale：搜索按钮必须落在键盘上方');
      await tester.tap(find.byType(FilledButton), warnIfMissed: false);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';

import '../helpers/glass_unwrap.dart';
import 'widget_test_helpers.dart' as helpers;
import 'package:fushi/src/utils/fushi_icons.dart';

// FushiSearchBar / FushiSearchView（M3E 搜索共享层）的行为契约：防抖、IME
// 组字期间不出查询、清空、Esc 清空 / 失焦并归还焦点、提交跳过防抖；搜索视图
// 窄屏全屏 / 宽屏 docked、展开收起、最近搜索、Esc 关闭后焦点回到搜索栏。

// These tests assert input contracts, independently of GPU splash assets.
Widget buildTestApp(Widget child) => helpers.buildTestApp(
  child,
  theme: ThemeData.light(
    useMaterial3: true,
  ).copyWith(splashFactory: NoSplash.splashFactory),
);

Future<void> _pumpBar(
  WidgetTester tester,
  FushiSearchBar bar, {
  Widget? before,
}) async {
  await tester.pumpWidget(
    buildTestApp(
      Column(
        children: <Widget>[
          if (before != null) before,
          SizedBox(width: 400, child: bar),
        ],
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('FushiSearchBar', () {
    testWidgets('零防抖即时出查询，同值不重复', (WidgetTester tester) async {
      final List<String> queries = <String>[];
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      await _pumpBar(
        tester,
        FushiSearchBar(
          hintText: 'Search',
          controller: controller,
          onQueryChanged: queries.add,
        ),
      );
      await tester.enterText(find.byType(TextField), 'abc');
      expect(queries, <String>['abc']);
      controller.text = 'abc';
      expect(queries, <String>['abc'], reason: '同值不重复出查询');
    });

    testWidgets('防抖：停止输入满时长才出查询', (WidgetTester tester) async {
      final List<String> queries = <String>[];
      await _pumpBar(
        tester,
        FushiSearchBar(
          hintText: 'Search',
          debounce: const Duration(milliseconds: 300),
          onQueryChanged: queries.add,
        ),
      );
      await tester.enterText(find.byType(TextField), 'a');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(find.byType(TextField), 'ab');
      await tester.pump(const Duration(milliseconds: 200));
      expect(queries, isEmpty);
      await tester.pump(const Duration(milliseconds: 150));
      expect(queries, <String>['ab']);
    });

    testWidgets('IME 组字期间不出查询，确认后才出', (WidgetTester tester) async {
      final List<String> queries = <String>[];
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      await _pumpBar(
        tester,
        FushiSearchBar(
          hintText: 'Search',
          controller: controller,
          onQueryChanged: queries.add,
        ),
      );
      controller.value = const TextEditingValue(
        text: 'にほん',
        composing: TextRange(start: 0, end: 3),
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();
      expect(queries, isEmpty, reason: '组字中的假名不触发搜索');
      // 选词确认：文本换成汉字、composing 收起。
      controller.value = const TextEditingValue(
        text: '日本',
        selection: TextSelection.collapsed(offset: 2),
      );
      await tester.pump();
      expect(queries, <String>['日本']);
    });

    testWidgets('组字中的 Esc / 回车交给输入法：不清空、不提交', (WidgetTester tester) async {
      final List<String> submitted = <String>[];
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      await _pumpBar(
        tester,
        FushiSearchBar(
          hintText: 'Search',
          controller: controller,
          onSubmitted: submitted.add,
        ),
      );
      await tester.showKeyboard(find.byType(TextField));
      controller.value = const TextEditingValue(
        text: 'かな',
        composing: TextRange(start: 0, end: 2),
        selection: TextSelection.collapsed(offset: 2),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(controller.text, 'かな', reason: '组字中的 Esc 属于输入法，不能被清空');
    });

    testWidgets('清空钮：清空、交出空查询、保留焦点', (WidgetTester tester) async {
      final List<String> queries = <String>[];
      int cleared = 0;
      final FocusNode focus = FocusNode();
      addTearDown(focus.dispose);
      await _pumpBar(
        tester,
        FushiSearchBar(
          hintText: 'Search',
          focusNode: focus,
          clearButtonKey: const ValueKey<String>('clear'),
          onQueryChanged: queries.add,
          onClear: () => cleared++,
        ),
      );
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('clear')));
      await tester.pump();
      expect(queries, <String>['abc', '']);
      expect(cleared, 1);
      expect(focus.hasFocus, isTrue);
      expect(find.byKey(const ValueKey<String>('clear')), findsNothing);
    });

    testWidgets('Esc：有字清空；空框按 clearThenUnfocus 把焦点还回去', (
      WidgetTester tester,
    ) async {
      final FocusNode back = FocusNode(debugLabel: 'restore-target');
      final FocusNode field = FocusNode(debugLabel: 'field');
      addTearDown(back.dispose);
      addTearDown(field.dispose);
      int escaped = 0;
      await _pumpBar(
        tester,
        FushiSearchBar(
          hintText: 'Search',
          focusNode: field,
          escapeBehavior: FushiSearchEscapeBehavior.clearThenUnfocus,
          restoreFocusTo: back,
          onEscape: () => escaped++,
        ),
        before: Focus(focusNode: back, child: const SizedBox(height: 10)),
      );
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('abc'), findsNothing);
      expect(field.hasFocus, isTrue, reason: '第一下 Esc 只清空');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(field.hasFocus, isFalse);
      expect(back.hasFocus, isTrue, reason: '焦点归还给 restoreFocusTo');
      expect(escaped, 1);
    });

    testWidgets('默认 Esc 空框放行（交给页面 / 对话框）', (WidgetTester tester) async {
      final FocusNode field = FocusNode();
      addTearDown(field.dispose);
      bool pageGotEscape = false;
      await tester.pumpWidget(
        buildTestApp(
          Focus(
            onKeyEvent: (FocusNode node, KeyEvent event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                pageGotEscape = true;
              }
              return KeyEventResult.ignored;
            },
            child: SizedBox(
              width: 400,
              child: FushiSearchBar(hintText: 'Search', focusNode: field),
            ),
          ),
        ),
      );
      await tester.showKeyboard(find.byType(TextField));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(pageGotEscape, isTrue);
      expect(field.hasFocus, isTrue);
    });

    testWidgets('回车提交跳过防抖', (WidgetTester tester) async {
      final List<String> queries = <String>[];
      final List<String> submitted = <String>[];
      await _pumpBar(
        tester,
        FushiSearchBar(
          hintText: 'Search',
          debounce: const Duration(seconds: 1),
          onQueryChanged: queries.add,
          onSubmitted: submitted.add,
        ),
      );
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(submitted, <String>['abc']);
      expect(queries, <String>['abc'], reason: '提交立即交出查询');
    });

    testWidgets('onBack 换成返回箭头，仍是胶囊搜索框', (WidgetTester tester) async {
      int backs = 0;
      await _pumpBar(
        tester,
        FushiSearchBar(hintText: 'Search', onBack: () => backs++),
      );
      expect(find.byIcon(FushiIcons.back), findsOneWidget);
      expect(find.byIcon(FushiIcons.search), findsNothing);
      await tester.tap(find.byIcon(FushiIcons.back));
      expect(backs, 1);
      final TextField field = tester.widget<TextField>(
        glassUnwrap<TextField>(find.byType(TextField)),
      );
      final OutlineInputBorder border =
          field.decoration!.border! as OutlineInputBorder;
      expect(border.borderRadius, BorderRadius.circular(999));
    });

    testWidgets('large 档是 56 高 M3 search bar，avatar 排在尾部', (
      WidgetTester tester,
    ) async {
      await _pumpBar(
        tester,
        const FushiSearchBar(
          hintText: 'Search',
          size: FushiSearchFieldSize.large,
          avatar: ColoredBox(
            key: ValueKey<String>('avatar'),
            color: Colors.teal,
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(FushiSearchField)).height,
        kFushiSearchFieldLargeHeight,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey<String>('avatar'))),
        const Size(32, 32),
      );
    });
  });

  group('FushiSearchView', () {
    Future<void> pumpAnchor(
      WidgetTester tester, {
      required Size size,
      List<String> recent = const <String>[],
      ValueChanged<String>? onSubmitted,
      ValueChanged<String>? onQueryChanged,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        buildTestApp(
          Padding(
            padding: const EdgeInsets.all(24),
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 360,
                child: FushiSearchAnchor(
                  hintText: 'Search books',
                  recentSearches: recent,
                  onRemoveRecent: (_) {},
                  onSubmitted: onSubmitted,
                  onQueryChanged: onQueryChanged,
                  resultsBuilder: (BuildContext context, String query) =>
                      ListView(
                        children: <Widget>[
                          Text('result:$query', key: const ValueKey('r')),
                        ],
                      ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Finder surface() => find
        .ancestor(
          of: find.byType(OverflowBox),
          matching: find.byType(Positioned),
        )
        .first;

    testWidgets('窄屏展开为全屏，Esc 收起且焦点回到搜索栏', (WidgetTester tester) async {
      await pumpAnchor(tester, size: const Size(420, 900));
      await tester.tap(find.text('Search books'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // 容器变换进行中：表面比屏幕小。
      expect(tester.getSize(surface()).height, lessThan(900));
      await tester.pumpAndSettle();
      expect(tester.getSize(surface()), const Size(420, 900));
      expect(find.byIcon(FushiIcons.back), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(OverflowBox), findsNothing);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'fushi-search-anchor',
        reason: '收起后焦点回到搜索栏',
      );
    });

    testWidgets('宽屏为 docked 面板，输入出结果，回车提交并关闭', (WidgetTester tester) async {
      final List<String> submitted = <String>[];
      await pumpAnchor(
        tester,
        size: const Size(1600, 900),
        onSubmitted: submitted.add,
      );
      await tester.tap(find.text('Search books'));
      await tester.pumpAndSettle();
      final Size docked = tester.getSize(surface());
      expect(docked.width, lessThan(800));
      expect(docked.height, lessThan(900));

      await tester.enterText(find.byType(TextField).last, 'kotoba');
      await tester.pump();
      expect(find.text('result:kotoba'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(submitted, <String>['kotoba']);
      expect(find.byType(OverflowBox), findsNothing);
    });

    testWidgets('组字中不出结果；最近搜索可移除、点按即提交', (WidgetTester tester) async {
      final List<String> queries = <String>[];
      final List<String> submitted = <String>[];
      await pumpAnchor(
        tester,
        size: const Size(420, 900),
        recent: const <String>['猫', '犬'],
        onQueryChanged: queries.add,
        onSubmitted: submitted.add,
      );
      await tester.tap(find.text('Search books'));
      await tester.pumpAndSettle();
      expect(find.text('猫'), findsOneWidget);
      expect(find.text('犬'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('犬'),
            matching: find.byType(FushiListItem),
          ),
          matching: find.byIcon(FushiIcons.close),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('犬'), findsNothing);

      final TextField field = tester.widget<TextField>(
        find.byType(TextField).last,
      );
      field.controller!.value = const TextEditingValue(
        text: 'ねこ',
        composing: TextRange(start: 0, end: 2),
        selection: TextSelection.collapsed(offset: 2),
      );
      await tester.pump();
      expect(queries, isEmpty);
      expect(find.textContaining('result:'), findsNothing);
      field.controller!.value = const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
      await tester.pump();

      await tester.tap(find.text('猫'));
      await tester.pumpAndSettle();
      expect(submitted, <String>['猫']);
    });

    test('auto 形态按 600 分界', () {
      expect(
        resolveFushiSearchViewMode(FushiSearchViewMode.auto, 420),
        FushiSearchViewMode.fullScreen,
      );
      expect(
        resolveFushiSearchViewMode(FushiSearchViewMode.auto, 1600),
        FushiSearchViewMode.docked,
      );
    });

    test('弹簧曲线 0→1，末端落在 1', () {
      const FushiSpringCurve curve = FushiSpringCurve.spatial;
      expect(curve.transform(0), 0);
      expect(curve.transform(1), 1);
      expect(curve.transform(0.3), greaterThan(0.5));
    });
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/dictionary_download_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_dialog_page.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('dictionary download selection dialog fits a compact window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 480);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        DictionaryDownloadSelectionDialogFrame(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text('Language'),
              for (int index = 0; index < 12; index++)
                Text('Recommended dictionary with a long label $index'),
            ],
          ),
          actions: const <Widget>[
            TextButton(onPressed: null, child: Text('Cancel')),
            FilledButton(onPressed: null, child: Text('Download 12')),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Download 12'), findsOneWidget);
  });

  testWidgets('dictionary download progress dialog fits a compact window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 480);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        DictionaryDownloadProgressDialog(
          message:
              'Downloading a recommended dictionary with a long visible name',
          progressListenable: ValueNotifier<double>(0.42),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  group('BUG-1499 进度框：取消与后台化', () {
    testWidgets('下载阶段：取消按钮可点，不显示「停不下来」的说明', (WidgetTester tester) async {
      int cancelled = 0;
      await tester.pumpWidget(
        buildApp(
          DictionaryDownloadProgressDialog(
            message: 'Downloading JMdict',
            progressListenable: ValueNotifier<double>(0.42),
            onCancel: () => cancelled++,
            cancelDisabledHint: t.dict_download_import_uncancellable,
            onHide: () {},
          ),
        ),
      );

      expect(find.text(t.dict_download_import_uncancellable), findsNothing);
      await tester.tap(find.text(t.dialog_cancel));
      await tester.pump();
      expect(cancelled, 1);
    });

    testWidgets('导入阶段：取消按钮点不动，并如实说明这一步无法中断', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildApp(
          DictionaryDownloadProgressDialog(
            message: 'Importing JMdict',
            progressListenable: ValueNotifier<double>(0),
            // onCancel == null 就是「这一阶段停不下来」的唯一表达。
            cancelDisabledHint: t.dict_download_import_uncancellable,
            onHide: () {},
          ),
        ),
      );

      expect(find.text(t.dict_download_import_uncancellable), findsOneWidget);
      await tester.tap(find.text(t.dialog_cancel));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '按钮 disabled，点了什么都不该发生');
    });

    testWidgets('收起进度框后任务照跑，结果仍然送达', (WidgetTester tester) async {
      final List<DictionaryDownloadOutcome> outcomes =
          <DictionaryDownloadOutcome>[];
      final DictionaryDownloadController controller =
          DictionaryDownloadController(showOutcome: outcomes.add);
      addTearDown(controller.dispose);
      final Completer<void> hold = Completer<void>();

      late BuildContext pageContext;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (BuildContext ctx) {
                pageContext = ctx;
                return const Scaffold(body: Text('dictionary page'));
              },
            ),
          ),
        ),
      );

      final Future<bool> running = controller.run(
        initialMessage: 'start',
        body: (DictionaryDownloadJob job) async {
          job.markDownloadPhase();
          // 给一个确定的比例：留 0 会让 LinearProgressIndicator 退化成不定态动画，
          // pumpAndSettle 永远等不到静止（那是测试脚手架的事，不是产品行为）。
          job.progress.value = 0.5;
          await hold.future;
          return const DictionaryDownloadOutcome(message: 'finished');
        },
      );
      await tester.pump();

      unawaited(showAppDialog<void>(
        context: pageContext,
        barrierDismissible: false,
        builder: (BuildContext ctx) => DictionaryDownloadProgressAutoCloser(
          phase: controller.phase,
          child: DictionaryDownloadProgressDialog(
            message: 'start',
            progressListenable: controller.progress,
            onHide: () => Navigator.of(ctx).pop(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text(t.dict_download_hide), findsOneWidget);

      await tester.tap(find.text(t.dict_download_hide));
      await tester.pumpAndSettle();

      expect(find.text(t.dict_download_hide), findsNothing, reason: '进度框收起来了');
      expect(find.text('dictionary page'), findsOneWidget,
          reason: '收起进度框绝不能连带弹掉词典页本身');
      expect(controller.isBusy, isTrue, reason: '任务不属于对话框，收起来只是不看');

      hold.complete();
      expect(await running, isTrue);
      await tester.pumpAndSettle();

      expect(outcomes.single.message, 'finished',
          reason: '结果由 controller 送出，与页面/对话框是否还在无关');
      expect(tester.takeException(), isNull);
    });

    testWidgets('任务结束时进度框自己关闭，只弹掉自己', (WidgetTester tester) async {
      final DictionaryDownloadController controller =
          DictionaryDownloadController(showOutcome: (_) {});
      addTearDown(controller.dispose);
      final Completer<void> hold = Completer<void>();

      late BuildContext pageContext;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (BuildContext ctx) {
                pageContext = ctx;
                return const Scaffold(body: Text('dictionary page'));
              },
            ),
          ),
        ),
      );

      final Future<bool> running = controller.run(
        initialMessage: 'start',
        body: (DictionaryDownloadJob job) async {
          job.markDownloadPhase();
          job.progress.value = 0.5;
          await hold.future;
          return null;
        },
      );
      await tester.pump();

      unawaited(showAppDialog<void>(
        context: pageContext,
        barrierDismissible: false,
        builder: (BuildContext ctx) => DictionaryDownloadProgressAutoCloser(
          phase: controller.phase,
          child: DictionaryDownloadProgressDialog(
            message: 'start',
            progressListenable: controller.progress,
            onHide: () => Navigator.of(ctx).pop(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text(t.dict_download_hide), findsOneWidget);

      hold.complete();
      expect(await running, isTrue);
      await tester.pumpAndSettle();

      expect(find.text(t.dict_download_hide), findsNothing,
          reason: '任务结束进度框应自己消失');
      expect(find.text('dictionary page'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('批量勾选：全选 / 反选 / 分类三态的可勾选域', () {
    test('可勾选域 = catalog 全体减去已安装项', () {
      expect(
        selectableDictionaryIndices(
          catalogLength: 5,
          installedIndices: <int>{1, 3},
        ),
        <int>{0, 2, 4},
      );
    });

    test('全部已安装时可勾选域为空（全选/反选按钮据此禁用）', () {
      expect(
        selectableDictionaryIndices(
          catalogLength: 3,
          installedIndices: <int>{0, 1, 2},
        ),
        isEmpty,
      );
    });

    test('没有已安装项时可勾选域是整份 catalog', () {
      expect(
        selectableDictionaryIndices(
          catalogLength: 3,
          installedIndices: const <int>{},
        ),
        <int>{0, 1, 2},
      );
    });

    test('反选只在可勾选域内翻转，已安装项不会被卷进来', () {
      final Set<int> selectable = selectableDictionaryIndices(
        catalogLength: 5,
        installedIndices: <int>{1},
      );
      final Set<int> checked = <int>{0, 2};
      expect(selectable.difference(checked), <int>{3, 4},
          reason: '已安装的 1 号既不在原选中集也不该被反选带出来');
    });

    test('分类三态：全选 true / 全不选 false / 部分 null', () {
      expect(
        dictionaryCategoryCheckState(
          categoryIndices: <int>{1, 2, 3},
          checked: <int>{1, 2, 3},
        ),
        isTrue,
      );
      expect(
        dictionaryCategoryCheckState(
          categoryIndices: <int>{1, 2, 3},
          checked: <int>{9},
        ),
        isFalse,
      );
      expect(
        dictionaryCategoryCheckState(
          categoryIndices: <int>{1, 2, 3},
          checked: <int>{2},
        ),
        isNull,
      );
    });

    test('分类可勾选域为空时给 false 而非 true（勾选框同时被禁用）', () {
      expect(
        dictionaryCategoryCheckState(
          categoryIndices: const <int>{},
          checked: <int>{1, 2},
        ),
        isFalse,
        reason: '本类全已安装时说「已全选」是谎话，且此时勾选框不可点',
      );
    });

    test('选中集含本类之外的下标不影响本类三态判定', () {
      expect(
        dictionaryCategoryCheckState(
          categoryIndices: <int>{1, 2},
          checked: <int>{1, 2, 7, 8},
        ),
        isTrue,
      );
    });
  });

  group('目录勾选列表的真实接线', () {
    RecommendedDictionary rec(String name, DictionaryCategory cat) =>
        RecommendedDictionary(
          name: name,
          url: 'https://example.invalid/$name.zip',
          description: 'desc',
          matchPrefix: name,
          category: cat,
          sizeEstimate: '~1 MB',
          langCode: 'en',
        );

    /// 三条：两条 jaEn、一条 kanji；下标即 catalog 顺序。
    final List<RecommendedDictionary> catalog = <RecommendedDictionary>[
      rec('Alpha', DictionaryCategory.jaEn),
      rec('Beta', DictionaryCategory.jaEn),
      rec('Gamma', DictionaryCategory.kanji),
    ];

    Future<Set<int>> pumpList(
      WidgetTester tester, {
      required Set<int> checked,
      Set<int> installed = const <int>{},
    }) async {
      Set<int> current = Set<int>.of(checked);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) =>
                    SingleChildScrollView(
                  child: DictionaryCatalogSelectionList(
                    workingCatalog: catalog,
                    byCategory: <DictionaryCategory,
                        List<RecommendedDictionary>>{
                      DictionaryCategory.jaEn: <RecommendedDictionary>[
                        catalog[0],
                        catalog[1],
                      ],
                      DictionaryCategory.kanji: <RecommendedDictionary>[
                        catalog[2],
                      ],
                    },
                    recIndex: <RecommendedDictionary, int>{
                      catalog[0]: 0,
                      catalog[1]: 1,
                      catalog[2]: 2,
                    },
                    installedIndices: installed,
                    checked: current,
                    expandedCategories: <DictionaryCategory>{
                      DictionaryCategory.jaEn,
                      DictionaryCategory.kanji,
                    },
                    onCheckedChanged: (Set<int> next) =>
                        setState(() => current = next),
                    onExpansionChanged: (_, __) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return current;
    }

    testWidgets('点「全选」勾上全部未安装项，已安装的不进选中集', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      Set<int> current = <int>{};
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) =>
                    SingleChildScrollView(
                  child: DictionaryCatalogSelectionList(
                    workingCatalog: catalog,
                    byCategory: <DictionaryCategory,
                        List<RecommendedDictionary>>{
                      DictionaryCategory.jaEn: <RecommendedDictionary>[
                        catalog[0],
                        catalog[1],
                      ],
                      DictionaryCategory.kanji: <RecommendedDictionary>[
                        catalog[2],
                      ],
                    },
                    recIndex: <RecommendedDictionary, int>{
                      catalog[0]: 0,
                      catalog[1]: 1,
                      catalog[2]: 2,
                    },
                    installedIndices: const <int>{1},
                    checked: current,
                    expandedCategories: <DictionaryCategory>{
                      DictionaryCategory.jaEn,
                      DictionaryCategory.kanji,
                    },
                    onCheckedChanged: (Set<int> next) =>
                        setState(() => current = next),
                    onExpansionChanged: (_, __) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('dict-download-select-all')),
      );
      await tester.pumpAndSettle();

      expect(
        current,
        <int>{0, 2},
        reason: '已安装的 1 号再下一遍只是白跑一趟下载 + 导入',
      );
      expect(find.text(t.batch_selected_count(n: 2)), findsOneWidget);
    });

    testWidgets('分类三态框勾上 → 只勾本类；再点 → 只清本类', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      Set<int> current = <int>{2};
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) =>
                    SingleChildScrollView(
                  child: DictionaryCatalogSelectionList(
                    workingCatalog: catalog,
                    byCategory: <DictionaryCategory,
                        List<RecommendedDictionary>>{
                      DictionaryCategory.jaEn: <RecommendedDictionary>[
                        catalog[0],
                        catalog[1],
                      ],
                      DictionaryCategory.kanji: <RecommendedDictionary>[
                        catalog[2],
                      ],
                    },
                    recIndex: <RecommendedDictionary, int>{
                      catalog[0]: 0,
                      catalog[1]: 1,
                      catalog[2]: 2,
                    },
                    installedIndices: const <int>{},
                    checked: current,
                    expandedCategories: <DictionaryCategory>{
                      DictionaryCategory.jaEn,
                      DictionaryCategory.kanji,
                    },
                    onCheckedChanged: (Set<int> next) =>
                        setState(() => current = next),
                    onExpansionChanged: (_, __) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(
          const ValueKey<String>('dict-download-category-check-jaEn'),
        ),
      );
      await tester.pumpAndSettle();
      expect(current, <int>{2, 0, 1},
          reason: '本类全选不该动别的分类里已经勾上的 2 号');

      await tester.tap(
        find.byKey(
          const ValueKey<String>('dict-download-category-check-jaEn'),
        ),
      );
      await tester.pumpAndSettle();
      expect(current, <int>{2}, reason: '再点一次只清本类');
    });

    testWidgets('全部已安装时全选/反选禁用，分类三态框也点不动', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpList(
        tester,
        checked: const <int>{},
        installed: const <int>{0, 1, 2},
      );

      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey<String>('dict-download-select-all')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(
                const ValueKey<String>('dict-download-invert-selection'),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(
                const ValueKey<String>('dict-download-category-check-jaEn'),
              ),
            )
            .onChanged,
        isNull,
        reason: '本类全已安装时说「已全选」是谎话，框必须点不动',
      );
    });

    testWidgets('反选只在可勾选域内翻转', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      Set<int> current = <int>{0};
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) =>
                    SingleChildScrollView(
                  child: DictionaryCatalogSelectionList(
                    workingCatalog: catalog,
                    byCategory: <DictionaryCategory,
                        List<RecommendedDictionary>>{
                      DictionaryCategory.jaEn: <RecommendedDictionary>[
                        catalog[0],
                        catalog[1],
                      ],
                      DictionaryCategory.kanji: <RecommendedDictionary>[
                        catalog[2],
                      ],
                    },
                    recIndex: <RecommendedDictionary, int>{
                      catalog[0]: 0,
                      catalog[1]: 1,
                      catalog[2]: 2,
                    },
                    installedIndices: const <int>{2},
                    checked: current,
                    expandedCategories: <DictionaryCategory>{
                      DictionaryCategory.jaEn,
                      DictionaryCategory.kanji,
                    },
                    onCheckedChanged: (Set<int> next) =>
                        setState(() => current = next),
                    onExpansionChanged: (_, __) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('dict-download-invert-selection')),
      );
      await tester.pumpAndSettle();
      expect(current, <int>{1},
          reason: '已安装的 2 号既不在原选中集也不该被反选带出来');
    });
  });
}

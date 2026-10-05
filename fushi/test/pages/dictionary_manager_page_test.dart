import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/dictionary_dialog_page.dart';
import 'package:fushi/src/pages/implementations/dictionary_manager_panels.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// 词典管理页（2026-10 M3 Expressive 重做）的真页面行为测试：不拉 Drift / 引擎，
/// 只把 AppModel 的词典读写面换成内存实现，验证两种布局、批量操作与三条排序
/// 路径（详情按钮 / 键盘 Alt+↑↓ / 拖拽由 FushiReorderableColumn 自己的测试覆盖）。
class _FakeAppModel extends AppModel {
  _FakeAppModel(this.store) : super(testPlatformServices());

  final List<Dictionary> store;
  final List<String> deleted = <String>[];
  int orderWrites = 0;

  List<Dictionary> _sorted() => List<Dictionary>.of(store)
    ..sort((Dictionary a, Dictionary b) => a.order.compareTo(b.order));

  List<Dictionary> _ofType(DictionaryType type) =>
      _sorted().where((Dictionary d) => d.type == type).toList();

  @override
  List<Dictionary> get dictionaries => _sorted();
  @override
  List<Dictionary> get termDictionaries => _ofType(DictionaryType.term);
  @override
  List<Dictionary> get kanjiDictionaries => _ofType(DictionaryType.kanji);
  @override
  List<Dictionary> get freqDictionaries => _ofType(DictionaryType.frequency);
  @override
  List<Dictionary> get pitchDictionaries => _ofType(DictionaryType.pitch);

  @override
  Map<String, DictionaryFormat> get dictionaryFormats =>
      <String, DictionaryFormat>{'yomichan': YomichanFormat.instance};

  @override
  bool get autoUpdateDictionaries => false;
  @override
  DictionaryUpdateInterval get dictionaryUpdateInterval =>
      DictionaryUpdateInterval.weekly;
  @override
  DateTime? get lastDictionaryUpdateAt => null;

  @override
  void toggleDictionaryHidden(Dictionary dictionary) {
    const String code = 'ja';
    dictionary.hiddenLanguages = dictionary.hiddenLanguages.contains(code)
        ? (List<String>.of(dictionary.hiddenLanguages)..remove(code))
        : <String>[...dictionary.hiddenLanguages, code];
  }

  @override
  void cycleDictionaryCollapseState(Dictionary dictionary) {
    const String code = 'ja';
    switch (dictionary.collapseStateFor(JapaneseLanguage.instance)) {
      case DictionaryCollapseState.inherit:
        dictionary.expandedLanguages = <String>[code];
        dictionary.collapsedLanguages = <String>[];
      case DictionaryCollapseState.expanded:
        dictionary.expandedLanguages = <String>[];
        dictionary.collapsedLanguages = <String>[code];
      case DictionaryCollapseState.collapsed:
        dictionary.expandedLanguages = <String>[];
        dictionary.collapsedLanguages = <String>[];
    }
  }

  @override
  void updateDictionaryOrder(List<Dictionary> newDictionaries) {
    orderWrites++;
  }

  @override
  Future<void> deleteDictionary(Dictionary dictionary) async {
    deleted.add(dictionary.name);
    store.removeWhere((Dictionary d) => d.name == dictionary.name);
  }
}

List<Dictionary> _sampleDictionaries() => <Dictionary>[
      Dictionary(
        name: 'JMdict',
        formatKey: 'yomichan',
        order: 0,
        metadata: const <String, String>{'revision': 'jmdict4'},
      ),
      Dictionary(
        name: '三省堂国語辞典 第七版',
        formatKey: 'yomichan',
        order: 1,
        metadata: const <String, String>{'revision': 'v7'},
      ),
      Dictionary(
        name: '大辞林',
        formatKey: 'yomichan',
        order: 2,
        hiddenLanguages: const <String>['ja'],
      ),
      Dictionary(
        name: 'JPDB Frequency',
        formatKey: 'yomichan',
        order: 3,
        type: DictionaryType.frequency,
      ),
    ];

List<String> _termOrder(_FakeAppModel model) =>
    model.termDictionaries.map((Dictionary d) => d.name).toList();

Future<_FakeAppModel> _pumpPage(
  WidgetTester tester, {
  required Size size,
  List<Dictionary>? dictionaries,
  TargetPlatform platform = TargetPlatform.windows,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final _FakeAppModel model =
      _FakeAppModel(dictionaries ?? _sampleDictionaries());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appProvider.overrideWith((ref) => model)],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiFallbackTheme(Brightness.light).copyWith(
            platform: platform,
          ),
          home: const DictionaryDialogPage(),
        ),
      ),
    ),
  );
  await tester.pump();
  await _settle(tester);
  return model;
}

/// 推过转场：AnimatedSwitcher / sheet 的旧子树要在动画结束后的下一帧才摘掉。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('wide window: list plus detail side pane', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model =
        await _pumpPage(tester, size: const Size(1280, 800));

    expect(tester.takeException(), isNull);
    expect(dictionaryManagerUsesSplitLayout(1280), isTrue);
    // 未选中：右侧是概览（四类计数 + 自动更新）。
    expect(find.byKey(const ValueKey<String>('dict-overview')), findsOneWidget);
    expect(find.text('JMdict'), findsOneWidget);
    // 行尾不再堆改名 / 更新 / 语言 / 删除图标：这些只在详情里。
    expect(
        find.byKey(const ValueKey<String>('dict_rename_JMdict')), findsNothing);

    await tester.tap(find.text('三省堂国語辞典 第七版'));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey<String>('dict-detail-三省堂国語辞典 第七版')),
      findsOneWidget,
    );
    expect(find.byType(DictionaryManagerOverview), findsNothing);

    // 详情里的「移到最前」：最终下标语义，写一次顺序。
    await tester
        .tap(find.byKey(const ValueKey<String>('dict-detail-move-top')));
    await _settle(tester);
    expect(model.orderWrites, 1);
    expect(_termOrder(model), <String>['三省堂国語辞典 第七版', 'JMdict', '大辞林']);

    // 详情里的开关：关掉 = 查词时隐藏。
    await tester.tap(
      find.byKey(
        const ValueKey<String>('dict-detail-enabled-三省堂国語辞典 第七版'),
      ),
    );
    await _settle(tester);
    expect(
      model.dictionaries.first.isHidden(JapaneseLanguage.instance),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow window: card list opens a bottom sheet', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model = await _pumpPage(
      tester,
      size: const Size(400, 860),
      platform: TargetPlatform.android,
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(DictionaryManagerOverview), findsNothing);
    // 窄屏也用分段筛选（不再是要点开的下拉框），每段带本数。
    expect(find.text('Term 3'), findsOneWidget);
    expect(find.text('Frequency 1'), findsOneWidget);
    // 主操作一步可达。
    expect(find.text('Import dictionary'), findsWidgets);

    await tester.tap(find.text('JMdict'));
    await _settle(tester);
    expect(find.byType(DictionaryManagerDetail), findsOneWidget);

    // sheet 里下移：页面重排后 sheet 内容跟着刷新（位置文案变成第 2 位）。
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('dict-detail-move-down')),
    );
    await tester
        .tap(find.byKey(const ValueKey<String>('dict-detail-move-down')));
    await _settle(tester);
    expect(_termOrder(model).indexOf('JMdict'), 1);
    expect(find.text('Position 2 / 3'), findsOneWidget);

    // 切到词频：行与计数跟着走。
    Navigator.of(tester.element(find.byType(DictionaryManagerDetail))).pop();
    await _settle(tester);
    await tester.ensureVisible(find.text('Frequency 1'));
    await tester.tap(find.text('Frequency 1'));
    await _settle(tester);
    expect(find.text('JPDB Frequency'), findsOneWidget);
    expect(find.text('JMdict'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('batch selection enables, disables and deletes', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model =
        await _pumpPage(tester, size: const Size(1280, 800));

    await tester
        .tap(find.byKey(const ValueKey<String>('dict-selection-toggle')));
    await _settle(tester);
    expect(
        find.byKey(const ValueKey<String>('dict-batch-bar')), findsOneWidget);

    // 多选态点行 = 勾选，不开详情。
    await tester.tap(find.text('JMdict'));
    await tester.tap(find.text('三省堂国語辞典 第七版'));
    await _settle(tester);
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.byType(DictionaryManagerDetail), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('dict-batch-disable')));
    await _settle(tester);
    final Map<String, bool> hidden = <String, bool>{
      for (final Dictionary d in model.termDictionaries)
        d.name: d.isHidden(JapaneseLanguage.instance),
    };
    expect(hidden, <String, bool>{
      'JMdict': true,
      '三省堂国語辞典 第七版': true,
      '大辞林': true,
    });

    // 全选 + 启用：原本就停用的「大辞林」也一起启用。
    await tester.tap(find.text('All'));
    await _settle(tester);
    expect(find.text('3 selected'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('dict-batch-enable')));
    await _settle(tester);
    expect(
      model.termDictionaries
          .where((Dictionary d) => d.isHidden(JapaneseLanguage.instance)),
      isEmpty,
    );

    // 反选清空后再勾一本删除：一次确认，逐本走 deleteDictionary。
    await tester.tap(find.text('Invert'));
    await _settle(tester);
    await tester.tap(find.text('大辞林'));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey<String>('dict-batch-delete')));
    await _settle(tester);
    expect(find.text('Delete 1 dictionaries?'), findsOneWidget);
    await tester.tap(find.text('DELETE').last);
    await _settle(tester);
    await _settle(tester);
    expect(model.deleted, <String>['大辞林']);
    // 删完退出多选。
    expect(find.byKey(const ValueKey<String>('dict-batch-bar')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Alt+Down moves the focused row and focus follows it', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model =
        await _pumpPage(tester, size: const Size(1280, 800));

    Focus.of(tester.element(find.text('JMdict'))).requestFocus();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();

    // 连按两次：焦点跟着 JMdict 走，所以第二次仍挪的是它。
    expect(_termOrder(model), <String>['三省堂国語辞典 第七版', '大辞林', 'JMdict']);
    expect(model.orderWrites, 2);
    final FocusNode? focused = FocusManager.instance.primaryFocus;
    expect(focused, isNotNull);
    expect(
      find.descendant(
        of: find.byElementPredicate(
          (Element e) => identical(e, focused!.context),
        ),
        matching: find.text('JMdict'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('no dictionaries: empty state puts import and download upfront', (
    WidgetTester tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(400, 860),
      dictionaries: <Dictionary>[],
      platform: TargetPlatform.android,
    );
    expect(find.byType(DictionaryManagerEmptyState), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('dict-empty-import')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('dict-empty-download')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

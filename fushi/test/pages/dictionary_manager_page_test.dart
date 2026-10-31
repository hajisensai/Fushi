import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/dictionary_dialog_page.dart';
import 'package:fushi/src/pages/implementations/dictionary_manager_panels.dart';
import 'package:fushi/utils.dart' show FushiIconButton;
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

  List<Dictionary> _sorted() =>
      List<Dictionary>.of(store)
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
  List<Dictionary> get kanjiSectionDictionaries =>
      kanjiSectionDictionariesOf(_sorted());
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
  Future<void> toggleDictionaryHidden(Dictionary dictionary) async {
    const String code = 'ja';
    dictionary.hiddenLanguages = dictionary.hiddenLanguages.contains(code)
        ? (List<String>.of(dictionary.hiddenLanguages)..remove(code))
        : <String>[...dictionary.hiddenLanguages, code];
  }

  @override
  Future<void> setDictionaryHidden(Dictionary dictionary, bool hidden) async {
    dictionary.hiddenLanguages = <String>[
      for (final String code in dictionary.hiddenLanguages)
        if (code != 'ja') code,
      if (hidden) 'ja',
    ];
  }

  @override
  Future<void> setDictionaryCollapseState(
    Dictionary dictionary,
    DictionaryCollapseState state,
  ) async {
    dictionary.expandedLanguages = state == DictionaryCollapseState.expanded
        ? <String>['ja']
        : <String>[];
    dictionary.collapsedLanguages = state == DictionaryCollapseState.collapsed
        ? <String>['ja']
        : <String>[];
  }

  @override
  Future<void> cycleDictionaryCollapseState(Dictionary dictionary) async {
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
  Future<void> updateDictionaryOrder(List<Dictionary> newDictionaries) async {
    orderWrites++;
    for (final Dictionary updated in newDictionaries) {
      store.firstWhere((Dictionary d) => d.name == updated.name).order =
          updated.order;
    }
  }

  /// 与 `DictionaryRepository.setDictionaryLanguageOverride` 同一语义：换组则
  /// 排到新组最后，本分区按 [sectionAfterLanguageChange] 规范化重编号；同组不动。
  @override
  Future<void> setDictionaryLanguageOverride(
    Dictionary dictionary,
    String? language,
  ) async {
    final Dictionary stored = store.firstWhere(
      (Dictionary d) => d.name == dictionary.name,
    );
    final String? before = dictionaryLanguageGroupOf(stored);
    stored.languageOverride = language;
    if (dictionaryLanguageGroupOf(stored) != before) {
      final List<Dictionary> section = sectionAfterLanguageChange(
        _ofType(stored.type),
        stored,
      );
      for (int i = 0; i < section.length; i++) {
        section[i].order = i;
      }
    }
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
  final _FakeAppModel model = _FakeAppModel(
    dictionaries ?? _sampleDictionaries(),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appProvider.overrideWith((ref) => model)],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiFallbackTheme(
            Brightness.light,
          ).copyWith(platform: platform),
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
    final _FakeAppModel model = await _pumpPage(
      tester,
      size: const Size(1280, 800),
    );

    expect(tester.takeException(), isNull);
    expect(dictionaryManagerUsesSplitLayout(1280), isTrue);
    // 未选中：右侧是概览（四类计数 + 自动更新）。
    expect(find.byKey(const ValueKey<String>('dict-overview')), findsOneWidget);
    expect(find.text('JMdict'), findsOneWidget);
    // 行尾不再堆改名 / 更新 / 语言 / 删除图标：这些只在详情里。
    expect(
      find.byKey(const ValueKey<String>('dict_rename_JMdict')),
      findsNothing,
    );

    await tester.tap(find.text('三省堂国語辞典 第七版'));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey<String>('dict-detail-三省堂国語辞典 第七版')),
      findsOneWidget,
    );
    expect(find.byType(DictionaryManagerOverview), findsNothing);

    // 详情里的「移到最前」：最终下标语义，写一次顺序。
    await tester.tap(
      find.byKey(const ValueKey<String>('dict-detail-move-top')),
    );
    await _settle(tester);
    expect(model.orderWrites, 1);
    expect(_termOrder(model), <String>['三省堂国語辞典 第七版', 'JMdict', '大辞林']);

    // 详情里的开关：关掉 = 查词时隐藏。
    await tester.tap(
      find.byKey(const ValueKey<String>('dict-detail-enabled-三省堂国語辞典 第七版')),
    );
    await _settle(tester);
    expect(
      model.dictionaries.first.isHidden(JapaneseLanguage.instance),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'BUG-3573: kanji section rows of a mixed dictionary offer no collapse '
    'control (it would edit the term part)',
    (WidgetTester tester) async {
      await _pumpPage(
        tester,
        size: const Size(1280, 800),
        dictionaries: <Dictionary>[
          Dictionary(
            name: 'Mixed',
            formatKey: 'yomichan',
            order: 0,
            metadata: const <String, String>{kDictHasKanjiKey: 'true'},
          ),
          Dictionary(
            name: 'KANJIDIC',
            formatKey: 'yomichan',
            order: 1,
            type: DictionaryType.kanji,
          ),
        ],
      );
      const ValueKey<String> collapseKey = ValueKey<String>(
        'dict-detail-collapse-Mixed',
      );
      const ValueKey<String> rowCollapseKey = ValueKey<String>(
        'dict-row-collapse-Mixed',
      );

      // 「术语」分区：混合词典的术语部分照常有折叠控件（行内钮 + 详情分段）。
      expect(find.byKey(rowCollapseKey), findsOneWidget);
      await tester.tap(find.text('Mixed'));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey<String>('dict-detail-Mixed')),
        findsOneWidget,
      );
      expect(find.byKey(collapseKey), findsOneWidget);

      // 「汉字」分区：同一本的汉字部分不给折叠控件（汉字卡不折叠）。切分区时详情
      // 侧板仍停在这本（再点一下行会把详情收起），此时它按「汉字」分区的上下文渲染。
      await tester.tap(find.textContaining(t.dictionary_section_kanji));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey<String>('dict-detail-Mixed')),
        findsOneWidget,
      );
      expect(find.byKey(collapseKey), findsNothing);
      expect(find.byKey(rowCollapseKey), findsNothing, reason: '行内折叠钮与详情同一判据');
      expect(tester.takeException(), isNull);
    },
  );

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
    await tester.tap(
      find.byKey(const ValueKey<String>('dict-detail-move-down')),
    );
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
    final _FakeAppModel model = await _pumpPage(
      tester,
      size: const Size(1280, 800),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('dict-selection-toggle')),
    );
    await _settle(tester);
    expect(
      find.byKey(const ValueKey<String>('dict-batch-bar')),
      findsOneWidget,
    );

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
      model.termDictionaries.where(
        (Dictionary d) => d.isHidden(JapaneseLanguage.instance),
      ),
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
    final _FakeAppModel model = await _pumpPage(
      tester,
      size: const Size(1280, 800),
    );

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
    expect(
      find.byKey(const ValueKey<String>('dict-empty-import')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('dict-empty-download')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  // ── 移到第几位 ─────────────────────────────────────────────────────────

  List<Dictionary> sixTerms() => <Dictionary>[
    for (int i = 0; i < 6; i++)
      Dictionary(name: 'Dict ${i + 1}', formatKey: 'yomichan', order: i),
  ];

  Future<void> openMoveTo(WidgetTester tester, String name) async {
    await tester.tap(find.text(name));
    await _settle(tester);
    final Finder row = find.byKey(
      const ValueKey<String>('dict-detail-move-to'),
    );
    await tester.ensureVisible(row);
    await tester.tap(row);
    await _settle(tester);
    expect(find.byType(DictionaryPositionDialog), findsOneWidget);
  }

  Finder positionField() => find.descendant(
    of: find.byKey(const ValueKey<String>('dict-position-field')),
    matching: find.byType(EditableText),
  );

  test(
    'parseDictionaryPosition clamps out of range and rejects non-numbers',
    () {
      expect(parseDictionaryPosition('5', 6), 5);
      expect(parseDictionaryPosition(' 0 ', 6), 1);
      expect(parseDictionaryPosition('-3', 6), 1);
      expect(parseDictionaryPosition('99', 6), 6);
      expect(parseDictionaryPosition('', 6), isNull);
      expect(parseDictionaryPosition('abc', 6), isNull);
    },
  );

  testWidgets('move the first dictionary to position 5; focus follows it', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model = await _pumpPage(
      tester,
      size: const Size(1280, 800),
      dictionaries: sixTerms(),
    );
    await openMoveTo(tester, 'Dict 1');

    await tester.enterText(positionField(), '5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);

    expect(find.byType(DictionaryPositionDialog), findsNothing);
    expect(model.orderWrites, 1);
    expect(_termOrder(model), <String>[
      'Dict 2',
      'Dict 3',
      'Dict 4',
      'Dict 5',
      'Dict 1',
      'Dict 6',
    ]);
    // 详情跟着刷新，焦点落在移动后的那一行。
    expect(find.text('Position 5 / 6'), findsOneWidget);
    final FocusNode? focused = FocusManager.instance.primaryFocus;
    expect(
      find.descendant(
        of: find.byElementPredicate(
          (Element e) => identical(e, focused!.context),
        ),
        matching: find.text('Dict 1'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('arrow keys step the position inside the field', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model = await _pumpPage(
      tester,
      size: const Size(1280, 800),
      dictionaries: sixTerms(),
    );
    await openMoveTo(tester, 'Dict 1');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(tester.widget<EditableText>(positionField()).controller.text, '3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    expect(_termOrder(model).indexOf('Dict 1'), 2);
  });

  testWidgets('out-of-range input is clamped; non-numbers are rejected', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model = await _pumpPage(
      tester,
      size: const Size(1280, 800),
      dictionaries: sixTerms(),
    );
    await openMoveTo(tester, 'Dict 2');

    // 非数字：确认置灰、回车不提交。
    await tester.enterText(positionField(), 'abc');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    expect(find.byType(DictionaryPositionDialog), findsOneWidget);
    expect(model.orderWrites, 0);

    // 越界：提示夹到最后一位，提交即移到末尾。
    await tester.enterText(positionField(), '99');
    await _settle(tester);
    expect(find.text('Out of range — will move to position 6'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    expect(_termOrder(model).last, 'Dict 2');
    expect(model.orderWrites, 1);
  });

  testWidgets('cancel leaves the order unchanged', (WidgetTester tester) async {
    final _FakeAppModel model = await _pumpPage(
      tester,
      size: const Size(1280, 800),
      dictionaries: sixTerms(),
    );
    await openMoveTo(tester, 'Dict 1');
    await tester.enterText(positionField(), '4');
    await tester.tap(find.text('CANCEL'));
    await _settle(tester);
    expect(find.byType(DictionaryPositionDialog), findsNothing);
    expect(model.orderWrites, 0);
    expect(_termOrder(model).first, 'Dict 1');
  });

  testWidgets('batch bar offers move-to only with exactly one selected', (
    WidgetTester tester,
  ) async {
    final _FakeAppModel model = await _pumpPage(
      tester,
      size: const Size(1280, 800),
      dictionaries: sixTerms(),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('dict-selection-toggle')),
    );
    await _settle(tester);
    FushiIconButton moveButton() => tester.widget<FushiIconButton>(
      find.byKey(const ValueKey<String>('dict-batch-move-to')),
    );
    expect(moveButton().enabled, isFalse);

    await tester.tap(find.text('Dict 6'));
    await _settle(tester);
    expect(moveButton().enabled, isTrue);
    await tester.tap(find.text('Dict 1'));
    await _settle(tester);
    expect(moveButton().enabled, isFalse);
    await tester.tap(find.text('Dict 1'));
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey<String>('dict-batch-move-to')));
    await _settle(tester);
    await tester.enterText(positionField(), '1');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    expect(_termOrder(model).first, 'Dict 6');
  });

  group('language groups (D_Nz5R4vSH)', () {
    List<Dictionary> mixedLanguages() => <Dictionary>[
      Dictionary(
        name: 'JMdict',
        formatKey: 'yomichan',
        order: 0,
        metadata: const <String, String>{'sourceLanguage': 'ja'},
      ),
      Dictionary(
        name: 'OALDPE',
        formatKey: 'yomichan',
        order: 1,
        metadata: const <String, String>{'sourceLanguage': 'en'},
      ),
      Dictionary(
        name: '大辞林',
        formatKey: 'yomichan',
        order: 2,
        metadata: const <String, String>{'sourceLanguage': 'ja'},
      ),
      Dictionary(name: 'local-pack', formatKey: 'yomichan', order: 3),
    ];

    testWidgets('one header per language, unlabelled group last', (
      WidgetTester tester,
    ) async {
      await _pumpPage(
        tester,
        size: const Size(1280, 800),
        dictionaries: mixedLanguages(),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('日本語 (ja) · 2'), findsOneWidget);
      expect(find.text('English (en) · 1'), findsOneWidget);
      expect(find.text('Language not set · 1'), findsOneWidget);
      final double ja = tester.getTopLeft(find.text('日本語 (ja) · 2')).dy;
      final double en = tester.getTopLeft(find.text('English (en) · 1')).dy;
      final double none = tester
          .getTopLeft(find.text('Language not set · 1'))
          .dy;
      expect(ja < en && en < none, isTrue);
      // 大辞林 紧跟 JMdict 在日语组里：组内序号 2，而不是全局第 3。
      expect(tester.getTopLeft(find.text('大辞林')).dy, lessThan(en));
    });

    testWidgets('a single language group shows no group header', (
      WidgetTester tester,
    ) async {
      // 全部未标注语言（一组）。
      await _pumpPage(tester, size: const Size(1280, 800));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Language not set'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('dict-language-group-')),
        findsNothing,
      );
      // 全部日语（也是一组）。
      await _pumpPage(
        tester,
        size: const Size(1280, 800),
        dictionaries: <Dictionary>[
          for (final Dictionary d in mixedLanguages())
            if (d.name != 'OALDPE' && d.name != 'local-pack') d,
        ],
      );
      expect(find.textContaining('日本語 (ja)'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('dict-language-group-ja')),
        findsNothing,
      );
      expect(find.text('JMdict'), findsOneWidget);
      expect(find.text('大辞林'), findsOneWidget);
    });

    testWidgets('Alt+Down only moves inside the language group', (
      WidgetTester tester,
    ) async {
      final _FakeAppModel model = await _pumpPage(
        tester,
        size: const Size(1280, 800),
        dictionaries: mixedLanguages(),
      );
      Focus.of(tester.element(find.text('JMdict'))).requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      // 已是日语组最后一本：再按不越过英语组，不写顺序。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(model.orderWrites, 1);
      // 日语组内换位；写回的是规范顺序（各组首尾相接），英语 / 未标注组的组内
      // 顺序不动——显示顺序 == 查词顺序。
      expect(_termOrder(model), <String>[
        '大辞林',
        'JMdict',
        'OALDPE',
        'local-pack',
      ]);
    });

    testWidgets('a stale group (membership changed elsewhere) still reorders '
        'from the latest partition, no exception', (WidgetTester tester) async {
      final _FakeAppModel model = await _pumpPage(
        tester,
        size: const Size(1280, 800),
        dictionaries: mixedLanguages(),
      );
      // 列表按 [JMdict, 大辞林] 渲染了日语组；随后别处（ctl 路由 / 另一窗口）把
      // OALDPE 改成日语，页面还没重建，手里仍是旧组。
      model.store
              .firstWhere((Dictionary d) => d.name == 'OALDPE')
              .languageOverride =
          'ja';
      Focus.of(tester.element(find.text('JMdict'))).requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(model.orderWrites, 1);
      // 最新日语组是 [JMdict, OALDPE, 大辞林]：JMdict 下移一位。
      expect(_termOrder(model), <String>[
        'OALDPE',
        'JMdict',
        '大辞林',
        'local-pack',
      ]);
    });

    testWidgets('changing a dictionary language moves it to the end of the '
        'new group', (WidgetTester tester) async {
      final _FakeAppModel model = await _pumpPage(
        tester,
        size: const Size(1280, 800),
        dictionaries: mixedLanguages(),
      );
      await tester.tap(find.text('JMdict'));
      await _settle(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('dict-detail-language-JMdict')),
      );
      await _settle(tester);
      await tester.tap(find.text('English (en)').last);
      await _settle(tester);

      expect(find.text('English (en) · 2'), findsOneWidget);
      expect(find.text('日本語 (ja) · 1'), findsOneWidget);
      final List<String> en = <String>[
        for (final Dictionary d in model.termDictionaries)
          if (dictionaryLanguageGroupOf(d) == 'en') d.name,
      ];
      expect(en, <String>['OALDPE', 'JMdict']);
      // 按行尾开关定位列表行（右侧详情里也有一个 JMdict 标题）。
      expect(
        tester
            .getTopLeft(
              find.byKey(const ValueKey<String>('dict-row-switch-JMdict')),
            )
            .dy,
        greaterThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey<String>('dict-row-switch-OALDPE')),
              )
              .dy,
        ),
      );
    });
  });
}

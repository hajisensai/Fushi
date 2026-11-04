// 复习卡片浏览页：搜索（语法 / 按字段）、多选 + 批量 + 撤销、预览（窄屏预览页 / 宽屏分栏 +
// 键盘），MD3 与 Apple 两套设计系统。
//
// 内存库 + 确定性假排程内核；卡面经 srsCardFaceBuilderProvider 换成纯文本实现。
// 数据库读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_views.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_list_page.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart'
    show FushiCheckbox, FushiFilledButton;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_browse.dart' show srsDeckQuery;
import 'package:fushi_engine/srs/srs_browse_ops.dart'
    show srsBatchMoveCards, srsBatchSetDue, srsBatchSetSuspended;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart'
    show
        FushiFsrs,
        SrsEntityKind,
        SrsFieldKeys,
        SrsNoteView,
        SrsCustomStudyMode,
        SrsCustomStudyState,
        SrsDeckTree,
        SrsSourceRef,
        SrsTemplateDef,
        kFushiFsrsLibEnv;
import 'package:material_ui/material_ui.dart';

import 'srs_test_support.dart';

/// 每个测试一个可拨的时钟：笔记的新建时间确定、互不相同（默认排序按它）。
SrsTestClock _clock = SrsTestClock();

Future<SrsDbStore> _openStore(WidgetTester tester) async {
  _clock = SrsTestClock();
  final (FushiDatabase db, SrsDbStore store) = (await tester.runAsync(
    () => openSrsTestStore(clock: _clock),
  ))!;
  addTearDown(() => tester.runAsync(db.close));
  return store;
}

Future<String> _add(
  WidgetTester tester,
  SrsDbStore store,
  String expression,
  String definition,
) async {
  final String id = (await tester.runAsync(
    () => store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): expression,
        srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): definition,
      },
    ),
  ))!;
  _clock.advance(const Duration(seconds: 1));
  return id;
}

Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 选列偏好存在内存里的 AppModel（测试没有装配 prefs）。
class _ColumnsPrefAppModel extends SrsTestAppModel {
  String columns = '';

  @override
  String get srsBrowseTableColumns => columns;

  @override
  Future<void> setSrsBrowseTableColumns(String value) async => columns = value;
}

/// 加一条带出处的 Lapis 笔记。
Future<String> _addSourced(
  WidgetTester tester,
  SrsDbStore store,
  String expression,
  String definition,
  SrsSourceRef? source, {
  String? deckId,
}) async {
  final String id = (await tester.runAsync(
    () => store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      deckId: deckId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): expression,
        srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): definition,
      },
      source: source,
    ),
  ))!;
  _clock.advance(const Duration(seconds: 1));
  return id;
}

SrsSourceRef _book(String key, String title) => SrsSourceRef.book(
  bookKey: key,
  sectionIndex: 0,
  charStart: 0,
  title: title,
);

/// 双击（两次点击之间留出双击识别的间隔）。
Future<void> _doubleTap(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(f);
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _pump(
  WidgetTester tester, {
  required SrsDbStore store,
  bool apple = false,
  Size size = const Size(500, 900),
  Widget page = const SrsBrowsePage(),
  AppModel? app,
  List<Override> overrides = const <Override>[],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel appModel = app ?? SrsTestAppModel();
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => appModel),
        srsStoreProvider.overrideWith((Ref ref) async => store),
        ...overrides,
        srsCardFaceBuilderProvider.overrideWithValue(
          (BuildContext context, SrsCardFace face) =>
              SrsPlainCardFace(face: face),
        ),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            designSystem: apple
                ? FushiDesignSystem.cupertino
                : FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: apple,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: page,
        ),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

Future<List<SrsCardCacheRow>> _cards(
  WidgetTester tester,
  SrsDbStore store,
) async => (await tester.runAsync(store.allCardRows))!;

Finder _row(String text) => find.descendant(
  of: find.byWidgetPredicate(
    (Widget w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('srs-browse-row-'),
  ),
  matching: find.text(text),
);

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(
    find.descendant(
      of: find.byKey(const ValueKey<String>('srs-browse-search')),
      matching: find.byType(EditableText),
    ),
    query,
  );
  await tester.pump(const Duration(milliseconds: 250));
  await _settle(tester, rounds: 3);
}

/// 在 [deckId] 牌组里加一条 Lapis 笔记（null = 默认牌组）。
Future<String> _addIn(
  WidgetTester tester,
  SrsDbStore store,
  String expression, {
  String? deckId,
}) async {
  final String id = (await tester.runAsync(
    () => store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      deckId: deckId,
      fieldsById: <String, String>{
        srsLapisFieldId(kSrsTestProfile, 'Expression'): expression,
        srsLapisFieldId(kSrsTestProfile, 'MainDefinition'): 'x',
      },
    ),
  ))!;
  _clock.advance(const Duration(seconds: 1));
  return id;
}

void _expectNativeSearch() => expect(
  FushiFsrs.isAvailable,
  isTrue,
  reason:
      'fushi_fsrs native library not loadable: build it with '
      'native/fushi_fsrs/build_*.{ps1,sh} and set $kFushiFsrsLibEnv',
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('[$ds] 搜索：字段限定语法、按字段的关键字搜索、语法错误给出提示', (
      WidgetTester tester,
    ) async {
      // 搜索求值只有 Rust 实现（native/fushi_fsrs/src/search.rs）：库缺失直接判红，不 skip。
      expect(
        FushiFsrs.isAvailable,
        isTrue,
        reason:
            'fushi_fsrs native library not loadable: build it with '
            'native/fushi_fsrs/build_*.{ps1,sh} and set $kFushiFsrsLibEnv',
      );
      final SrsDbStore store = await _openStore(tester);
      await _add(tester, store, '食べる', 'to eat');
      await _add(tester, store, '飲む', 'to drink');
      await _pump(tester, store: store, apple: apple);
      expect(_row('食べる'), findsOneWidget);
      expect(_row('飲む'), findsOneWidget);

      await _search(tester, 'MainDefinition:*drink*');
      expect(_row('飲む'), findsOneWidget);
      expect(_row('食べる'), findsNothing);

      await _search(tester, '(broken');
      expect(
        find.byKey(const ValueKey<String>('srs-browse-search-error')),
        findsOneWidget,
      );

      // 不记语法：搜索范围选 MainDefinition，再输关键字。
      await tester.tap(find.byKey(const ValueKey<String>('srs-browse-field')));
      await _settle(tester, rounds: 4);
      await tester.tap(find.text('MainDefinition').last);
      await _settle(tester, rounds: 4);
      await _search(tester, 'EAT');
      expect(_row('食べる'), findsOneWidget);
      expect(_row('飲む'), findsNothing);
      await _unmount(tester);
    });

    testWidgets('[$ds] 多选（长按）→ 批量暂停 → 撤销', (WidgetTester tester) async {
      final SrsDbStore store = await _openStore(tester);
      await _add(tester, store, '食べる', 'to eat');
      await _add(tester, store, '飲む', 'to drink');
      await _add(tester, store, '走る', 'to run');
      await _pump(tester, store: store, apple: apple);

      await tester.longPress(_row('食べる'));
      await _settle(tester, rounds: 3);
      await tester.tap(_row('飲む'));
      await _settle(tester, rounds: 3);
      expect(find.text(t.srs_browse_selected_count(n: 2)), findsWidgets);

      await tester.tap(
        find.byKey(const ValueKey<String>('srs_browse_batch')).first,
      );
      await _settle(tester, rounds: 4);
      await tester.tap(find.text(t.srs_browse_toggle_suspend).last);
      await _settle(tester);
      final List<SrsCardCacheRow> after = await _cards(tester, store);
      expect(after.where((SrsCardCacheRow c) => c.suspended), hasLength(2));

      await tester.tap(
        find.byKey(const ValueKey<String>('srs_browse_undo')).first,
      );
      await _settle(tester);
      final List<SrsCardCacheRow> undone = await _cards(tester, store);
      expect(undone.where((SrsCardCacheRow c) => c.suspended), isEmpty);
      await _unmount(tester);
    });
    testWidgets('[$ds] 牌组菜单「浏览此牌组的卡片」：宽屏「⋯」与窄屏长按（含默认牌组）带 deck: 查询打开浏览页', (
      WidgetTester tester,
    ) async {
      _expectNativeSearch();
      final SrsDbStore store = await _openStore(tester);
      final String jp = (await tester.runAsync(
        () => store.ensureDeckPath('JP'),
      ))!;
      final String n3 = (await tester.runAsync(
        () => store.ensureDeckPath('JP::N3'),
      ))!;
      await _addIn(tester, store, '食べる');
      await _addIn(tester, store, '飲む', deckId: jp);
      await _addIn(tester, store, '走る', deckId: n3);

      // 宽屏：行尾「⋯」。
      await _pump(
        tester,
        store: store,
        apple: apple,
        size: const Size(1100, 900),
        page: const SrsDeckListPage(),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey<String>('srs-deck-$jp')),
          // 行尾「⋯」（Apple 版不挂 Tooltip，按组件类型找）。
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w.runtimeType.toString().startsWith('FushiPopupMenuButton'),
          ),
        ),
      );
      await _settle(tester, rounds: 4);
      expect(find.text(t.srs_deck_browse_cards), findsOneWidget);
      // Apple 菜单按 value / child 重建菜单项（不保留 key），按文案点。
      await tester.tap(find.text(t.srs_deck_browse_cards));
      await _settle(tester);
      final SrsBrowsePage page = tester.widget<SrsBrowsePage>(
        find.byType(SrsBrowsePage),
      );
      expect(page.initialQuery, srsDeckQuery('JP'));
      expect(page.initialQuery, 'deck:"JP"');
      // 含子牌组（Anki deck: 语义），不含默认牌组的卡。
      expect(_row('飲む'), findsOneWidget);
      expect(_row('走る'), findsOneWidget);
      expect(_row('食べる'), findsNothing);
      await _unmount(tester);

      // 窄屏：长按默认牌组行弹同一份菜单，默认牌组同样可用。
      await _pump(
        tester,
        store: store,
        apple: apple,
        size: const Size(412, 915),
        page: const SrsDeckListPage(),
      );
      await tester.longPress(find.text('Default'));
      await _settle(tester, rounds: 4);
      expect(find.text(t.srs_deck_browse_cards), findsOneWidget);
      await tester.tap(find.text(t.srs_deck_browse_cards));
      await _settle(tester);
      expect(
        tester.widget<SrsBrowsePage>(find.byType(SrsBrowsePage)).initialQuery,
        'deck:"Default"',
      );
      expect(_row('食べる'), findsOneWidget);
      expect(_row('飲む'), findsNothing);
      await _unmount(tester);
    });
  }

  test('srsDeckQuery：通配符 / 反斜杠 / 引号转义成字面量，层级 :: 原样保留', () {
    expect(srsDeckQuery('A::B c'), 'deck:"A::B c"');
    expect(srsDeckQuery(r'x_y*z"q\w'), r'deck:"x\_y\*z\"q\\w"');
  });

  testWidgets('BUG-3617：牌组已不存在的卡在浏览页归默认牌组，deck:Default 筛得到', (
    WidgetTester tester,
  ) async {
    _expectNativeSearch();
    final SrsDbStore store = await _openStore(tester);
    final String jp = (await tester.runAsync(
      () => store.ensureDeckPath('JP'),
    ))!;
    await _addIn(tester, store, '食べる');
    final String orphan = await _addIn(tester, store, '飲む');
    await _addIn(tester, store, '走る', deckId: jp);
    // 卡片指向一个本机不存在的牌组（别的设备删了牌组 / 移动先于牌组同步到）。
    final List<String> orphanCards = <String>[
      for (final SrsCardCacheRow c in await _cards(tester, store))
        if (c.noteId == orphan) c.id,
    ];
    await tester.runAsync(
      () => srsBatchMoveCards(store, orphanCards, 'deck-gone-elsewhere'),
    );
    expect(
      (await _cards(tester, store))
          .where((SrsCardCacheRow c) => c.noteId == orphan)
          .map((SrsCardCacheRow c) => c.deckId),
      everyElement('deck-gone-elsewhere'),
    );

    await _pump(
      tester,
      store: store,
      page: SrsBrowsePage(initialQuery: srsDeckQuery('Default')),
    );
    expect(_row('食べる'), findsOneWidget);
    expect(_row('飲む'), findsOneWidget, reason: '孤儿卡归默认牌组');
    expect(_row('走る'), findsNothing);
    expect(
      find.descendant(
        of: find.byWidgetPredicate(
          (Widget w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('srs-browse-row-'),
        ),
        matching: find.textContaining('Default'),
      ),
      findsNWidgets(2),
      reason: '孤儿卡的牌组名显示为默认牌组（以前是空）',
    );
    await _unmount(tester);
  });

  testWidgets('批量删除需要确认；全选 + 改旗标', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _add(tester, store, '食べる', 'to eat');
    await _add(tester, store, '飲む', 'to drink');
    await _pump(tester, store: store);

    await tester.tap(find.byKey(const ValueKey<String>('srs_browse_select')));
    await _settle(tester, rounds: 3);
    await tester.tap(
      find.byKey(const ValueKey<String>('srs_browse_select_all')),
    );
    await _settle(tester, rounds: 3);
    await tester.tap(find.byKey(const ValueKey<String>('srs_browse_batch')));
    await _settle(tester, rounds: 4);
    await tester.tap(find.text(t.srs_card_flag).last);
    await _settle(tester, rounds: 4);
    await tester.tap(find.text(t.srs_flag_blue).last);
    await _settle(tester);
    expect(
      (await _cards(tester, store)).every((SrsCardCacheRow c) => c.flag == 4),
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey<String>('srs_browse_batch')));
    await _settle(tester, rounds: 4);
    await tester.tap(find.text(t.srs_browse_delete_notes).last);
    await _settle(tester, rounds: 4);
    expect(find.text(t.srs_browse_delete_confirm(n: 2)), findsOneWidget);
    await tester.tap(find.text(t.cancel).last);
    await _settle(tester, rounds: 4);
    expect((await tester.runAsync(store.listNotes))!, hasLength(2));

    await tester.tap(find.byKey(const ValueKey<String>('srs_browse_batch')));
    await _settle(tester, rounds: 4);
    await tester.tap(find.text(t.srs_browse_delete_notes).last);
    await _settle(tester, rounds: 4);
    await tester.tap(find.text(t.srs_note_delete).last);
    await _settle(tester);
    expect((await tester.runAsync(store.listNotes))!, isEmpty);
    await _unmount(tester);
  });

  testWidgets('窄屏：点一行进预览页，翻面、下一张', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _add(tester, store, '食べる', 'to eat');
    await _add(tester, store, '飲む', 'to drink');
    await _pump(tester, store: store);
    // 默认按新建时间降序：飲む 在前。
    await tester.tap(_row('飲む'));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey<String>('srs-face-question')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('srs-preview-flip')));
    await _settle(tester, rounds: 4);
    expect(
      find.byKey(const ValueKey<String>('srs-face-answer')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('srs-preview-next')));
    await _settle(tester);
    final Text question = tester.widget<Text>(
      find.byKey(const ValueKey<String>('srs-face-question')),
    );
    expect(question.data, contains('食べる'));
    await _unmount(tester);
  });

  testWidgets('宽屏：列表 + 预览分栏；↓ 换卡、Enter 翻面、Ctrl+A 全选、Esc 取消', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _openStore(tester);
    await _add(tester, store, '食べる', 'to eat');
    await _add(tester, store, '飲む', 'to drink');
    await _pump(tester, store: store, size: const Size(1300, 900));
    expect(
      find.byKey(const ValueKey<String>('srs-browse-preview')),
      findsOneWidget,
    );
    String question() => tester
        .widget<Text>(find.byKey(const ValueKey<String>('srs-face-question')))
        .data!;
    expect(question(), contains('飲む'));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _settle(tester);
    expect(question(), contains('食べる'));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester, rounds: 4);
    expect(
      find.byKey(const ValueKey<String>('srs-face-answer')),
      findsOneWidget,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _settle(tester, rounds: 3);
    expect(find.text(t.srs_browse_selected_count(n: 2)), findsWidgets);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester, rounds: 3);
    expect(find.text(t.srs_browse_selected_count(n: 2)), findsNothing);
    await _unmount(tester);
  });

  testWidgets('排序：切到「排序字段」升序，再切升降序', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _add(tester, store, 'b', 'x');
    await _add(tester, store, 'a', 'y');
    await _add(tester, store, 'c', 'z');
    await _pump(tester, store: store);
    double y(String text) => tester.getTopLeft(_row(text)).dy;

    await tester.tap(find.byKey(const ValueKey<String>('srs-browse-sort')));
    await _settle(tester, rounds: 4);
    await tester.tap(find.text(t.srs_browse_sort_sort_field).last);
    await _settle(tester, rounds: 4);
    // 默认降序。
    expect(y('c') < y('b') && y('b') < y('a'), isTrue);
    await tester.tap(
      find.byKey(const ValueKey<String>('srs-browse-direction')),
    );
    await _settle(tester, rounds: 4);
    expect(y('a') < y('b') && y('b') < y('c'), isTrue);
    await _unmount(tester);
  });

  testWidgets('更改笔记类型：没有接线时不出现；接上后传入所选笔记', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    final String n1 = await _add(tester, store, '食べる', 'to eat');
    List<String>? got;
    await _pump(
      tester,
      store: store,
      page: SrsBrowsePage(
        onChangeNoteType: (BuildContext context, List<String> ids) async {
          got = ids;
        },
      ),
    );
    await tester.longPress(_row('食べる'));
    await _settle(tester, rounds: 3);
    await tester.tap(find.byKey(const ValueKey<String>('srs_browse_batch')));
    await _settle(tester, rounds: 4);
    await tester.tap(find.text(t.srs_browse_change_note_type).last);
    await _settle(tester);
    expect(got, <String>[n1]);
    await _unmount(tester);

    await _pump(tester, store: store);
    await tester.longPress(_row('食べる'));
    await _settle(tester, rounds: 3);
    await tester.tap(find.byKey(const ValueKey<String>('srs_browse_batch')));
    await _settle(tester, rounds: 4);
    expect(find.text(t.srs_browse_change_note_type), findsNothing);
    await _unmount(tester);
  });

  testWidgets('积木：回车把草稿拆成积木，草稿空时退格删掉最后一块', (WidgetTester tester) async {
    _expectNativeSearch();
    final SrsDbStore store = await _openStore(tester);
    await _add(tester, store, '食べる', 'to eat');
    await _add(tester, store, '飲む', 'to drink');
    await _pump(tester, store: store);

    await _search(tester, 'MainDefinition:*eat*');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester, rounds: 4);
    expect(
      find.byKey(const ValueKey<String>('srs-browse-chip-0')),
      findsOneWidget,
    );
    final EditableText editor = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('srs-browse-search')),
        matching: find.byType(EditableText),
      ),
    );
    expect(editor.controller.text, isEmpty);
    expect(_row('食べる'), findsOneWidget);
    expect(_row('飲む'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await _settle(tester, rounds: 4);
    expect(
      find.byKey(const ValueKey<String>('srs-browse-chip-0')),
      findsNothing,
    );
    expect(_row('飲む'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('快捷视图：带计数，点一下套用、再点撤掉', (WidgetTester tester) async {
    _expectNativeSearch();
    final SrsDbStore store = await _openStore(tester);
    await _add(tester, store, '食べる', 'to eat');
    await _add(tester, store, '飲む', 'to drink');
    final String suspended = (await _cards(
      tester,
      store,
    )).firstWhere((SrsCardCacheRow c) => true).id;
    await tester.runAsync(
      () => srsBatchSetSuspended(store, <String>[suspended], suspended: true),
    );
    await _pump(tester, store: store);
    final Finder chip = find.byKey(
      const ValueKey<String>('srs-browse-view-suspended'),
    );
    expect(
      find.descendant(
        of: chip,
        matching: find.text('${t.srs_browse_quick_suspended} · 1'),
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(chip);
    await tester.pump();
    await tester.tap(chip);
    await _settle(tester, rounds: 6);
    expect(
      find.byKey(const ValueKey<String>('srs-browse-chip-0')),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value == 'srs-browse-row-$suspended',
      ),
      findsOneWidget,
    );
    expect(_row('食べる').evaluate().length + _row('飲む').evaluate().length, 1);
    await tester.ensureVisible(chip);
    await tester.pump();
    await tester.tap(chip);
    await _settle(tester, rounds: 6);
    expect(
      find.byKey(const ValueKey<String>('srs-browse-chip-0')),
      findsNothing,
    );
    expect(_row('食べる'), findsOneWidget);
    expect(_row('飲む'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('宽屏检查器：编辑页签停笔自动保存（可撤销），历史页签', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    final String noteId = await _add(tester, store, '食べる', 'to eat');
    await _pump(tester, store: store, size: const Size(1300, 900));

    await tester.tap(
      find.byKey(const ValueKey<String>('srs-browse-tab-history')),
    );
    await _settle(tester, rounds: 6);
    expect(
      find.byKey(const ValueKey<String>('srs-browse-history')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey<String>('srs-browse-tab-edit')));
    await _settle(tester, rounds: 6);
    final Finder field = find.descendant(
      of: find.byKey(const ValueKey<String>('srs-browse-field-MainDefinition')),
      matching: find.byType(EditableText),
    );
    expect(field, findsOneWidget);
    // 字段编辑器是富文本：存进去的是 HTML（空格会变 &nbsp;），这里用不带空格的值。
    await tester.enterText(field, 'consume');
    await tester.pump(const Duration(milliseconds: 900));
    await _settle(tester);
    final SrsNoteView? saved = await tester.runAsync<SrsNoteView?>(
      () => store.note(noteId),
    );
    expect(
      saved!.field(srsLapisFieldId(kSrsTestProfile, 'MainDefinition')),
      'consume',
    );

    // 编辑框持焦时 Ctrl+Z 归文本框：点撤销按钮。
    await tester.tap(
      find.byKey(const ValueKey<String>('srs_browse_undo')).first,
    );
    await _settle(tester);
    final SrsNoteView? undone = await tester.runAsync<SrsNoteView?>(
      () => store.note(noteId),
    );
    expect(
      undone!.field(srsLapisFieldId(kSrsTestProfile, 'MainDefinition')),
      'to eat',
    );
    await _unmount(tester);
  });

  testWidgets('健康条：按笔记计数（多卡笔记算一条），「查看」只把条件套成积木、不删任何笔记', (
    WidgetTester tester,
  ) async {
    _expectNativeSearch();
    final SrsDbStore store = await _openStore(tester);
    // Lapis 加两个只用释义字段的模板：主字段为空的笔记照样生成 2 张卡——卡片模式数出来不是 1。
    final String def = srsLapisFieldId(kSrsTestProfile, 'MainDefinition');
    await tester.runAsync(
      () => store.editFields(
        SrsEntityKind.noteType,
        store.lapisNoteTypeId,
        <String, Object?>{
          for (final int i in <int>[1, 2])
            SrsFieldKeys.templateDef('browse-def-$i'): SrsTemplateDef(
              id: 'browse-def-$i',
              name: 'Def $i',
              ord: 10 + i,
              front: '{{fld:$def}}',
              back: '{{fld:$def}}',
            ).toValue(),
        },
      ),
    );
    final String keep = await _add(tester, store, '食べる', 'to eat');
    final String empty = await _add(tester, store, '<br>', 'blank front');
    expect(
      (await _cards(
        tester,
        store,
      )).where((SrsCardCacheRow c) => c.noteId == empty).length,
      greaterThanOrEqualTo(2),
      reason: 'precondition: the empty-front note has several cards',
    );
    await _pump(tester, store: store, size: const Size(1300, 900));

    // 列表是卡片模式，健康条照样按笔记数：1 条，不是卡片数。
    expect(find.text(t.srs_browse_health_empty_notes(n: 1)), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('srs-browse-health-empty-fix')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('srs-browse-chip-0')),
      findsNothing,
    );
    // 卡片模式：「食べる」这条笔记有 3 张卡（Lapis 本身 + 两个释义模板），各占一行。
    expect(_row('食べる'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey<String>('srs-browse-health-empty-view')),
    );
    await _settle(tester, rounds: 4);
    // 套成一块积木（用户可以自己删掉），列表只剩主字段为空的那条。
    expect(
      find.byKey(const ValueKey<String>('srs-browse-chip-0')),
      findsOneWidget,
    );
    expect(_row('食べる'), findsNothing);
    // 没有任何写入：两条笔记都还在。
    expect(
      <String>{
        for (final SrsNoteCacheRow n in (await tester.runAsync(
          store.listNotes,
        ))!)
          n.id,
      },
      <String>{keep, empty},
    );
    await _unmount(tester);
  });

  testWidgets('宽屏检查器：标签与字段同一套保存（失焦落库、换卡前落库）', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    final String a = await _add(tester, store, '食べる', 'to eat');
    final String b = await _add(tester, store, '飲む', 'to drink');
    await _pump(tester, store: store, size: const Size(1300, 900));
    await tester.tap(find.byKey(const ValueKey<String>('srs-browse-tab-edit')));
    await _settle(tester, rounds: 6);

    Finder tagsBox() => find.descendant(
      of: find.byKey(const ValueKey<String>('srs-browse-edit-tags')),
      matching: find.byType(EditableText),
    );
    Future<Map<String, List<String>>> tagsByNote() async =>
        <String, List<String>>{
          for (final String id in <String>[a, b])
            id: (await tester.runAsync<SrsNoteView?>(
              () => store.note(id),
            ))!.tags,
        };

    // 标签框在字段列表末尾（列表懒构建）：先滚到它。
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey<String>('srs-browse-edit-tags')),
      200,
      // 字段编辑器里还有自己的滚动区：取最外层（列表本身）那个。
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey<String>('srs-browse-edit-fields')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump();

    // 失焦：改完标签不按回车，焦点离开输入框。
    await tester.enterText(tagsBox(), 'alpha beta');
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await _settle(tester);
    final Map<String, List<String>> afterBlur = await tagsByNote();
    final String edited = afterBlur[a]!.isNotEmpty ? a : b;
    final String other = edited == a ? b : a;
    expect(afterBlur[edited], unorderedEquals(<String>['alpha', 'beta']));
    expect(afterBlur[other], isEmpty);

    // 换卡：改完标签直接点另一行，检查器换笔记前落库。
    await tester.enterText(tagsBox(), 'alpha beta gamma');
    await tester.pump();
    await tester.tap(_row(other == a ? '食べる' : '飲む'));
    await _settle(tester);
    final Map<String, List<String>> afterSwitch = await tagsByNote();
    expect(
      afterSwitch[edited],
      unorderedEquals(<String>['alpha', 'beta', 'gamma']),
    );
    expect(afterSwitch[other], isEmpty);
    await _unmount(tester);
  });

  testWidgets('表格：按出处分组（组头是作品名，没有出处的一组在最后）；双击字段摘要格原地改原值，Enter 存并跳到下一行', (
    WidgetTester tester,
  ) async {
    _expectNativeSearch();
    final SrsDbStore store = await _openStore(tester);
    final String eat = await _addSourced(
      tester,
      store,
      '食べる',
      '<b>to eat</b>',
      _book('bk-a', 'Book A'),
    );
    await _addSourced(tester, store, '走る', 'to run', null);
    await _addSourced(tester, store, '飲む', 'to drink', _book('bk-b', 'Book B'));
    await _pump(tester, store: store, size: const Size(1300, 900));
    await tester.tap(
      find.byKey(const ValueKey<String>('srs-browse-layout-table')),
    );
    await _settle(tester, rounds: 6);
    await tester.tap(
      find.byKey(const ValueKey<String>('srs-browse-group-button')),
    );
    await _settle(tester, rounds: 4);
    await tester.tap(find.text(t.srs_browse_table_group_source).last);
    await _settle(tester);

    String header(int index) => tester
        .widget<Text>(find.byKey(ValueKey<String>('srs-browse-group-$index')))
        .data!;
    expect(header(0), 'Book A');
    expect(header(1), 'Book B');
    expect(header(2), t.srs_browse_source_none);
    expect(
      find.byKey(const ValueKey<String>('srs-browse-group-3')),
      findsNothing,
    );

    // 双击第一行的字段摘要格：编辑框是笔记里的原值（带 HTML），不是摘要。
    await _doubleTap(
      tester,
      find.byKey(const ValueKey<String>('srs-browse-cell-0-field1')),
    );
    await _settle(tester, rounds: 6);
    Finder editor() => find.descendant(
      of: find.byKey(const ValueKey<String>('srs-browse-cell-editor')),
      matching: find.byType(EditableText),
    );
    expect(
      tester.widget<EditableText>(editor()).controller.text,
      '<b>to eat</b>',
    );
    await tester.enterText(editor(), 'to consume');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    final SrsNoteView? saved = await tester.runAsync<SrsNoteView?>(
      () => store.note(eat),
    );
    expect(
      saved!.field(srsLapisFieldId(kSrsTestProfile, 'MainDefinition')),
      'to consume',
    );
    // Enter 之后接着改下一行同一格；Esc 取消、不写。
    expect(tester.widget<EditableText>(editor()).controller.text, 'to drink');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester, rounds: 4);
    expect(editor(), findsNothing);

    // 改字段进撤销栈。
    await tester.tap(
      find.byKey(const ValueKey<String>('srs_browse_undo')).first,
    );
    await _settle(tester);
    final SrsNoteView? undone = await tester.runAsync<SrsNoteView?>(
      () => store.note(eat),
    );
    expect(
      undone!.field(srsLapisFieldId(kSrsTestProfile, 'MainDefinition')),
      '<b>to eat</b>',
    );
    await _unmount(tester);
  });

  testWidgets('表格选列存进 profile 偏好，重开页面照旧；标签格原地改，Tab 存并跳到下一格', (
    WidgetTester tester,
  ) async {
    _expectNativeSearch();
    expect(decodeSrsBrowseColumns(''), kSrsBrowseDefaultColumns);
    expect(decodeSrsBrowseColumns('bogus,tags,tags'), <SrsBrowseTableColumn>[
      SrsBrowseTableColumn.front,
      SrsBrowseTableColumn.tags,
    ]);
    final SrsDbStore store = await _openStore(tester);
    final String eat = await _add(tester, store, '食べる', 'to eat');
    final _ColumnsPrefAppModel app = _ColumnsPrefAppModel();
    await _pump(tester, store: store, size: const Size(1300, 900), app: app);
    await tester.tap(
      find.byKey(const ValueKey<String>('srs-browse-layout-table')),
    );
    await _settle(tester, rounds: 6);
    expect(
      find.byKey(const ValueKey<String>('srs-browse-cell-0-tags')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('srs-browse-columns-button')),
    );
    await _settle(tester, rounds: 6);
    final Finder tagsRow = find.byKey(
      const ValueKey<String>('srs-browse-column-tags'),
    );
    // 列面板的列表懒构建：滚到「标签」那一行。
    await tester.scrollUntilVisible(
      tagsRow,
      60,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey<String>('srs-browse-columns')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump();
    await tester.tap(
      find.descendant(of: tagsRow, matching: find.byType(FushiCheckbox)),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('srs-browse-columns-apply')),
    );
    await _settle(tester);
    expect(
      app.columns,
      encodeSrsBrowseColumns(<SrsBrowseTableColumn>[
        ...kSrsBrowseDefaultColumns,
        SrsBrowseTableColumn.tags,
      ]),
    );
    await _unmount(tester);

    // 重开：选的列从偏好读回来（ProviderScope 卸载时 dispose 了上一个 AppModel，换一个读同一份偏好）。
    final _ColumnsPrefAppModel reopened = _ColumnsPrefAppModel()
      ..columns = app.columns;
    await _pump(
      tester,
      store: store,
      size: const Size(1300, 900),
      app: reopened,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('srs-browse-layout-table')),
    );
    await _settle(tester, rounds: 6);
    final Finder tagsCell = find.byKey(
      const ValueKey<String>('srs-browse-cell-0-tags'),
    );
    expect(tagsCell, findsOneWidget);
    await _doubleTap(tester, tagsCell);
    await _settle(tester, rounds: 6);
    Finder editor() => find.descendant(
      of: find.byKey(const ValueKey<String>('srs-browse-cell-editor')),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(editor()).controller.text, '');
    await tester.enterText(editor(), 'n5  grammar n5');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await _settle(tester);
    final SrsNoteView? saved = await tester.runAsync<SrsNoteView?>(
      () => store.note(eat),
    );
    expect(saved!.tags, unorderedEquals(<String>['n5', 'grammar']));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester, rounds: 4);
    await _unmount(tester);
  });

  testWidgets('出处视图「只复习这一作」：在作品各卡牌组的公共祖先上开只出这部作品到期卡的自定义学习', (
    WidgetTester tester,
  ) async {
    _expectNativeSearch();
    final SrsDbStore store = await _openStore(tester);
    final (String works, String a, String b, String other) = (await tester
        .runAsync(() async {
          final String a = await store.ensureDeckPath('Works::A');
          final String b = await store.ensureDeckPath('Works::B');
          final String other = await store.ensureDeckPath('Other');
          final SrsDeckTree tree = await store.deckTree();
          return (tree.parentOf(a)!, a, b, other);
        }))!;
    final SrsDeckTree tree = (await tester.runAsync(store.deckTree))!;
    expect(srsCommonDeckAncestor(tree, <String>[a, b]), works);
    expect(srsCommonDeckAncestor(tree, <String>[a, a]), a);
    expect(srsCommonDeckAncestor(tree, <String>[a, other]), isNull);
    expect(srsTopLevelDecks(tree, <String>[a, b, other]), <String>[
      works,
      other,
    ]);

    final String due = await _addSourced(
      tester,
      store,
      '食べる',
      'to eat',
      _book('bk-a', 'Book A'),
      deckId: a,
    );
    await _addSourced(
      tester,
      store,
      '飲む',
      'to drink',
      _book('bk-a', 'Book A'),
      deckId: b,
    );
    await _addSourced(
      tester,
      store,
      '走る',
      'to run',
      _book('bk-b', 'Book B'),
      deckId: other,
    );
    final String dueCard = (await tester.runAsync(
      () => store.cardsOfNote(due),
    ))!.single.id;
    await tester.runAsync(
      () => srsBatchSetDue(store, <String>[dueCard], from: 0, to: 0),
    );
    // 窗口放高：三组都在首屏里构建（出处列表是懒构建的）。
    await _pump(
      tester,
      store: store,
      size: const Size(1300, 2400),
      // 测试环境没有应用支持目录：媒体库给 null（出处磁贴不显示缩略图），不让取目录的异常把整个出处视图清空。
      overrides: <Override>[
        srsMediaStoreProvider.overrideWith((Ref ref) async => null),
      ],
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('srs-browse-layout-sources')),
    );
    await _settle(tester);
    await _settle(tester);
    expect(
      find.byKey(const ValueKey<String>('srs-browse-sources')),
      findsOneWidget,
    );

    // 今天没有到期卡的作品不给开。
    final Finder idle = find.byKey(
      const ValueKey<String>('srs-browse-source-review-book:bk-b'),
    );
    expect(idle, findsOneWidget);
    expect(tester.widget<FushiFilledButton>(idle).onPressed, isNull);

    final Finder review = find.byKey(
      const ValueKey<String>('srs-browse-source-review-book:bk-a'),
    );
    await tester.ensureVisible(review);
    await tester.pump();
    await tester.tap(review);
    await _settle(tester);
    final SrsReviewPage page = tester.widget<SrsReviewPage>(
      find.byType(SrsReviewPage),
    );
    expect(page.deckId, works);
    expect(page.custom?.mode, SrsCustomStudyMode.filter);
    expect(page.custom?.source, 'book:bk-a');
    expect(page.custom?.states, <SrsCustomStudyState>{
      SrsCustomStudyState.due,
      SrsCustomStudyState.learning,
    });
    // 内核按这一轮的条件出卡：只出这部作品今天到期的那张。
    final SrsStudyState? state = await tester.runAsync<SrsStudyState?>(
      () => store.studyState(works, custom: page.custom),
    );
    expect(state?.next, dueCard);
    expect(state?.after, isNull);
    await _unmount(tester);
  });
}

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
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
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

Future<void> _pump(
  WidgetTester tester, {
  required SrsDbStore store,
  bool apple = false,
  Size size = const Size(500, 900),
  Widget page = const SrsBrowsePage(),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel appModel = AppModel(testPlatformServices());
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => appModel),
        srsStoreProvider.overrideWith((Ref ref) async => store),
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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('[$ds] 搜索：字段限定语法、按字段的关键字搜索、语法错误给出提示', (
      WidgetTester tester,
    ) async {
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
  }

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
}

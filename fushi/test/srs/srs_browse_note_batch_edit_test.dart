// 复习浏览页的批量改笔记：设卡型 / 设字段 / 查找替换三个批量动作接到引擎
// （packages/fushi_engine/lib/srs/srs_note_batch_edit.dart），确认后落库、页面「撤销」能撤掉；
// 查找替换的非法正则在对话框里就地报错、不关窗。
//
// 内存库 + 确定性假排程内核；卡面经 srsCardFaceBuilderProvider 换成纯文本实现。
// 数据库读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_dialogs.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_batch_edit.dart';
import 'package:fushi_srs/fushi_srs.dart'
    show FushiFsrs, SrsNoteView, kFushiFsrsLibEnv;
import 'package:material_ui/material_ui.dart';

import 'srs_test_support.dart';

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

Future<String> _field(
  WidgetTester tester,
  SrsDbStore store,
  String noteId,
  String fieldName,
) async {
  final SrsNoteView? note = await tester.runAsync<SrsNoteView?>(
    () => store.note(noteId),
  );
  return note!.field(srsLapisFieldId(kSrsTestProfile, fieldName));
}

Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _pump(WidgetTester tester, {required SrsDbStore store}) async {
  tester.view.physicalSize = const Size(500, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppModel appModel = SrsTestAppModel();
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
            designSystem: FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: false,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: const SrsBrowsePage(),
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

Finder _row(String text) => find.descendant(
  of: find.byWidgetPredicate(
    (Widget w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('srs-browse-row-'),
  ),
  matching: find.text(text),
);

Future<void> _openMenu(WidgetTester tester, String row) async {
  await tester.longPress(_row(row));
  await _settle(tester, rounds: 3);
  await tester.tap(
    find.byKey(const ValueKey<String>('srs_browse_batch')).first,
  );
  await _settle(tester, rounds: 4);
}

Future<void> _tapText(WidgetTester tester, String text) async {
  final Finder f = find.text(text).last;
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await _settle(tester, rounds: 4);
}

/// 页面「撤销」可点（撤销栈非空且不在忙）：落库后的刷新也占着 `_busy`，机器忙时固定轮数的
/// [_settle] 不一定等得到它，在按钮还是禁用时点下去就是空点（并发跑时的偶发红）。
bool _undoEnabled() => find
    .descendant(
      of: find.byKey(const ValueKey<String>('srs_browse_undo')).first,
      matching: find.byWidgetPredicate(
        (Widget w) =>
            (w is FushiIconButtonControl && w.onPressed != null) ||
            (w is IconButton && w.onPressed != null) ||
            (w is InkResponse && w.onTap != null),
      ),
      matchRoot: true,
    )
    .evaluate()
    .isNotEmpty;

Future<void> _undo(WidgetTester tester) async {
  for (int i = 0; i < 200 && !_undoEnabled(); i++) {
    await _settle(tester, rounds: 1);
  }
  expect(_undoEnabled(), isTrue, reason: '撤销按钮一直不可用');
  await tester.tap(find.byKey(const ValueKey<String>('srs_browse_undo')).first);
  await _settle(tester);
}

/// 等字段写到 [expected]（撤销在后台写库，机器忙时固定轮数不一定等得到）；超时按最后读到的值断言。
Future<void> _expectFieldEventually(
  WidgetTester tester,
  SrsDbStore store,
  String noteId,
  String fieldName,
  String expected,
) async {
  String actual = await _field(tester, store, noteId, fieldName);
  for (int i = 0; i < 200 && actual != expected; i++) {
    await _settle(tester, rounds: 1);
    actual = await _field(tester, store, noteId, fieldName);
  }
  expect(actual, expected);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  setUpAll(
    () => expect(
      FushiFsrs.isAvailable,
      isTrue,
      reason:
          'fushi_fsrs native library not loadable: build it with '
          'native/fushi_fsrs/build_*.{ps1,sh} and set $kFushiFsrsLibEnv',
    ),
  );

  testWidgets('批量菜单列出设卡型 / 设字段 / 查找替换', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    await _add(tester, store, '食べる', 'to eat');
    await _pump(tester, store: store);
    await _openMenu(tester, '食べる');
    expect(find.text(t.srs_browse_card_type_set), findsOneWidget);
    expect(find.text(t.srs_browse_field_set), findsOneWidget);
    expect(find.text(t.srs_browse_find_replace), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('设卡型：确认显示条数，落库后可撤销', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    final String id = await _add(tester, store, '食べる', 'to eat');
    await _pump(tester, store: store);
    final String sentenceBefore = await _field(
      tester,
      store,
      id,
      'IsSentenceCard',
    );

    await _openMenu(tester, '食べる');
    await _tapText(tester, t.srs_browse_card_type_set);
    await _tapText(tester, t.srs_browse_card_type_sentence);
    expect(
      find.textContaining(t.srs_browse_field_edit_confirm(n: 1)),
      findsOneWidget,
    );
    await _tapText(tester, t.srs_browse_field_edit_apply);
    expect(await _field(tester, store, id, 'IsSentenceCard'), 'x');

    await _undo(tester);
    await _expectFieldEventually(
      tester,
      store,
      id,
      'IsSentenceCard',
      sentenceBefore,
    );
    await _unmount(tester);
  });

  testWidgets('查找替换：非法正则就地报错不关窗；改对后替换并可撤销', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    final String id = await _add(tester, store, '食べる', 'to eat food');
    await _pump(tester, store: store);

    await _openMenu(tester, '食べる');
    await _tapText(tester, t.srs_browse_find_replace);
    final Finder findField = find.descendant(
      of: find.byKey(const ValueKey<String>('srs-browse-find-replace-find')),
      matching: find.byType(EditableText),
    );
    final Finder replaceField = find.descendant(
      of: find.byKey(
        const ValueKey<String>('srs-browse-find-replace-replacement'),
      ),
      matching: find.byType(EditableText),
    );
    await tester.enterText(findField, '(eat');
    await tester.tap(
      find.byKey(const ValueKey<String>('srs-browse-find-replace-regex')),
    );
    await _settle(tester, rounds: 3);
    await tester.tap(
      find.byKey(const ValueKey<String>('srs-browse-find-replace-ok')),
    );
    await _settle(tester, rounds: 4);
    expect(
      find.textContaining(
        t.srs_browse_find_replace_regex_invalid(reason: '').trim(),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('srs-browse-find-replace-ok')),
      findsOneWidget,
    );

    await tester.enterText(findField, r'eat (\w+)');
    await tester.enterText(replaceField, r'drink $1');
    await _settle(tester, rounds: 3);
    await tester.tap(
      find.byKey(const ValueKey<String>('srs-browse-find-replace-ok')),
    );
    await _settle(tester, rounds: 4);
    expect(
      find.textContaining(t.srs_browse_field_edit_confirm(n: 1)),
      findsOneWidget,
    );
    await _tapText(tester, t.srs_browse_field_edit_apply);
    expect(await _field(tester, store, id, 'MainDefinition'), 'to drink food');

    await _undo(tester);
    await _expectFieldEventually(
      tester,
      store,
      id,
      'MainDefinition',
      'to eat food',
    );
    await _unmount(tester);
  });

  test('空计划提示：全被跳过报跳过条数，只有都已是目标值才「没有改动」', () {
    final ({String message, bool warning}) skipped =
        srsNoteFieldPlanEmptyNotice(
          const SrsNoteFieldPlan(
            changes: <SrsNoteFieldChange>[],
            skipped: <String>['a', 'b'],
            unchanged: 0,
            missing: <String>[],
          ),
        );
    expect(skipped.message, t.srs_browse_field_edit_skipped(n: 2));
    expect(skipped.warning, isTrue);
    final ({String message, bool warning}) same = srsNoteFieldPlanEmptyNotice(
      const SrsNoteFieldPlan(
        changes: <SrsNoteFieldChange>[],
        skipped: <String>[],
        unchanged: 3,
        missing: <String>[],
      ),
    );
    expect(same.message, t.srs_browse_nothing_changed);
    expect(same.warning, isFalse);
  });
}

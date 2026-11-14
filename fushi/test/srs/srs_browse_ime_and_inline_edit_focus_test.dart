// 复习卡片浏览页的两条输入回归（焦点驱动，不点按）：
// - 搜索框的输入法组字：组字中的中间态不进查询、不被当成粘贴拆成积木（反馈 D2hILRLlPT）；
// - 宽屏检查器编辑页签：停笔 800 ms 自动保存后输入框不重建、不丢焦点与光标（反馈 a0lR-BHuJU）。
//
// 内存库 + 确定性假排程内核；数据库读写一律放 tester.runAsync。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
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
  required Size size,
}) async {
  tester.view.physicalSize = size;
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

final Finder _searchBox = find.descendant(
  of: find.byKey(const ValueKey<String>('srs-browse-search')),
  matching: find.byType(EditableText),
);

/// 输入法往搜索框里送一份编辑值（[composing] 非空 = 还在组字）。
Future<void> _ime(
  WidgetTester tester,
  String text, {
  TextRange composing = TextRange.empty,
}) async {
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: composing,
    ),
  );
  await tester.pump(const Duration(milliseconds: 250));
  await _settle(tester, rounds: 4);
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

  testWidgets('BUG：搜索框组字中的中间态不进查询、不拆积木；组字确认后才按提交值筛（含只清 composing 不改文本）', (
    WidgetTester tester,
  ) async {
    _expectNativeSearch();
    final SrsDbStore store = await _openStore(tester);
    await _add(tester, store, '食べる', 'to eat');
    await _add(tester, store, '飲む', 'to drink');
    await _pump(tester, store: store, size: const Size(500, 900));
    await tester.showKeyboard(_searchBox);
    await tester.pump();

    // 中文输入法组字：拼音带空格分音节，整段是 composing。以前一次多进来几个字 + 含空白 = 当成粘贴拆积木、
    // 清空草稿，组字被打断。
    await _ime(tester, 'ni', composing: const TextRange(start: 0, end: 2));
    await _ime(tester, 'ni hao', composing: const TextRange(start: 0, end: 6));
    expect(
      find.byKey(const ValueKey<String>('srs-browse-chip-0')),
      findsNothing,
    );
    final EditableText box = tester.widget<EditableText>(_searchBox);
    expect(box.controller.text, 'ni hao');
    expect(box.controller.value.composing, const TextRange(start: 0, end: 6));
    // 中间态不进查询：两行都在。
    expect(_row('食べる'), findsOneWidget);
    expect(_row('飲む'), findsOneWidget);

    // 选定候选：提交值进来，按它筛；输入法确认的一段字不当粘贴。
    await _ime(tester, '食べる');
    expect(
      find.byKey(const ValueKey<String>('srs-browse-chip-0')),
      findsNothing,
    );
    expect(_row('食べる'), findsOneWidget);
    expect(_row('飲む'), findsNothing);

    // 日文输入法：候选已经是正文、回车确认时只清 composing、文本不变（TextField 的 onChanged 不报）。
    await _ime(tester, '飲む', composing: const TextRange(start: 0, end: 2));
    expect(_row('食べる'), findsOneWidget, reason: '组字中仍按上一次提交值筛');
    await _ime(tester, '飲む');
    expect(_row('飲む'), findsOneWidget);
    expect(_row('食べる'), findsNothing);
    await _unmount(tester);
  });

  testWidgets('BUG：检查器编辑页签停笔自动保存后，输入框不重建、保住焦点与光标，可以接着打字', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _openStore(tester);
    final String noteId = await _add(tester, store, '食べる', 'to eat');
    await _pump(tester, store: store, size: const Size(1300, 900));

    // 焦点驱动切到「编辑」页签：焦点放到分段按钮的这一段上，对持焦控件发激活意图（浏览页自己的按键处理
    // 把 Enter / 空格当「翻面」，到不了应用级的激活快捷键）。
    final FocusNode tab = Focus.of(
      tester.element(find.byKey(const ValueKey<String>('srs-browse-tab-edit'))),
    );
    tab.requestFocus();
    await tester.pump();
    expect(tab.hasPrimaryFocus, isTrue);
    Actions.invoke(tab.context!, const ActivateIntent());
    await _settle(tester, rounds: 6);

    final Finder field = find.descendant(
      of: find.byKey(const ValueKey<String>('srs-browse-field-MainDefinition')),
      matching: find.byType(EditableText),
    );
    expect(field, findsOneWidget);
    await tester.showKeyboard(field);
    await tester.pump();
    final EditableTextState before = tester.state<EditableTextState>(field);
    expect(before.widget.focusNode.hasFocus, isTrue);

    // 富文本字段：空格存成 &nbsp;，正好走一遍「存进库的值 ≠ 编辑器里的文本」。
    tester.testTextInput.enterText('to consume');
    await tester.pump(const Duration(milliseconds: 900));
    await _settle(tester);
    final SrsNoteView? saved = await tester.runAsync<SrsNoteView?>(
      () => store.note(noteId),
    );
    expect(
      saved!.field(srsLapisFieldId(kSrsTestProfile, 'MainDefinition')),
      isNot('to eat'),
    );

    // 保存引起的重读之后：还是同一个输入框、仍持焦、光标停在末尾。
    expect(field, findsOneWidget);
    final EditableTextState after = tester.state<EditableTextState>(field);
    expect(identical(after, before), isTrue, reason: '输入框被整体重建了');
    expect(after.widget.focusNode.hasFocus, isTrue);
    expect(after.widget.controller.text, 'to consume', reason: '刚打的字被换回旧值');
    expect(
      after.widget.controller.selection,
      const TextSelection.collapsed(offset: 'to consume'.length),
    );

    // 接着打字照常进同一个输入框并再存一次。
    tester.testTextInput.enterText('to consume food');
    await tester.pump(const Duration(milliseconds: 900));
    await _settle(tester);
    expect(identical(tester.state<EditableTextState>(field), before), isTrue);
    expect(before.widget.controller.text, 'to consume food');
    expect(before.widget.focusNode.hasFocus, isTrue);
    await _unmount(tester);
  });
}

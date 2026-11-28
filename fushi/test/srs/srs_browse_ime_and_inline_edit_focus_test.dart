// 复习卡片浏览页的两条输入回归（焦点驱动，不点按）：
// - 搜索框的输入法组字：组字中的中间态不进查询、不被当成粘贴拆成积木（反馈 D2hILRLlPT）；
// - 宽屏检查器编辑页签：停笔 800 ms 自动保存后输入框不重建、不丢焦点与光标（反馈 a0lR-BHuJU）；写入途中才读回来的
//   上一次重读（读的是写入之前的库）不把刚存的格子 / 标签换回旧值。
//
// 等待一律按信号：[_settle] 推进到内核往返（读命令 / 写命令）都落地为止，不数固定轮数。
//
// 内存库 + 确定性假排程内核；数据库读写一律放 tester.runAsync。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_inspector.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_preview.dart'
    show SrsPreviewCommand;
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_browse_ops.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_batch_edit.dart';
import 'package:fushi_engine/srs/srs_op_ledger.dart';
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

/// 推进到内核往返都落地：至少 [rounds] 步，之后连续 3 步没有在途的内核读 / 写命令（[SrsOpLedger.inflightCount]）
/// 才停。不像 [srsSettle] 那样再等帧排空：输入框持焦时光标一直在闪、帧永远排着。
Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  int quiet = 0;
  for (int i = 0; i < rounds || quiet < 3; i++) {
    if (i >= 400) fail('400 步内内核往返没有全部落地 ${SrsOpLedger.takeSummary()}');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 60));
    quiet = SrsOpLedger.inflightCount == 0 ? quiet + 1 : 0;
  }
}

/// 测试用的应用外壳：[home] 是要测的页面 / 组件。同一个 [appModel] 重复挂载时组件树形状不变（只更新参数）。
Widget _app({
  required SrsDbStore store,
  required AppModel appModel,
  required Widget home,
}) => ProviderScope(
  overrides: <Override>[
    appProvider.overrideWith((Ref ref) => appModel),
    srsStoreProvider.overrideWith((Ref ref) async => store),
    srsCardFaceBuilderProvider.overrideWithValue(
      (BuildContext context, SrsCardFace face) => SrsPlainCardFace(face: face),
    ),
  ],
  child: TranslationProvider(
    child: MaterialApp(
      theme: buildFushiThemeData(
        scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        textTheme: Typography.material2021().black,
        glass: FushiGlassMaterial.off,
        glassDesign: false,
      ),
      builder: (BuildContext context, Widget? child) =>
          FushiGlassScope(child: child!),
      home: home,
    ),
  ),
);

Future<void> _pump(
  WidgetTester tester, {
  required SrsDbStore store,
  required Size size,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _app(
      store: store,
      appModel: SrsTestAppModel(),
      home: const SrsBrowsePage(),
    ),
  );
  await _settle(tester);
}

/// 单独挂上一份检查器（编辑页签），行与动作取自浏览页里那一份（[from]），保存回调换成测试可控的。
/// 换 [revision] 再挂一次 = 浏览页写入后让检查器重读（同一个组件，只更新参数）。
Future<void> _pumpInspector(
  WidgetTester tester, {
  required SrsDbStore store,
  required AppModel appModel,
  required SrsBrowseInspector from,
  required int revision,
  required SrsBrowseSaveField onSaveField,
  required SrsBrowseSaveTags onSaveTags,
}) => tester.pumpWidget(
  _app(
    store: store,
    appModel: appModel,
    home: Scaffold(
      body: SrsBrowseInspector(
        row: from.row,
        revision: revision,
        tab: SrsBrowseInspectorTab.edit,
        onTabChanged: (SrsBrowseInspectorTab _) {},
        showAnswer: false,
        onCommand: (SrsPreviewCommand _) {},
        onSaveField: onSaveField,
        onSaveTags: onSaveTags,
        onOpenEditor: (String _) {},
        actions: from.actions,
      ),
    ),
  ),
);

/// 像浏览页那样把笔记 [noteId] 的字段 [fieldName] 写成 [value]（计划 + 条件写）。
Future<void> _writeField(
  SrsDbStore store,
  String noteId,
  String fieldName,
  String value,
) async {
  await srsApplyNoteFieldPlan(
    store,
    await srsPlanSetField(store, <String>[noteId], fieldName, value),
  );
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

/// 把键盘焦点放到检查器分段按钮的某一段上（焦点驱动，不点按）。
Future<void> _focusTab(WidgetTester tester, String key) async {
  final FocusNode tab = Focus.of(
    tester.element(find.byKey(ValueKey<String>(key))),
  );
  tab.requestFocus();
  await tester.pump();
  expect(tab.hasPrimaryFocus, isTrue);
}

final Finder _answer = find.byKey(const ValueKey<String>('srs-face-answer'));
final Finder _question = find.byKey(
  const ValueKey<String>('srs-face-question'),
);
final Finder _editField = find.byKey(
  const ValueKey<String>('srs-browse-field-MainDefinition'),
);

void _expectNativeSearch() => expect(
  FushiFsrs.isAvailable,
  isTrue,
  reason:
      'fushi_fsrs native library not loadable: build it with '
      'native/fushi_fsrs/build_*.{ps1,sh} and set $kFushiFsrsLibEnv',
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    // 在途账本是进程级的：上一条用例卸载时没送到的内核回包会把它的操作一直留在账上，[_settle] 就永远等不到清零。
    SrsOpLedger.reset();
  });

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

    // 焦点驱动切到「编辑」页签：焦点放到分段按钮的这一段上，按真 Enter（BUG-4628：以前浏览页的按键处理
    // 把 Enter 当「翻面」吞掉，到不了应用级的激活快捷键）。
    await _focusTab(tester, 'srs-browse-tab-edit');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
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
  testWidgets('BUG：写入途中才读回来的上一次重读不把刚存的字段换回旧值、不重建输入框', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _openStore(tester);
    final String noteId = await _add(tester, store, '食べる', 'to eat');
    await _pump(tester, store: store, size: const Size(1300, 900));
    final SrsBrowseInspector from = tester.widget<SrsBrowseInspector>(
      find.byType(SrsBrowseInspector),
    );
    final AppModel appModel = SrsTestAppModel();
    final Completer<void> gate = Completer<void>();
    final List<String> saves = <String>[];
    Future<void> onSaveField(String id, String field, String value) async {
      saves.add(value);
      await gate.future;
      await _writeField(store, id, field, value);
    }

    Future<void> onSaveTags(String id, List<String> b, List<String> a) async {}
    await _pumpInspector(
      tester,
      store: store,
      appModel: appModel,
      from: from,
      revision: 0,
      onSaveField: onSaveField,
      onSaveTags: onSaveTags,
    );
    await _settle(tester);
    final Finder field = find.descendant(
      of: _editField,
      matching: find.byType(EditableText),
    );
    expect(field, findsOneWidget);

    // 上一次保存已落库（库里是 'to drink'），它引起的重读刚发出、还没读回来。
    await tester.runAsync(
      () => _writeField(store, noteId, 'MainDefinition', 'to drink'),
    );
    await _pumpInspector(
      tester,
      store: store,
      appModel: appModel,
      from: from,
      revision: 1,
      onSaveField: onSaveField,
      onSaveTags: onSaveTags,
    );
    // 重读在途时接着打字、停笔 800 ms 开始下一次保存（这里只推进假时钟，内核的回包还送不到）。
    await tester.showKeyboard(field);
    await tester.pump();
    final EditableTextState before = tester.state<EditableTextState>(field);
    tester.testTextInput.enterText('to consume');
    await tester.pump(const Duration(milliseconds: 900));
    expect(saves, <String>['to&nbsp;consume']);

    // 写入途中那次重读读回来（库里还是 'to drink'）：不许把刚存的字段换回去。
    await _settle(tester);
    expect(field, findsOneWidget);
    final EditableTextState during = tester.state<EditableTextState>(field);
    expect(identical(during, before), isTrue, reason: '输入框被整体重建了');
    expect(during.widget.controller.text, 'to consume', reason: '刚打的字被换回旧值');
    expect(during.widget.focusNode.hasFocus, isTrue);

    // 写完之后检查器重读到库里的新值，仍是同一个输入框。
    gate.complete();
    await _settle(tester);
    final SrsNoteView? saved = await tester.runAsync<SrsNoteView?>(
      () => store.note(noteId),
    );
    expect(
      saved!.field(srsLapisFieldId(kSrsTestProfile, 'MainDefinition')),
      'to&nbsp;consume',
    );
    expect(identical(tester.state<EditableTextState>(field), before), isTrue);
    expect(before.widget.controller.text, 'to consume');
    await _unmount(tester);
  });

  testWidgets('BUG：同一字段两次保存重叠时，W1 落库引起的重读赶在 W2 落库前读回来，不把字段换回 W1、后发的值最终落库', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _openStore(tester);
    final String noteId = await _add(tester, store, '食べる', 'to eat');
    await _pump(tester, store: store, size: const Size(1300, 900));
    final SrsBrowseInspector from = tester.widget<SrsBrowseInspector>(
      find.byType(SrsBrowseInspector),
    );
    final AppModel appModel = SrsTestAppModel();
    // 第 i 次保存先等 gates[i] 放行再写库，写完 persisted[i] 完成。
    final List<Completer<void>> gates = <Completer<void>>[
      Completer<void>(),
      Completer<void>(),
    ];
    final List<Completer<void>> persisted = <Completer<void>>[
      Completer<void>(),
      Completer<void>(),
    ];
    final List<String> saves = <String>[];
    Future<void> onSaveField(String id, String field, String value) async {
      final int i = saves.length;
      saves.add(value);
      await gates[i].future;
      await _writeField(store, id, field, value);
      persisted[i].complete();
    }

    Future<void> onSaveTags(String id, List<String> b, List<String> a) async {}
    Future<void> mount(int revision) => _pumpInspector(
      tester,
      store: store,
      appModel: appModel,
      from: from,
      revision: revision,
      onSaveField: onSaveField,
      onSaveTags: onSaveTags,
    );
    await mount(0);
    await _settle(tester);
    final Finder field = find.descendant(
      of: _editField,
      matching: find.byType(EditableText),
    );
    expect(field, findsOneWidget);
    await tester.showKeyboard(field);
    await tester.pump();
    final EditableTextState before = tester.state<EditableTextState>(field);

    // W1：停笔 800 ms 保存 'devour'，还没落库；接着打字再停笔，发起 W2 'devours'。
    tester.testTextInput.enterText('devour');
    await tester.pump(const Duration(milliseconds: 900));
    tester.testTextInput.enterText('devours');
    await tester.pump(const Duration(milliseconds: 900));

    // W1 落库；W2 还卡着没落库。
    gates[0].complete();
    await _settle(tester);
    expect(persisted[0].isCompleted, isTrue);
    expect(saves, <String>['devour', 'devours']);
    expect(persisted[1].isCompleted, isFalse);

    // W1 落库让浏览页 revision +1，检查器重读——读回来的是 W1 的 'devour'（W2 还没提交）：不许落地。
    await mount(1);
    await _settle(tester);
    expect(field, findsOneWidget);
    final EditableTextState during = tester.state<EditableTextState>(field);
    expect(identical(during, before), isTrue, reason: '输入框被整体重建了');
    expect(during.widget.controller.text, 'devours', reason: '刚打的字被换回 W1 的值');
    expect(during.widget.focusNode.hasFocus, isTrue);

    // W2 落库（浏览页 revision 再 +1）：库里是后发的值，界面不回退、仍是同一个输入框。
    gates[1].complete();
    await _settle(tester);
    await mount(2);
    await _settle(tester);
    final SrsNoteView? saved = await tester.runAsync<SrsNoteView?>(
      () => store.note(noteId),
    );
    expect(
      saved!.field(srsLapisFieldId(kSrsTestProfile, 'MainDefinition')),
      'devours',
    );
    expect(identical(tester.state<EditableTextState>(field), before), isTrue);
    expect(before.widget.controller.text, 'devours');
    expect(before.widget.focusNode.hasFocus, isTrue);
    await _unmount(tester);
  });

  testWidgets('BUG：写入途中才读回来的上一次重读不把刚存的标签换回旧值', (WidgetTester tester) async {
    final SrsDbStore store = await _openStore(tester);
    final String noteId = await _add(tester, store, '食べる', 'to eat');
    await _pump(tester, store: store, size: const Size(1300, 900));
    final SrsBrowseInspector from = tester.widget<SrsBrowseInspector>(
      find.byType(SrsBrowseInspector),
    );
    final AppModel appModel = SrsTestAppModel();
    final Completer<void> gate = Completer<void>();
    final List<List<String>> saves = <List<String>>[];
    // 标签框排在全部字段之后：视口拉高到整列都建出来（不靠拖动滚动）。
    tester.view.physicalSize = const Size(1300, 6000);
    Future<void> onSaveField(String id, String field, String value) async {}
    Future<void> onSaveTags(String id, List<String> b, List<String> a) async {
      saves.add(a);
      await gate.future;
      await srsBatchEditTags(
        store,
        <String>[id],
        add: <String>[
          for (final String t in a)
            if (!b.contains(t)) t,
        ],
        remove: <String>[
          for (final String t in b)
            if (!a.contains(t)) t,
        ],
      );
    }

    await _pumpInspector(
      tester,
      store: store,
      appModel: appModel,
      from: from,
      revision: 0,
      onSaveField: onSaveField,
      onSaveTags: onSaveTags,
    );
    await _settle(tester);
    final Finder tags = find.descendant(
      of: find.byKey(const ValueKey<String>('srs-browse-edit-tags')),
      matching: find.byType(EditableText),
    );
    expect(tags, findsOneWidget);

    // 上一次保存已落库（库里的标签是 old），它引起的重读刚发出、还没读回来。
    await tester.runAsync(
      () => srsBatchEditTags(store, <String>[noteId], add: <String>['old']),
    );
    await _pumpInspector(
      tester,
      store: store,
      appModel: appModel,
      from: from,
      revision: 1,
      onSaveField: onSaveField,
      onSaveTags: onSaveTags,
    );
    // 重读在途时改标签并回车保存（只推进假时钟，内核的回包还送不到）。
    await tester.showKeyboard(tags);
    await tester.pump();
    tester.testTextInput.enterText('fresh');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(saves, <List<String>>[
      <String>['fresh'],
    ]);

    // 写入途中那次重读读回来（库里的标签还是 old）：不许把刚存的标签换回去。
    await _settle(tester);
    expect(
      tester.state<EditableTextState>(tags).widget.controller.text,
      'fresh',
      reason: '刚存的标签被换回旧值',
    );

    gate.complete();
    await _settle(tester);
    final SrsNoteView? saved = await tester.runAsync<SrsNoteView?>(
      () => store.note(noteId),
    );
    expect(saved!.tags, contains('fresh'));
    await _unmount(tester);
  });

  testWidgets('BUG-4628：宽屏卡面区持焦时 Enter 翻面；焦点在检查器页签上时 Enter 切页签、不翻面', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _openStore(tester);
    await _add(tester, store, '食べる', 'to eat');
    await _pump(tester, store: store, size: const Size(1300, 900));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _settle(tester, rounds: 4);
    expect(_question, findsOneWidget);

    // 卡面区（整页 key sink）持焦：Enter 仍是翻面。
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester, rounds: 4);
    expect(_answer, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester, rounds: 4);
    expect(_answer, findsNothing);

    // 焦点在「编辑」页签上：Enter 归分段按钮，切到编辑页签。
    await _focusTab(tester, 'srs-browse-tab-edit');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester, rounds: 6);
    expect(_editField, findsOneWidget);

    // 切回「预览」页签同样走 Enter；切回来卡面仍是正面（Enter 没被当成翻面）。
    await _focusTab(tester, 'srs-browse-tab-preview');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester, rounds: 6);
    expect(_editField, findsNothing);
    expect(_question, findsOneWidget);
    expect(_answer, findsNothing);
    await _unmount(tester);
  });

  testWidgets('BUG-4628：窄屏详情页卡面区持焦时空格 / Enter 翻面；焦点在页签上时 Enter 切页签', (
    WidgetTester tester,
  ) async {
    final SrsDbStore store = await _openStore(tester);
    await _add(tester, store, '食べる', 'to eat');
    await _pump(tester, store: store, size: const Size(500, 900));
    // 列表页：↓ 选中第一行，Enter 打开全屏详情页。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _settle(tester, rounds: 4);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester);
    expect(_question, findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _settle(tester, rounds: 4);
    expect(_answer, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester, rounds: 4);
    expect(_answer, findsNothing);

    await _focusTab(tester, 'srs-browse-tab-edit');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester, rounds: 6);
    expect(_editField, findsOneWidget);
    await _unmount(tester);
  });
}

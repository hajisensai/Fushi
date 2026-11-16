// 「导入文本文件」对话框：初值来自文件头（笔记类型 / 牌组 / 已存在笔记 / 匹配范围 / 标签 / 列用途），
// 字段默认按顺序取普通列；确认交回的选项；窄屏不溢出。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_text_import_dialog.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/text/srs_text_import.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'srs_test_support.dart';

void main() {
  const SrsTextFile preview = SrsTextFile(
    delimiter: '\t',
    html: false,
    columnCount: 4,
    total: 12,
    rows: <List<String>>[
      <String>['猫', 'neko', 'animal', 'g1'],
    ],
    tags: <String>['imported', 'n5'],
    noteType: 'lapis',
    tagsColumn: 3,
    guidColumn: 4,
    ifMatches: SrsTextDupeMode.preserve,
    matchScope: SrsTextMatchScope.noteTypeAndDeck,
  );

  Future<(BuildContext, SrsDbStore, List<SrsNoteTypeView>, SrsDeckTree)> host(
    WidgetTester tester,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (_, SrsDbStore store) = (await tester.runAsync(openSrsTestStore))!;
    final List<SrsNoteTypeView> types = (await tester.runAsync(
      store.noteTypes,
    ))!;
    final SrsDeckTree tree = (await tester.runAsync(store.deckTree))!;
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              ctx = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    return (ctx, store, types, tree);
  }

  Future<SrsTextImportChoice?> openAndConfirm(
    WidgetTester tester,
    Size size,
  ) async {
    final (
      BuildContext ctx,
      SrsDbStore store,
      List<SrsNoteTypeView> types,
      SrsDeckTree tree,
    ) = await host(
      tester,
      size,
    );
    final Future<SrsTextImportChoice?> result = showSrsTextImportDialog(
      context: ctx,
      fileName: 'vocab.tsv',
      preview: preview,
      noteTypes: types,
      decks: tree,
      defaultDeckId: store.defaultDeckId,
      reparse: (String d, bool h) async => preview,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('vocab.tsv · 12 rows'), findsOneWidget);
    final Finder confirm = find.byKey(
      const ValueKey<String>('srs-text-import-confirm'),
    );
    await tester.ensureVisible(confirm);
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('文件头给的初值与默认列映射交回给导入', (WidgetTester tester) async {
    final SrsTextImportChoice choice = (await openAndConfirm(
      tester,
      const Size(1280, 900),
    ))!;
    expect(choice.delimiter, '\t');
    expect(choice.html, isFalse);
    final SrsTextImportOptions o = choice.options;
    expect(o.dupeMode, SrsTextDupeMode.preserve);
    expect(o.matchScope, SrsTextMatchScope.noteTypeAndDeck);
    expect(o.tags, <String>['imported', 'n5']);
    expect(o.tagsColumn, 3);
    expect(o.guidColumn, 4);
    expect(o.deckColumn, isNull);
    // 笔记类型按名字（不分大小写）选中；字段按顺序取第 1、2 列，标签 / GUID 列不参与。
    expect(o.fieldColumns.take(3), <int>[1, 2, 0]);
  });

  testWidgets('手机宽度不溢出', (WidgetTester tester) async {
    final SrsTextImportChoice? choice = await openAndConfirm(
      tester,
      const Size(360, 740),
    );
    expect(choice, isNotNull);
  });
}

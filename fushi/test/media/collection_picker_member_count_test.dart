import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/add_to_collection_dialog.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-3361（反馈 ow9_1sxU16「合集数和实际合集数量不一致」）：「加入合集」弹窗按
/// 成员表**原始行数**写「N 项」，合集详情页只画得出库页上真实存在的成员。成员表
/// 没有指向媒体的外键——删掉的书、配对有声书的伴生行都会留行——于是弹窗写「10 项」、
/// 点进去只有 6 本。修复后弹窗按调用方给的可见性判据计数（与详情页同一判据）。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Future<({FushiDatabase db, String visibleUid, String targetUid})>
  seed() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    Future<String> book(String key) async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: key,
          title: key,
          epubPath: '/tmp/$key.epub',
          extractDir: '/tmp',
          chapterCount: 1,
          chaptersJson: '["a"]',
          importedAt: 0,
          format: const Value<String>('epub'),
        ),
      );
      return (await db.resolveEpubBookUid(key))!;
    }

    final String visibleUid = await book('vol1');
    final String targetUid = await book('vol6');
    final int col = await db.createMediaCollection('やはり俺の青春');
    await db.addToCollection(col, MediaKind.epub, visibleUid);
    // 画不出来的行：已删除的书（孤儿 uid）与配对有声书的伴生 srt 行。
    await db.addToCollection(col, MediaKind.epub, 'deleted-book-uid');
    await db.addToCollection(col, MediaKind.srt, 'srtbook_epub_vol1');
    return (db: db, visibleUid: visibleUid, targetUid: targetUid);
  }

  Future<void> openDialog(
    WidgetTester tester,
    FushiDatabase db,
    String entryKey,
    CollectionMemberVisibility? isMemberVisible,
  ) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => showAddToCollectionDialog(
                  context: context,
                  database: db,
                  mediaType: MediaKind.epub,
                  entryKey: entryKey,
                  isMemberVisible: isMemberVisible,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('弹窗成员数只数库页画得出来的成员（与详情页同口径）', (WidgetTester tester) async {
    late ({FushiDatabase db, String visibleUid, String targetUid}) s;
    await tester.runAsync(() async => s = await seed());
    await openDialog(
      tester,
      s.db,
      s.targetUid,
      (String mediaType, String entryKey) =>
          mediaType == MediaKind.epub.dbValue && entryKey == s.visibleUid,
    );
    expect(find.text(t.series_item_count(n: 1)), findsOneWidget);
    expect(find.text(t.series_item_count(n: 3)), findsNothing);
  });

  testWidgets('不给判据时保持原始行数（调用方没有可见性判据的旧行为）', (WidgetTester tester) async {
    late ({FushiDatabase db, String visibleUid, String targetUid}) s;
    await tester.runAsync(() async => s = await seed());
    await openDialog(tester, s.db, s.targetUid, null);
    expect(find.text(t.series_item_count(n: 3)), findsOneWidget);
  });

  test('书架 / 游戏库把详情页同一判据交给「加入合集」与「移到其他合集」（源码守卫）', () {
    final String shelf = File(
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
    ).readAsStringSync();
    final String books = File(
      'lib/src/pages/implementations/reader_history/books.part.dart',
    ).readAsStringSync();
    final String games = File(
      'lib/src/pages/implementations/games_library_page.dart',
    ).readAsStringSync();
    expect(
      'isMemberVisible: _isCollectionMemberVisible'.allMatches(shelf).length,
      2,
      reason: '书卡「加入合集」+ 合集详情页（移到其他合集）',
    );
    expect(
      books.contains('isMemberVisible: _isCollectionMemberVisible'),
      isTrue,
      reason: '字幕书卡「加入合集」',
    );
    expect(
      'isMemberVisible: _isGameCollectionMemberVisible'
          .allMatches(games)
          .length,
      2,
    );
    expect(
      shelf.contains('_resolveCollectionMember(mediaType, entryKey);'),
      isTrue,
      reason: '成员卡与可见性判据必须共用同一个解析函数，不得各写一份',
    );
  });
}

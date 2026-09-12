import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test(
    'v103 migration preserves books and persists canonical aliases on reopen',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'aliases104',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = '${directory.path}/test.db';
      final FushiDatabase original = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      await original.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'actual-title',
          uid: const Value<String>('book-uid'),
          title: 'Title',
          epubPath: '/book.epub',
          extractDir: '/book',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 10,
        ),
      );
      await original.close();
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      raw.execute('DROP TABLE collection_book_aliases');
      raw.execute('PRAGMA user_version = 103');
      raw.dispose();
      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      expect(await migrated.resolveEpubBookUid('actual-title'), 'book-uid');
      expect(await migrated.getCollectionBookAliases(), isEmpty);
      await migrated.setCollectionBookAlias('book-uid', 'remote-key');
      await migrated.close();
      final FushiDatabase reopened = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      addTearDown(reopened.close);
      expect(await reopened.getCollectionBookAliases(), <String, String>{
        'remote-key': 'book-uid',
      });
      expect(
        await reopened.resolveEpubBookKeyByUid('book-uid'),
        'actual-title',
      );
    },
  );
}

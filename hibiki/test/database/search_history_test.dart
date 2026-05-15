import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/database/database.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

SearchHistoryItemsCompanion _historyItem(String historyKey, String searchTerm) {
  return SearchHistoryItemsCompanion.insert(
    historyKey: historyKey,
    searchTerm: searchTerm,
    uniqueKey: '$historyKey/$searchTerm',
  );
}

void main() {
  test('search history upsert replaces duplicate terms atomically', () async {
    final db = await _openDb();

    await db.upsertSearchHistoryItem(
      _historyItem('dictionary_media_type', '猫'),
    );
    final firstRow = await db.getSearchHistoryByUniqueKey(
      'dictionary_media_type/猫',
    );

    await db.upsertSearchHistoryItem(
      _historyItem('dictionary_media_type', '猫'),
    );

    final rows = await db.getSearchHistory('dictionary_media_type');
    final secondRow = await db.getSearchHistoryByUniqueKey(
      'dictionary_media_type/猫',
    );

    expect(rows, hasLength(1));
    expect(rows.single.searchTerm, '猫');
    expect(secondRow!.id, greaterThan(firstRow!.id));
  });
}

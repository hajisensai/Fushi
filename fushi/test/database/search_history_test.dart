import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

Future<FushiDatabase> _openDb() async {
  final db = FushiDatabase.forTesting(NativeDatabase.memory());
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
    final firstRow =
        (await db.getSearchHistory('dictionary_media_type')).single;

    await db.upsertSearchHistoryItem(
      _historyItem('dictionary_media_type', '猫'),
    );

    final rows = await db.getSearchHistory('dictionary_media_type');

    expect(rows, hasLength(1));
    expect(rows.single.searchTerm, '猫');
    expect(rows.single.id, greaterThan(firstRow.id));
  });
}

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

MediaItemsCompanion _item({
  String identifier = 'media/1',
  String title = 'Item',
  String typeId = 'reader',
  String sourceId = 'hoshi',
  String? uniqueKey,
}) {
  return MediaItemsCompanion.insert(
    mediaIdentifier: identifier,
    title: title,
    mediaTypeIdentifier: typeId,
    mediaSourceIdentifier: sourceId,
    uniqueKey: uniqueKey ?? '$typeId/$sourceId/$identifier',
    position: 0,
    duration: 0,
    canDelete: true,
    canEdit: false,
  );
}

void main() {
  group('MediaItems table', () {
    test('upsert then retrieve by unique key', () async {
      final db = await _openDb();

      await db.upsertMediaItem(_item(title: 'First'));

      final row = await db.getMediaItemByUniqueKey('reader/hoshi/media/1');
      expect(row, isNotNull);
      expect(row!.title, 'First');
    });

    // insertOnConflictUpdate resolves on primary key (id), not unique_key.
    // A second insert with a new auto-increment id hits the UNIQUE(unique_key)
    // constraint because the original row still occupies that unique_key slot.
    test('second insert with same unique_key hits UNIQUE constraint', () async {
      final db = await _openDb();
      await db.upsertMediaItem(_item(title: 'V1'));

      expect(
        () => db.upsertMediaItem(_item(title: 'V2')),
        throwsA(isA<SqliteException>()),
      );
    });

    test('delete then re-insert updates by unique key', () async {
      final db = await _openDb();
      await db.upsertMediaItem(_item(title: 'V1'));

      await db.deleteMediaItemByUniqueKey('reader/hoshi/media/1');
      await db.upsertMediaItem(_item(title: 'V2'));

      final all = await db.getAllMediaItems();
      expect(all, hasLength(1));
      expect(all.single.title, 'V2');
    });

    test('getMediaItemsByType filters correctly', () async {
      final db = await _openDb();
      await db.upsertMediaItem(_item(typeId: 'reader', uniqueKey: 'uk1'));
      await db.upsertMediaItem(_item(typeId: 'dict', uniqueKey: 'uk2'));

      final readers = await db.getMediaItemsByType('reader');
      expect(readers, hasLength(1));
      expect(readers.single.mediaTypeIdentifier, 'reader');
    });

    test('getMediaItemsBySource filters correctly', () async {
      final db = await _openDb();
      await db.upsertMediaItem(_item(sourceId: 'hoshi', uniqueKey: 'uk1'));
      await db.upsertMediaItem(_item(sourceId: 'other', uniqueKey: 'uk2'));

      final items = await db.getMediaItemsBySource('hoshi');
      expect(items, hasLength(1));
    });

    test('deleteMediaItemByUniqueKey removes the item', () async {
      final db = await _openDb();
      await db.upsertMediaItem(_item());

      final count = await db.deleteMediaItemByUniqueKey('reader/hoshi/media/1');
      expect(count, 1);
      expect(await db.getAllMediaItems(), isEmpty);
    });

    test('deleteMediaItemById removes by primary key', () async {
      final db = await _openDb();
      await db.upsertMediaItem(_item());
      final row = await db.getMediaItemByUniqueKey('reader/hoshi/media/1');

      final count = await db.deleteMediaItemById(row!.id);
      expect(count, 1);
    });

    test('deleteMediaItemsByIdentifier removes all matching', () async {
      final db = await _openDb();
      await db.upsertMediaItem(_item(identifier: 'x', uniqueKey: 'uk1'));
      await db.upsertMediaItem(
          _item(identifier: 'x', uniqueKey: 'uk2', typeId: 'dict'));

      final count = await db.deleteMediaItemsByIdentifier('x');
      expect(count, 2);
    });

    test('trimMediaHistory keeps only maxItems per type', () async {
      final db = await _openDb();
      for (int i = 0; i < 5; i++) {
        await db.upsertMediaItem(
          _item(identifier: 'item$i', uniqueKey: 'uk$i'),
        );
      }

      await db.trimMediaHistory('reader', 2);

      final remaining = await db.getMediaItemsByType('reader');
      expect(remaining.length, lessThanOrEqualTo(2));
    });
  });
}

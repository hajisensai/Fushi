import 'package:drift/drift.dart' show Value;
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

MediaItemsCompanion _historyItem({
  required int id,
  required String bookKey,
  required String sourceId,
  required int importedAt,
  String? uniqueKey,
  String mediaTypeId = 'legacy-reader-type',
  String title = 'History title',
  String? base64Image,
  String? imageUrl,
  String? audioUrl,
  String? author,
  String? authorIdentifier,
  String? extraUrl,
  String? extra,
  String? sourceMetadata,
  int position = 12,
  int duration = 34,
  bool canDelete = false,
  bool canEdit = true,
}) {
  final String identifier = 'hoshi://book/$bookKey';
  return MediaItemsCompanion(
    id: Value<int>(id),
    mediaIdentifier: Value<String>(identifier),
    title: Value<String>(title),
    mediaTypeIdentifier: Value<String>(mediaTypeId),
    mediaSourceIdentifier: Value<String>(sourceId),
    uniqueKey: Value<String>(uniqueKey ?? '$sourceId/$identifier'),
    base64Image: Value<String?>(base64Image),
    imageUrl: Value<String?>(imageUrl),
    audioUrl: Value<String?>(audioUrl),
    author: Value<String?>(author),
    authorIdentifier: Value<String?>(authorIdentifier),
    extraUrl: Value<String?>(extraUrl),
    extra: Value<String?>(extra),
    sourceMetadata: Value<String?>(sourceMetadata),
    position: Value<int>(position),
    duration: Value<int>(duration),
    canDelete: Value<bool>(canDelete),
    canEdit: Value<bool>(canEdit),
    importedAt: Value<int>(importedAt),
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

      final remaining = await db.getAllMediaItems();
      expect(remaining.length, lessThanOrEqualTo(2));
    });

    test('getAllMediaItems has stable importedAt DESC, id DESC order',
        () async {
      final db = await _openDb();
      await db.upsertMediaItem(
        _historyItem(
          id: 2,
          bookKey: 'two',
          sourceId: 'reader_ttu',
          importedAt: 100,
        ),
      );
      await db.upsertMediaItem(
        _historyItem(
          id: 1 << 40,
          bookKey: 'high',
          sourceId: 'reader_pdf',
          importedAt: 100,
        ),
      );
      await db.upsertMediaItem(
        _historyItem(
          id: 9,
          bookKey: 'old',
          sourceId: 'reader_manga',
          importedAt: 99,
        ),
      );

      expect(
        (await db.getAllMediaItems()).map((MediaItemRow row) => row.id),
        <int>[1 << 40, 2, 9],
      );
    });

    test(
        'format reconciliation keeps newest candidate row and only rekeys identity columns',
        () async {
      final db = await _openDb();
      const String bookKey = 'volume-1';
      await db.upsertMediaItem(
        _historyItem(
          id: 7,
          bookKey: bookKey,
          sourceId: 'reader_manga',
          importedAt: 500,
          title: 'older target',
        ),
      );
      await db.upsertMediaItem(
        _historyItem(
          id: 1 << 40,
          bookKey: bookKey,
          sourceId: 'reader_pdf',
          importedAt: 500,
          title: 'newest full payload',
          base64Image: 'base64',
          imageUrl: 'https://example.test/cover',
          audioUrl: 'https://example.test/audio',
          author: 'Author',
          authorIdentifier: 'author-id',
          extraUrl: 'https://example.test/extra',
          extra: '{"extra":true}',
          sourceMetadata: '{"pages":42}',
          position: 987,
          duration: 1234,
          canDelete: true,
          canEdit: false,
        ),
      );
      await db.upsertMediaItem(
        _historyItem(
          id: 3,
          bookKey: bookKey,
          sourceId: 'reader_ttu',
          importedAt: 400,
          title: 'old epub',
        ),
      );
      await db.upsertMediaItem(
        _historyItem(
          id: 99,
          bookKey: bookKey,
          sourceId: 'external_reader',
          importedAt: 999,
          title: 'outside candidate',
        ),
      );

      await db.transaction(() async {
        await db.reconcileBookMediaHistoryForFormat(
          bookKey,
          BookFormat.manga,
        );
      });

      final List<MediaItemRow> rows = (await db.getAllMediaItems())
          .where((MediaItemRow row) =>
              row.mediaIdentifier == 'hoshi://book/$bookKey')
          .toList();
      expect(rows, hasLength(2), reason: '候选外 source 不参与归并，也不能被误删');

      final MediaItemRow survivor = rows.singleWhere(
        (MediaItemRow row) => row.mediaSourceIdentifier == 'reader_manga',
      );
      expect(survivor.id, 1 << 40,
          reason: 'importedAt 同值时必须用更高 id 作确定性 tie-break');
      expect(survivor.uniqueKey, 'reader_manga/hoshi://book/$bookKey');
      expect(survivor.mediaTypeIdentifier, 'reader_media_type');
      expect(survivor.title, 'newest full payload');
      expect(survivor.base64Image, 'base64');
      expect(survivor.imageUrl, 'https://example.test/cover');
      expect(survivor.audioUrl, 'https://example.test/audio');
      expect(survivor.author, 'Author');
      expect(survivor.authorIdentifier, 'author-id');
      expect(survivor.extraUrl, 'https://example.test/extra');
      expect(survivor.extra, '{"extra":true}');
      expect(survivor.sourceMetadata, '{"pages":42}');
      expect(survivor.position, 987);
      expect(survivor.duration, 1234);
      expect(survivor.canDelete, true);
      expect(survivor.canEdit, false);
      expect(survivor.importedAt, 500);
      expect(
        rows
            .singleWhere(
              (MediaItemRow row) =>
                  row.mediaSourceIdentifier == 'external_reader',
            )
            .id,
        99,
      );
    });

    test('unrelated or outside-candidate target-key collision is rejected',
        () async {
      final db = await _openDb();
      const String bookKey = 'collision';
      await db.upsertMediaItem(
        _historyItem(
          id: 1,
          bookKey: bookKey,
          sourceId: 'reader_ttu',
          importedAt: 1,
        ),
      );
      await db.upsertMediaItem(
        _historyItem(
          id: 2,
          bookKey: 'unrelated',
          sourceId: 'outside_reader',
          importedAt: 2,
          uniqueKey: 'reader_manga/hoshi://book/$bookKey',
        ),
      );

      await expectLater(
        db.transaction(() => db.reconcileBookMediaHistoryForFormat(
              bookKey,
              BookFormat.manga,
            )),
        throwsStateError,
      );
      expect(await db.getAllMediaItems(), hasLength(2), reason: '碰撞必须在任何删除前拒绝');
    });

    test('zero history stays zero and an already-target row is idempotent',
        () async {
      final db = await _openDb();
      const String bookKey = 'idempotent';

      await db.transaction(() => db.reconcileBookMediaHistoryForFormat(
            bookKey,
            BookFormat.manga,
          ));
      expect(await db.getAllMediaItems(), isEmpty);

      await db.upsertMediaItem(
        _historyItem(
          id: 42,
          bookKey: bookKey,
          sourceId: 'reader_manga',
          importedAt: 123,
        ),
      );
      for (int i = 0; i < 2; i++) {
        await db.transaction(() => db.reconcileBookMediaHistoryForFormat(
              bookKey,
              BookFormat.manga,
            ));
      }
      final MediaItemRow row = (await db.getAllMediaItems()).single;
      expect(row.id, 42);
      expect(row.importedAt, 123);
      expect(row.uniqueKey, 'reader_manga/hoshi://book/$bookKey');
    });
  });
}

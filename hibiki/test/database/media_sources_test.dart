import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

MediaSourcesCompanion _source({
  String label = 'Folder',
  String mediaKind = 'book',
  String rootPath = '/srv/media',
  int sortOrder = 0,
}) =>
    MediaSourcesCompanion.insert(
      label: label,
      mediaKind: mediaKind,
      rootPath: rootPath,
      createdAt: 1000,
      sortOrder: Value(sortOrder),
    );

void main() {
  group('MediaSources table', () {
    test('insert returns id and getById round-trips with defaults', () async {
      final db = await _openDb();
      final id = await db.insertMediaSource(_source());
      expect(id, greaterThan(0));

      final row = await db.getMediaSourceById(id);
      expect(row, isNotNull);
      expect(row!.label, 'Folder');
      expect(row.mediaKind, 'book');
      expect(row.rootPath, '/srv/media');
      // Defaults (TODO-817): local transport, recursive, zero media count,
      // null config (no credentials), null scan timestamps.
      expect(row.transport, 'local');
      expect(row.recursive, isTrue);
      expect(row.mediaCount, 0);
      expect(row.configJson, isNull);
      expect(row.lastScannedAt, isNull);
      expect(row.lastScanError, isNull);
    });

    test('getById returns null for missing id', () async {
      final db = await _openDb();
      expect(await db.getMediaSourceById(999), isNull);
    });

    test('getAllMediaSources orders by sortOrder then id', () async {
      final db = await _openDb();
      final idB = await db
          .insertMediaSource(_source(label: 'B', sortOrder: 5, rootPath: '/b'));
      final idA = await db
          .insertMediaSource(_source(label: 'A', sortOrder: 1, rootPath: '/a'));
      final idC = await db
          .insertMediaSource(_source(label: 'C', sortOrder: 1, rootPath: '/c'));

      final all = await db.getAllMediaSources();
      expect(all.map((r) => r.label).toList(), ['A', 'C', 'B']);
      // Same sortOrder (1): A inserted before C, so id tiebreak keeps A first.
      expect(all[0].id, idA);
      expect(all[1].id, idC);
      expect(all[2].id, idB);
    });

    test('getMediaSourcesByKind filters by mediaKind', () async {
      final db = await _openDb();
      await db.insertMediaSource(
          _source(label: 'Book1', mediaKind: 'book', rootPath: '/b1'));
      await db.insertMediaSource(
          _source(label: 'Vid1', mediaKind: 'video', rootPath: '/v1'));
      await db.insertMediaSource(
          _source(label: 'Book2', mediaKind: 'book', rootPath: '/b2'));

      final books = await db.getMediaSourcesByKind('book');
      expect(books.map((r) => r.label).toSet(), {'Book1', 'Book2'});
      final videos = await db.getMediaSourcesByKind('video');
      expect(videos.map((r) => r.label).toList(), ['Vid1']);
    });

    test('updateMediaSourceScanResult writes through', () async {
      final db = await _openDb();
      final id = await db.insertMediaSource(_source());
      final scannedAt = DateTime.fromMillisecondsSinceEpoch(1700000000000);

      await db.updateMediaSourceScanResult(
        id: id,
        mediaCount: 42,
        lastScannedAt: scannedAt,
        lastScanError: 'partial',
      );
      final row = await db.getMediaSourceById(id);
      expect(row!.mediaCount, 42);
      expect(row.lastScannedAt, scannedAt);
      expect(row.lastScanError, 'partial');
    });

    test('updateMediaSourceLabel writes through', () async {
      final db = await _openDb();
      final id = await db.insertMediaSource(_source(label: 'Old'));
      await db.updateMediaSourceLabel(id, 'New');
      final row = await db.getMediaSourceById(id);
      expect(row!.label, 'New');
    });

    test('upsertMediaSource updates in place by id (no duplicate)', () async {
      final db = await _openDb();
      final id = await db.insertMediaSource(_source(label: 'V1'));
      await db.upsertMediaSource(MediaSourcesCompanion(
        id: Value(id),
        label: const Value('V2'),
        mediaKind: const Value('book'),
        rootPath: const Value('/srv/media'),
        createdAt: const Value(1000),
      ));
      final all = await db.getAllMediaSources();
      expect(all, hasLength(1));
      expect(all.single.label, 'V2');
    });

    test('deleteMediaSource removes the row', () async {
      final db = await _openDb();
      final id = await db.insertMediaSource(_source());
      expect(await db.getAllMediaSources(), hasLength(1));
      final removed = await db.deleteMediaSource(id);
      expect(removed, 1);
      expect(await db.getAllMediaSources(), isEmpty);
    });
  });
}

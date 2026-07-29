import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/media_item.dart';
import 'package:hibiki/src/models/media_history_repository.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

MediaItem _item({
  String mediaIdentifier = 'id-1',
  String title = 'Title',
  String mediaTypeIdentifier = 'reader',
  String mediaSourceIdentifier = 'hoshi',
  int position = 0,
  int duration = 100,
  bool canDelete = true,
  bool canEdit = false,
}) {
  return MediaItem(
    mediaIdentifier: mediaIdentifier,
    title: title,
    mediaTypeIdentifier: mediaTypeIdentifier,
    mediaSourceIdentifier: mediaSourceIdentifier,
    position: position,
    duration: duration,
    canDelete: canDelete,
    canEdit: canEdit,
  );
}

Future<void> _seedBook(HibikiDatabase db, String bookKey) async {
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: 'Book $bookKey',
      epubPath: 'book.epub',
      extractDir: '/books/$bookKey',
      chapterCount: 10,
      chaptersJson: '["chapter"]',
      importedAt: 100,
    ),
  );
}

MediaItemsCompanion _bookHistory({
  required int id,
  required String bookKey,
  required String source,
  required int importedAt,
  String title = 'History',
}) {
  final String identifier = 'hoshi://book/$bookKey';
  return MediaItemsCompanion(
    id: Value<int>(id),
    mediaIdentifier: Value<String>(identifier),
    title: Value<String>(title),
    mediaTypeIdentifier: const Value<String>('reader_media_type'),
    mediaSourceIdentifier: Value<String>(source),
    uniqueKey: Value<String>('$source/$identifier'),
    base64Image: const Value<String?>('base64'),
    imageUrl: const Value<String?>('image'),
    audioUrl: const Value<String?>('audio'),
    author: const Value<String?>('author'),
    authorIdentifier: const Value<String?>('author-id'),
    extraUrl: const Value<String?>('extra-url'),
    extra: const Value<String?>('extra'),
    sourceMetadata: const Value<String?>('metadata'),
    position: const Value<int>(321),
    duration: const Value<int>(654),
    canDelete: const Value<bool>(true),
    canEdit: const Value<bool>(false),
    importedAt: Value<int>(importedAt),
  );
}

void main() {
  late HibikiDatabase db;
  late MediaHistoryRepository repo;

  setUp(() async {
    db = _testDb();
    repo = MediaHistoryRepository(db);
    await repo.loadFromDb();
  });

  tearDown(() async {
    await _settle();
    repo.dispose();
    await db.close();
  });

  // ── media item CRUD ──────────────────────────────────────────────────

  group('media item CRUD', () {
    test('addMediaItem inserts item at front of cache', () {
      final item = _item();
      repo.addMediaItem(item);
      expect(repo.mediaItems.first.mediaIdentifier, 'id-1');
    });

    test('addMediaItem deduplicates by uniqueKey', () async {
      repo.addMediaItem(_item(title: 'v1'));
      await _settle();
      repo.addMediaItem(_item(title: 'v2'));
      await _settle();
      final items =
          repo.mediaItems.where((m) => m.mediaIdentifier == 'id-1').toList();
      expect(items.length, 1);
      expect(items.first.title, 'v2');
    });

    test('addMediaItem persists to DB and reloads', () async {
      repo.addMediaItem(_item());
      await _settle();

      final repo2 = MediaHistoryRepository(db);
      await repo2.loadFromDb();
      expect(repo2.mediaItems.length, 1);
      expect(repo2.mediaItems.first.mediaIdentifier, 'id-1');
      repo2.dispose();
    });

    test('updateMediaItem updates cache entry in place', () async {
      repo.addMediaItem(_item(position: 0));
      await _settle();
      final existing = repo.mediaItems.first;
      final updated = _item(position: 50)..id = existing.id;
      repo.updateMediaItem(updated);
      final found = repo.mediaItems.firstWhere(
        (m) => m.mediaIdentifier == 'id-1',
      );
      expect(found.position, 50);
    });

    test('updateMediaItem persists to DB', () async {
      repo.addMediaItem(_item(position: 0));
      await _settle();
      final existing = repo.mediaItems.first;
      final updated = _item(position: 75)..id = existing.id;
      repo.updateMediaItem(updated);
      await _settle();

      final repo2 = MediaHistoryRepository(db);
      await repo2.loadFromDb();
      expect(repo2.mediaItems.first.position, 75);
      repo2.dispose();
    });

    test('removeFromReadingList removes by mediaIdentifier', () {
      repo.addMediaItem(_item(mediaIdentifier: 'a'));
      repo.addMediaItem(_item(mediaIdentifier: 'b'));
      repo.removeFromReadingList('a');
      expect(
        repo.mediaItems.any((m) => m.mediaIdentifier == 'a'),
        false,
      );
      expect(
        repo.mediaItems.any((m) => m.mediaIdentifier == 'b'),
        true,
      );
    });

    test('deleteMediaItemById removes by id', () async {
      repo.addMediaItem(_item());
      await _settle();
      final item = repo.mediaItems.first;
      expect(item.id, isNotNull);
      await repo.deleteMediaItemById(item);
      expect(repo.mediaItems, isEmpty);
    });

    test('deleteMediaItemById with null id only clears cache', () async {
      final item = _item();
      expect(item.id, isNull);
      repo.addMediaItem(item);
      await repo.deleteMediaItemById(item);
      expect(
        repo.mediaItems.where((m) => m.id == null),
        isEmpty,
      );
    });
  });

  group('atomic book format and history coordination', () {
    test('commit swaps full-payload cache and notifies only after DB commit',
        () async {
      const String bookKey = 'atomic-success';
      await _seedBook(db, bookKey);
      await db.upsertMediaItem(
        _bookHistory(
          id: 10,
          bookKey: bookKey,
          source: 'reader_ttu',
          importedAt: 100,
          title: 'older',
        ),
      );
      await db.upsertMediaItem(
        _bookHistory(
          id: 1 << 40,
          bookKey: bookKey,
          source: 'reader_pdf',
          importedAt: 100,
          title: 'survivor',
        ),
      );
      await repo.loadFromDb();
      int notifications = 0;
      repo.addListener(() => notifications++);

      await repo.applyBookFormatConversion(
        bookKey: bookKey,
        format: BookFormat.manga,
        epubPath: 'manga.json',
        chapterCount: 80,
        chaptersJson: '[]',
        coverPath: 'images/page_0001.png',
      );

      expect((await db.getEpubBook(bookKey))!.format, 'manga');
      expect(await db.getAllMediaItems(), hasLength(1));
      expect(notifications, 1);
      final MediaItem cached = repo.mediaItems.single;
      expect(cached.id, 1 << 40);
      expect(cached.mediaSourceIdentifier, 'reader_manga');
      expect(cached.mediaTypeIdentifier, 'reader_media_type');
      expect(cached.title, 'survivor');
      expect(cached.base64Image, 'base64');
      expect(cached.imageUrl, 'image');
      expect(cached.audioUrl, 'audio');
      expect(cached.author, 'author');
      expect(cached.authorIdentifier, 'author-id');
      expect(cached.extraUrl, 'extra-url');
      expect(cached.extra, 'extra');
      expect(cached.sourceMetadata, 'metadata');
      expect(cached.position, 321);
      expect(cached.duration, 654);
      expect(cached.canDelete, true);
      expect(cached.canEdit, false);
    });

    test('fault after duplicate deletion rolls back format, rows, and cache',
        () async {
      const String bookKey = 'atomic-rollback';
      await _seedBook(db, bookKey);
      await db.upsertMediaItem(
        _bookHistory(
          id: 20,
          bookKey: bookKey,
          source: 'reader_ttu',
          importedAt: 10,
          title: 'old',
        ),
      );
      await db.upsertMediaItem(
        _bookHistory(
          id: 21,
          bookKey: bookKey,
          source: 'reader_pdf',
          importedAt: 20,
          title: 'new',
        ),
      );
      await repo.loadFromDb();
      final List<(int?, String, String)> cacheBefore = repo.mediaItems
          .map((MediaItem item) => (
                item.id,
                item.mediaSourceIdentifier,
                item.title,
              ))
          .toList();
      int notifications = 0;
      repo.addListener(() => notifications++);

      await expectLater(
        repo.applyBookFormatConversion(
          bookKey: bookKey,
          format: BookFormat.manga,
          epubPath: 'manga.json',
          chapterCount: 80,
          chaptersJson: '[]',
          afterHistoryDuplicatesDeletedForTesting: () async {
            expect((await db.getEpubBook(bookKey))!.format, 'manga',
                reason: '故障点必须位于 format 更新之后');
            final List<MediaItemRow> midRows = await db.getAllMediaItems();
            expect(midRows, hasLength(1), reason: '故障点必须位于 non-survivor 删除之后');
            expect(midRows.single.mediaSourceIdentifier, 'reader_pdf',
                reason: '故障点必须位于 survivor rekey 之前');
            throw StateError('injected after delete, before rekey');
          },
        ),
        throwsStateError,
      );

      expect((await db.getEpubBook(bookKey))!.format, 'epub');
      expect(await db.getAllMediaItems(), hasLength(2));
      expect(
        repo.mediaItems
            .map((MediaItem item) => (
                  item.id,
                  item.mediaSourceIdentifier,
                  item.title,
                ))
            .toList(),
        cacheBefore,
      );
      expect(notifications, 0, reason: '失败事务绝不能发布临时 cache');
    });

    test('zero stays zero and manga-book conversion is idempotent both ways',
        () async {
      const String emptyKey = 'zero-history';
      await _seedBook(db, emptyKey);
      await repo.applyBookFormatConversion(
        bookKey: emptyKey,
        format: BookFormat.manga,
        epubPath: 'manga.json',
        chapterCount: 5,
        chaptersJson: '[]',
      );
      expect(repo.mediaItems, isEmpty);

      const String bookKey = 'round-trip';
      await _seedBook(db, bookKey);
      await db.upsertMediaItem(
        _bookHistory(
          id: 77,
          bookKey: bookKey,
          source: 'reader_pdf',
          importedAt: 700,
        ),
      );
      await repo.loadFromDb();

      for (int i = 0; i < 2; i++) {
        await repo.applyBookFormatConversion(
          bookKey: bookKey,
          format: BookFormat.manga,
          epubPath: 'manga.json',
          chapterCount: 100,
          chaptersJson: '[]',
        );
      }
      expect(repo.mediaItems.single.id, 77);
      expect(repo.mediaItems.single.mediaSourceIdentifier, 'reader_manga');

      for (int i = 0; i < 2; i++) {
        await repo.applyBookFormatConversion(
          bookKey: bookKey,
          format: BookFormat.pdf,
          epubPath: 'book.pdf',
          chapterCount: 10,
          chaptersJson: '[]',
        );
      }
      expect(repo.mediaItems.single.id, 77);
      expect(repo.mediaItems.single.mediaSourceIdentifier, 'reader_pdf');
      expect((await db.getAllMediaItems()).single.id, 77);
      expect((await db.getEpubBook(bookKey))!.format, 'pdf');
    });
  });

  // ── media item queries ───────────────────────────────────────────────

  group('media item queries', () {
    test('getMediaTypeHistory filters by mediaTypeIdentifier', () {
      repo.addMediaItem(_item(
        mediaIdentifier: 'a',
        mediaTypeIdentifier: 'reader',
      ));
      repo.addMediaItem(_item(
        mediaIdentifier: 'b',
        mediaTypeIdentifier: 'player',
      ));
      final readers = repo.getMediaTypeHistory(mediaTypeKey: 'reader');
      expect(readers.length, 1);
      expect(readers.first.mediaIdentifier, 'a');
    });

    test('getMediaSourceHistory filters by mediaSourceIdentifier', () {
      repo.addMediaItem(_item(
        mediaIdentifier: 'a',
        mediaSourceIdentifier: 'hoshi',
      ));
      repo.addMediaItem(_item(
        mediaIdentifier: 'b',
        mediaSourceIdentifier: 'local',
      ));
      final hoshi = repo.getMediaSourceHistory(mediaSourceKey: 'hoshi');
      expect(hoshi.length, 1);
      expect(hoshi.first.mediaIdentifier, 'a');
    });

    test('empty repo returns empty lists for queries', () {
      expect(repo.getMediaTypeHistory(mediaTypeKey: 'reader'), isEmpty);
      expect(repo.getMediaSourceHistory(mediaSourceKey: 'hoshi'), isEmpty);
    });
  });

  // ── search history ───────────────────────────────────────────────────

  group('search history', () {
    test('addToSearchHistory stores term', () {
      repo.addToSearchHistory(historyKey: 'dict', searchTerm: '猫');
      expect(repo.getSearchHistory(historyKey: 'dict'), ['猫']);
    });

    test('addToSearchHistory ignores empty/whitespace terms', () {
      repo.addToSearchHistory(historyKey: 'dict', searchTerm: '');
      repo.addToSearchHistory(historyKey: 'dict', searchTerm: '   ');
      expect(repo.getSearchHistory(historyKey: 'dict'), isEmpty);
    });

    test('addToSearchHistory deduplicates and moves to end', () {
      repo.addToSearchHistory(historyKey: 'dict', searchTerm: 'a');
      repo.addToSearchHistory(historyKey: 'dict', searchTerm: 'b');
      repo.addToSearchHistory(historyKey: 'dict', searchTerm: 'a');
      expect(repo.getSearchHistory(historyKey: 'dict'), ['b', 'a']);
    });

    test('addToSearchHistory trims oldest when exceeding max', () {
      final repo3 = MediaHistoryRepository(db, maximumSearchHistoryItems: 3);
      repo3.addToSearchHistory(historyKey: 'k', searchTerm: 'a');
      repo3.addToSearchHistory(historyKey: 'k', searchTerm: 'b');
      repo3.addToSearchHistory(historyKey: 'k', searchTerm: 'c');
      repo3.addToSearchHistory(historyKey: 'k', searchTerm: 'd');
      final history = repo3.getSearchHistory(historyKey: 'k');
      expect(history, ['b', 'c', 'd']);
      expect(history.contains('a'), false);
      repo3.dispose();
    });

    test('addToSearchHistory persists to DB', () async {
      repo.addToSearchHistory(historyKey: 'dict', searchTerm: '本');
      await _settle();

      final repo2 = MediaHistoryRepository(db);
      await repo2.loadFromDb();
      expect(repo2.getSearchHistory(historyKey: 'dict'), contains('本'));
      repo2.dispose();
    });

    test('removeFromSearchHistory removes term', () async {
      repo.addToSearchHistory(historyKey: 'dict', searchTerm: '猫');
      repo.addToSearchHistory(historyKey: 'dict', searchTerm: '犬');
      await _settle();
      await repo.removeFromSearchHistory(
        historyKey: 'dict',
        searchTerm: '猫',
      );
      expect(repo.getSearchHistory(historyKey: 'dict'), ['犬']);
    });

    test('clearSearchHistory removes all terms for key', () {
      repo.addToSearchHistory(historyKey: 'dict', searchTerm: 'a');
      repo.addToSearchHistory(historyKey: 'dict', searchTerm: 'b');
      repo.addToSearchHistory(historyKey: 'other', searchTerm: 'c');
      repo.clearSearchHistory(historyKey: 'dict');
      expect(repo.getSearchHistory(historyKey: 'dict'), isEmpty);
      expect(repo.getSearchHistory(historyKey: 'other'), ['c']);
    });

    test('isTermInSearchHistory returns correct result', () {
      repo.addToSearchHistory(historyKey: 'dict', searchTerm: '猫');
      expect(
        repo.isTermInSearchHistory(historyKey: 'dict', searchTerm: '猫'),
        true,
      );
      expect(
        repo.isTermInSearchHistory(historyKey: 'dict', searchTerm: '犬'),
        false,
      );
      expect(
        repo.isTermInSearchHistory(historyKey: 'nope', searchTerm: '猫'),
        false,
      );
    });

    test('getSearchHistory returns unmodifiable list', () {
      repo.addToSearchHistory(historyKey: 'k', searchTerm: 'x');
      final list = repo.getSearchHistory(historyKey: 'k');
      expect(() => list.add('y'), throwsUnsupportedError);
    });

    test('separate history keys are independent', () {
      repo.addToSearchHistory(historyKey: 'a', searchTerm: 'term1');
      repo.addToSearchHistory(historyKey: 'b', searchTerm: 'term2');
      expect(repo.getSearchHistory(historyKey: 'a'), ['term1']);
      expect(repo.getSearchHistory(historyKey: 'b'), ['term2']);
    });
  });

  // ── stash ────────────────────────────────────────────────────────────

  group('stash', () {
    test('addToStashData adds terms to stash key', () {
      repo.addToStashData(terms: ['猫', '犬']);
      expect(repo.getStash(), ['猫', '犬']);
    });

    test('addToStashData skips empty terms', () {
      repo.addToStashData(terms: ['猫', '', '  ', '犬']);
      expect(repo.getStash(), ['猫', '犬']);
    });

    test('removeFromStashData removes single term', () async {
      repo.addToStashData(terms: ['a', 'b', 'c']);
      await _settle();
      await repo.removeFromStashData(term: 'b');
      expect(repo.getStash(), ['a', 'c']);
    });

    test('clearStash empties all stash terms', () {
      repo.addToStashData(terms: ['x', 'y']);
      repo.clearStash();
      expect(repo.getStash(), isEmpty);
    });

    test('isTermInStash checks stash key', () {
      repo.addToStashData(terms: ['猫']);
      expect(repo.isTermInStash('猫'), true);
      expect(repo.isTermInStash('犬'), false);
    });

    test('stash is independent from other search history keys', () {
      repo.addToStashData(terms: ['stash-term']);
      repo.addToSearchHistory(historyKey: 'dict', searchTerm: 'dict-term');
      expect(repo.getStash(), ['stash-term']);
      expect(repo.getSearchHistory(historyKey: 'dict'), ['dict-term']);
    });
  });

  // ── loadFromDb hydration ─────────────────────────────────────────────

  group('loadFromDb', () {
    test('hydrates media items from DB', () async {
      repo.addMediaItem(_item(title: 'Book A'));
      await _settle();

      final repo2 = MediaHistoryRepository(db);
      expect(repo2.mediaItems, isEmpty);
      await repo2.loadFromDb();
      expect(repo2.mediaItems.length, 1);
      expect(repo2.mediaItems.first.title, 'Book A');
      repo2.dispose();
    });

    test('hydrates search history from DB', () async {
      repo.addToSearchHistory(historyKey: 'k1', searchTerm: 'term1');
      repo.addToSearchHistory(historyKey: 'k2', searchTerm: 'term2');
      await _settle();

      final repo2 = MediaHistoryRepository(db);
      await repo2.loadFromDb();
      expect(repo2.getSearchHistory(historyKey: 'k1'), contains('term1'));
      expect(repo2.getSearchHistory(historyKey: 'k2'), contains('term2'));
      repo2.dispose();
    });

    test('mediaItems list is unmodifiable', () {
      repo.addMediaItem(_item());
      expect(() => repo.mediaItems.add(_item()), throwsUnsupportedError);
    });
  });

  // ── row conversion ───────────────────────────────────────────────────

  group('row conversion round-trip', () {
    test('all MediaItem fields survive add → loadFromDb', () async {
      final item = MediaItem(
        mediaIdentifier: 'mid',
        title: 'タイトル',
        mediaTypeIdentifier: 'reader',
        mediaSourceIdentifier: 'hoshi',
        position: 42,
        duration: 999,
        canDelete: true,
        canEdit: true,
        base64Image: 'abc123',
        imageUrl: 'https://img.example.com/cover.jpg',
        audioUrl: 'https://audio.example.com/track.mp3',
        author: '作者',
        authorIdentifier: 'author-id',
        extraUrl: 'https://extra.example.com',
        extra: '{"key":"value"}',
        sourceMetadata: '{"chapters":10}',
      );
      repo.addMediaItem(item);
      await _settle();

      final repo2 = MediaHistoryRepository(db);
      await repo2.loadFromDb();
      final loaded = repo2.mediaItems.first;
      expect(loaded.mediaIdentifier, 'mid');
      expect(loaded.title, 'タイトル');
      expect(loaded.mediaTypeIdentifier, 'reader');
      expect(loaded.mediaSourceIdentifier, 'hoshi');
      expect(loaded.position, 42);
      expect(loaded.duration, 999);
      expect(loaded.canDelete, true);
      expect(loaded.canEdit, true);
      expect(loaded.base64Image, 'abc123');
      expect(loaded.imageUrl, 'https://img.example.com/cover.jpg');
      expect(loaded.audioUrl, 'https://audio.example.com/track.mp3');
      expect(loaded.author, '作者');
      expect(loaded.authorIdentifier, 'author-id');
      expect(loaded.extraUrl, 'https://extra.example.com');
      expect(loaded.extra, '{"key":"value"}');
      expect(loaded.sourceMetadata, '{"chapters":10}');
      repo2.dispose();
    });
  });
}

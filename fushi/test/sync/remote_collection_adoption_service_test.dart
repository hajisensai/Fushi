import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/collection_sync_engine.dart';
import 'package:fushi_engine/sync/remote_collection_adoption_service.dart';

void main() {
  late FushiDatabase db;
  late RemoteCollectionAdoptionService service;
  const RemoteCollectionMembership collection = RemoteCollectionMembership(
    collectionName: 'Series',
    collectionType: 'playlist',
    sortIndex: 5,
  );
  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    service = RemoteCollectionAdoptionService(db);
  });
  tearDown(() => db.close());
  Future<EpubBookRow> insertBook(String key, {bool online = false}) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: 'book.epub',
        extractDir: '/tmp/$key',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
        sourceMetadata: online
            ? Value(
                jsonEncode({
                  'type': 'hibiki-online-manga',
                  'version': 3,
                  'runtime': 'interconnect',
                  'extensionPackage': 'fushi.interconnect',
                  'sourceId': 'library',
                  'series': {'key': 'remote'},
                }),
              )
            : const Value.absent(),
      ),
    );
    return (await db.getEpubBook(key))!;
  }

  test(
    'video directory and repeated download use the stable video ID',
    () async {
      const RemoteVideoInfo video = RemoteVideoInfo(
        id: 'video-id',
        title: 'Video',
        collection: collection,
      );
      await service.adoptVideo(video);
      await service.adoptVideo(video);
      expect((await db.getAllCollectionItems()).single.entryKey, video.id);
    },
  );
  for (final String format in ['epub', 'manga']) {
    test(
      '$format placeholder promotes using actual imported row UID',
      () async {
        final RemoteBookInfo book = RemoteBookInfo(
          title: 'Remote',
          bookKey: 'remote',
          hasContent: true,
          format: format,
          collection: collection,
        );
        await service.adoptBook(book);
        expect((await db.getAllCollectionItems()).single.entryKey, 'remote');
        final EpubBookRow row = await insertBook('remote');
        await service.adoptBook(book, localBook: row);
        await service.adoptBook(book);
        expect((await db.getAllCollectionItems()).single.entryKey, row.uid);
        expect(await db.getAllCollectionMemberTombstones(), isEmpty);
      },
    );
  }
  test(
    'online manga refresh heals existing hashed orphan and never recreates placeholder',
    () async {
      final EpubBookRow row = await insertBook('local-hash', online: true);
      const RemoteBookInfo book = RemoteBookInfo(
        title: 'Remote',
        bookKey: 'remote',
        hasContent: false,
        hasMangaChapters: true,
        format: 'manga',
        collection: collection,
      );
      await service.adoptBook(book);
      await service.adoptBook(book);
      expect((await db.getAllCollectionItems()).single.entryKey, row.uid);
    },
  );
  test(
    'missing membership is a no-op and never removes other relationships',
    () async {
      final EpubBookRow row = await insertBook('remote');
      final int other = await db.createMediaCollection('Other');
      await db.addToCollection(other, MediaKind.epub, row.uid);
      await service.adoptBook(
        const RemoteBookInfo(
          title: 'Remote',
          bookKey: 'remote',
          hasContent: true,
        ),
      );
      expect((await db.getAllCollectionItems()).single.collectionId, other);
    },
  );
  test(
    'different imported key remains promoted after refresh and full sync',
    () async {
      const RemoteBookInfo book = RemoteBookInfo(
        title: 'Remote',
        bookKey: 'remote',
        hasContent: true,
        collection: collection,
      );
      await service.adoptBook(book);
      final EpubBookRow row = await insertBook('actual-imported-key');
      await service.adoptBook(book, localBook: row);
      await service.adoptBook(book);
      expect((await db.getAllCollectionItems()).single.entryKey, row.uid);
      final CollectionManifest local = await loadLocalCollectionManifest(db);
      expect(local.collections.single.members.single.entryKey, 'remote');
      await applyCollectionLocalChanges(
        db,
        CollectionLocalChanges(local.collections),
      );
      expect((await db.getAllCollectionItems()).single.entryKey, row.uid);
      await db.removeFromCollection(
        (await db.getAllMediaCollections()).single.id,
        MediaKind.epub,
        row.uid,
      );
      await service.adoptBook(book);
      expect(await db.getAllCollectionItems(), isEmpty);
      expect(
        (await db.getAllCollectionMemberTombstones()).single.entryKey,
        'remote',
      );
    },
  );
}

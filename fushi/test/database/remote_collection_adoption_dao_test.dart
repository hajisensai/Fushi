import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase db;
  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());
  Future<int?> adopt(
    String remote,
    int index, {
    String? local,
    MediaKind kind = MediaKind.video,
  }) => db.adoptRemoteCollectionMember(
    name: 'Series',
    collectionType: 'collection',
    mediaType: kind,
    remoteEntryKey: remote,
    sortIndex: index,
    localEntryKey: local,
  );

  test('concurrent adoption creates one shell with remote order', () async {
    final List<int?> ids = await Future.wait(<Future<int?>>[
      adopt('episode-2', 20),
      adopt('episode-1', 10),
      adopt('episode-2', 99),
    ]);
    expect(ids.toSet(), hasLength(1));
    expect(await db.getAllMediaCollections(), hasLength(1));
    final List<MediaCollectionItemRow> rows = await db.getCollectionItems(
      ids.first!,
    );
    expect(rows.map((MediaCollectionItemRow r) => r.entryKey), [
      'episode-1',
      'episode-2',
    ]);
    expect(rows.map((MediaCollectionItemRow r) => r.sortIndex), [10, 20]);
  });
  test(
    'natural key reuses minimum ID without changing other memberships',
    () async {
      final int first = await db.createMediaCollection('Series');
      final int duplicate = await db
          .into(db.mediaCollections)
          .insert(
            MediaCollectionsCompanion.insert(name: 'Series', createdAt: 1),
          );
      final int other = await db.createMediaCollection('Other');
      await db.addToCollection(other, MediaKind.video, 'local');
      expect(await adopt('wire', 3, local: 'local'), first);
      expect(await db.getCollectionItems(duplicate), isEmpty);
      expect((await db.getCollectionItems(other)).single.entryKey, 'local');
    },
  );
  test('promotion preserves manual slot and appends new entries', () async {
    final int cid = (await adopt('wire', 10))!;
    await adopt('second', 20);
    await db.setCollectionOrderUpdatedAt(cid, 123);
    await adopt('wire', -10, local: 'local');
    await adopt('third', -20);
    final List<MediaCollectionItemRow> rows = await db.getCollectionItems(cid);
    expect(rows.map((MediaCollectionItemRow r) => r.entryKey), [
      'local',
      'second',
      'third',
    ]);
    expect(rows.map((MediaCollectionItemRow r) => r.sortIndex), [10, 20, 21]);
    expect((await db.getMediaCollectionById(cid))!.orderUpdatedAt, 123);
    expect(await db.getAllCollectionMemberTombstones(), isEmpty);
  });
  test(
    'promotion preserves existing local order and removes only matching wire',
    () async {
      final int cid = (await adopt('wire', 10))!;
      await db.upsertCollectionItemAt(cid, 'video', 'local', 2);
      await adopt('other-wire', 30);
      await Future.wait(
        List<Future<int?>>.generate(
          5,
          (int _) => adopt('wire', 99, local: 'local'),
        ),
      );
      final List<MediaCollectionItemRow> rows = await db.getCollectionItems(
        cid,
      );
      expect(rows.map((MediaCollectionItemRow r) => r.entryKey), [
        'local',
        'other-wire',
      ]);
      expect(rows.first.sortIndex, 2);
      expect(await db.getAllCollectionMemberTombstones(), isEmpty);
    },
  );
  for (final String key in <String>['', 'wire', 'local']) {
    test(
      'tombstone for ${key.isEmpty ? 'collection' : key} blocks adoption',
      () async {
        await db.upsertCollectionMemberTombstone(
          collectionName: 'Series',
          deletedAt: 1,
          collectionType: 'collection',
          mediaType: key.isEmpty
              ? FushiDatabase.collectionTombstoneSentinel
              : 'video',
          entryKey: key,
        );
        expect(await adopt('wire', 0, local: 'local'), isNull);
        expect(await db.getAllMediaCollections(), isEmpty);
        expect(
          (await db.getAllCollectionMemberTombstones()).single.entryKey,
          key,
        );
      },
    );
  }
  test(
    'EPUB local bookKey tombstone blocks differing remote identity',
    () async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'local-book-key',
          title: 'Comic',
          epubPath: '/comic.epub',
          extractDir: '/comic',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1,
          uid: const Value<String>('local-uid'),
        ),
      );
      await db.upsertCollectionMemberTombstone(
        collectionName: 'Series',
        deletedAt: 1,
        collectionType: 'collection',
        mediaType: 'epub',
        entryKey: 'local-book-key',
      );
      expect(
        await adopt(
          'remote-book-key',
          0,
          local: 'local-uid',
          kind: MediaKind.epub,
        ),
        isNull,
      );
      expect(await db.getAllMediaCollections(), isEmpty);
      expect(await db.getAllCollectionMemberTombstones(), hasLength(1));
    },
  );
  test(
    'online manga removal records canonical wire key but local lookup stays local',
    () async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'local-hash',
          uid: const Value<String>('comic-uid'),
          title: 'Comic',
          epubPath: '/comic.epub',
          extractDir: '/comic',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1,
          sourceMetadata: const Value<String>(
            '{'
            '"type":"hibiki-online-manga",'
            '"version":3,"runtime":"interconnect","extensionPackage":"fushi.interconnect",'
            '"sourceId":"library","series":{"key":"canonical-wire"}}',
          ),
        ),
      );
      final int cid = (await adopt(
        'canonical-wire',
        0,
        local: 'comic-uid',
        kind: MediaKind.epub,
      ))!;
      await db.removeFromCollection(cid, MediaKind.epub, 'comic-uid');
      expect(
        (await db.getAllCollectionMemberTombstones()).single.entryKey,
        'canonical-wire',
      );
      expect(await db.resolveEpubBookKeyByUid('comic-uid'), 'local-hash');
      expect(
        await adopt(
          'canonical-wire',
          0,
          local: 'comic-uid',
          kind: MediaKind.epub,
        ),
        isNull,
      );
    },
  );
  test(
    'persisted aliases keep first canonical identity and cannot steal live books',
    () async {
      for (final String uid in <String>['a', 'b']) {
        await db.insertEpubBook(
          EpubBooksCompanion.insert(
            bookKey: 'key-$uid',
            uid: Value<String>(uid),
            title: uid,
            epubPath: '/$uid.epub',
            extractDir: '/$uid',
            chapterCount: 1,
            chaptersJson: '[]',
            importedAt: 1,
          ),
        );
      }
      await db.setCollectionBookAlias('a', 'wire');
      await db.setCollectionBookAlias('a', 'different');
      await db.setCollectionBookAlias('b', 'wire');
      await db.setCollectionBookAlias('missing', 'ghost');
      expect(await db.getCollectionBookAliases(), <String, String>{
        'wire': 'a',
      });
      final int cid = (await adopt(
        'wire',
        0,
        local: 'a',
        kind: MediaKind.epub,
      ))!;
      await db.removeFromCollection(cid, MediaKind.epub, 'a');
      expect(
        (await db.getAllCollectionMemberTombstones()).single.entryKey,
        'wire',
      );
      await db.deleteEpubBook('key-a');
      expect(await db.getCollectionBookAliases(), isEmpty);
      expect(
        await db.customSelect('SELECT * FROM collection_book_aliases').get(),
        isEmpty,
      );
      await db.setCollectionBookAlias('b', 'wire');
      expect(await db.getCollectionBookAliases(), <String, String>{
        'wire': 'b',
      });
    },
  );
  test(
    'stale aliases are hidden and reclaimed without stealing valid identities',
    () async {
      await db.customStatement(
        "INSERT INTO collection_book_aliases(local_uid, remote_key) VALUES ('gone', 'wire')",
      );
      expect(await db.getCollectionBookAliases(), isEmpty);
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'new-book',
          uid: const Value<String>('new-uid'),
          title: 'New',
          epubPath: '/new.epub',
          extractDir: '/new',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1,
        ),
      );
      await Future.wait(
        List<Future<void>>.generate(
          4,
          (int _) => db.setCollectionBookAlias('new-uid', 'wire'),
        ),
      );
      expect(await db.getCollectionBookAliases(), <String, String>{
        'wire': 'new-uid',
      });
    },
  );
}

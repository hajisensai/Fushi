import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/collection_sync_engine.dart';

void main() {
  late FushiDatabase db;
  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());
  Future<String> insertOnline({String runtime = 'interconnect'}) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'local-hash',
        title: 'Manga',
        epubPath: 'manga.json',
        extractDir: '/tmp/manga',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
        sourceMetadata: Value(
          jsonEncode(<String, Object?>{
            'type': 'hibiki-online-manga',
            'version': 3,
            'runtime': runtime,
            'extensionPackage': 'fushi.interconnect',
            'sourceId': 'library',
            'series': <String, Object?>{'key': 'remote-key'},
          }),
        ),
      ),
    );
    return (await db.getEpubBook('local-hash'))!.uid;
  }

  test(
    'online manga publishes remote identity and applies it back to local UID',
    () async {
      final String uid = await insertOnline();
      final int id = await db.createMediaCollection('Manga');
      await db.addToCollection(id, MediaKind.epub, uid);
      final CollectionManifest manifest = await loadLocalCollectionManifest(db);
      expect(manifest.collections.single.members.single.entryKey, 'remote-key');
      await applyCollectionLocalChanges(
        db,
        const CollectionLocalChanges([
          CollectionManifestEntry(
            name: 'Manga',
            collectionType: 'collection',
            members: [
              CollectionManifestMember(
                mediaType: 'epub',
                entryKey: 'remote-key',
                sortIndex: 0,
              ),
            ],
          ),
        ]),
      );
      expect((await db.getCollectionItems(id)).single.entryKey, uid);
      await db.removeFromCollection(id, MediaKind.epub, uid);
      expect(
        (await db.getAllCollectionMemberTombstones()).single.entryKey,
        'remote-key',
      );
    },
  );
  test('other manga runtimes retain their own book identity', () async {
    final String uid = await insertOnline(runtime: 'mihon');
    final int id = await db.createMediaCollection('Manga');
    await db.addToCollection(id, MediaKind.epub, uid);
    expect(
      (await loadLocalCollectionManifest(
        db,
      )).collections.single.members.single.entryKey,
      'local-hash',
    );
  });
  for (final bool retainShell in [false, true]) {
    test(
      'legacy online tombstone canonicalizes with shell=$retainShell',
      () async {
        await insertOnline();
        if (retainShell) await db.createMediaCollection('Manga');
        await db.upsertCollectionMemberTombstone(
          collectionName: 'Manga',
          collectionType: 'collection',
          mediaType: 'epub',
          entryKey: 'local-hash',
          deletedAt: 10,
        );
        final CollectionManifest local = await loadLocalCollectionManifest(db);
        expect(
          local.collections.single.memberTombstones.single.entryKey,
          'remote-key',
        );
        const CollectionManifest remote = CollectionManifest(
          collections: [
            CollectionManifestEntry(
              name: 'Manga',
              collectionType: 'collection',
              members: [
                CollectionManifestMember(
                  mediaType: 'epub',
                  entryKey: 'remote-key',
                  sortIndex: 0,
                ),
              ],
            ),
          ],
        );
        final CollectionSyncOutcome outcome = CollectionSyncEngine.merge(
          local: local,
          remote: remote,
          lastSyncedAtMs: 0,
          nowMs: 20,
        );
        expect(outcome.merged.collections.single.members, isEmpty);
        await applyCollectionLocalChanges(db, outcome.changes);
        expect(await db.getAllCollectionItems(), isEmpty);
      },
    );
  }
}

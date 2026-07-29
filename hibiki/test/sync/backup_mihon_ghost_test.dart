import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

void main() {
  test('fresh-device restore excludes Mihon shelf ghosts but keeps local manga',
      () async {
    final Directory root =
        await Directory.systemTemp.createTemp('hibiki-backup-mihon-');
    addTearDown(() async {
      if (root.existsSync()) await cleanupTempDir(root);
    });
    final String sourceDbDirectory = p.join(root.path, 'source');
    final String restoredDbDirectory = p.join(root.path, 'restored');
    Directory(sourceDbDirectory).createSync(recursive: true);
    Directory(restoredDbDirectory).createSync(recursive: true);
    final HibikiDatabase source =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    const String mihonBookKey = 'mihon-remote-fixture';
    const String localBookKey = 'local-manga-fixture';
    const String malformedBookKey = 'malformed-metadata-fixture';
    const String missingMetadataBookKey = 'missing-metadata-fixture';
    await _insertManga(
      source,
      bookKey: mihonBookKey,
      sourceMetadata: jsonEncode(<String, Object?>{
        'type': 'hibiki-mihon',
        'version': 1,
        'extensionPackage': 'org.example.fixture',
        'sourceId': '9223372036854775807',
      }),
    );
    await _insertManga(
      source,
      bookKey: localBookKey,
      sourceMetadata: jsonEncode(<String, Object?>{'type': 'local-manga'}),
    );
    await _insertManga(
      source,
      bookKey: malformedBookKey,
      sourceMetadata: '{not-json',
    );
    await _insertManga(
      source,
      bookKey: missingMetadataBookKey,
      sourceMetadata: null,
    );
    await source.upsertShelfOrder(MediaKind.epub, mihonBookKey, 1);
    await source.upsertShelfOrder(MediaKind.epub, localBookKey, 2);
    await source.upsertShelfOrder(MediaKind.epub, malformedBookKey, 3);
    await source.upsertShelfOrder(MediaKind.epub, missingMetadataBookKey, 4);
    final int collection = await source.createMediaCollection('Manga');
    await source.addToCollection(collection, MediaKind.epub, mihonBookKey);
    await source.addToCollection(collection, MediaKind.epub, localBookKey);
    await source.addToCollection(collection, MediaKind.epub, malformedBookKey);
    await source.addToCollection(
      collection,
      MediaKind.epub,
      missingMetadataBookKey,
    );

    final String backupPath = p.join(root.path, 'backup.zip');
    await BackupService(
      db: source,
      dbDirectory: sourceDbDirectory,
      appVersion: 'test',
    ).createBackup(backupPath);
    // Sanitization is confined to the VACUUM export copy: even a descriptor
    // excluded from the backup must remain intact in the live source DB.
    expect(await source.getEpubBook(mihonBookKey), isNotNull);
    expect(
      await source.getShelfEntry(MediaKind.epub, mihonBookKey),
      isNotNull,
    );
    expect(
      await source.customSelect(
        'SELECT entry_key FROM media_collection_items '
        'WHERE entry_key = ?',
        variables: <Variable<Object>>[Variable<String>(mihonBookKey)],
      ).getSingleOrNull(),
      isNotNull,
    );
    await source.close();

    await BackupService.restoreBackup(
      dbDirectory: restoredDbDirectory,
      zipPath: backupPath,
    );
    final HibikiDatabase restored = HibikiDatabase(restoredDbDirectory);
    addTearDown(restored.close);

    expect(await restored.getEpubBook(mihonBookKey), equals(null));
    expect(
      await restored.getShelfEntry(MediaKind.epub, mihonBookKey),
      equals(null),
    );
    expect(await restored.getEpubBook(localBookKey), isNotNull);
    expect(
      await restored.getShelfEntry(MediaKind.epub, localBookKey),
      isNotNull,
    );
    expect(await restored.getEpubBook(malformedBookKey), isNotNull);
    expect(
      await restored.getShelfEntry(MediaKind.epub, malformedBookKey),
      isNotNull,
    );
    expect(await restored.getEpubBook(missingMetadataBookKey), isNotNull);
    expect(
      await restored.getShelfEntry(MediaKind.epub, missingMetadataBookKey),
      isNotNull,
    );
    final List<QueryRow> members = await restored
        .customSelect(
          'SELECT entry_key FROM media_collection_items ORDER BY entry_key',
        )
        .get();
    expect(
      members.map((QueryRow row) => row.read<String>('entry_key')),
      <String>[localBookKey, malformedBookKey, missingMetadataBookKey],
    );
  });
}

Future<void> _insertManga(
  HibikiDatabase database, {
  required String bookKey,
  required String? sourceMetadata,
}) =>
    database.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: bookKey,
        epubPath: '$bookKey.json',
        extractDir: bookKey,
        chapterCount: 0,
        chaptersJson: '[]',
        sourceMetadata: Value<String?>(sourceMetadata),
        importedAt: 1,
        format: const Value<String>('manga'),
      ),
    );

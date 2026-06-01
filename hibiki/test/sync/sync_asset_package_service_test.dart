import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

ArchiveFile _textFile(String name, String content) {
  final List<int> bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

void main() {
  group('Dictionary sync packages', () {
    test('round trip carries metadata and resource files', () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'hibiki-dict-package-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final HibikiDatabase sourceDb = _testDb();
      final HibikiDatabase targetDb = _testDb();
      addTearDown(sourceDb.close);
      addTearDown(targetDb.close);

      final Directory sourceResources =
          Directory(p.join(temp.path, 'source-dictionaries'));
      final Directory targetResources =
          Directory(p.join(temp.path, 'target-dictionaries'));
      await Directory(p.join(sourceResources.path, 'JMdict', 'media'))
          .create(recursive: true);
      await File(p.join(sourceResources.path, 'JMdict', 'blobs.bin'))
          .writeAsString('dictionary index');
      await File(p.join(sourceResources.path, 'JMdict', 'media', 'pitch.png'))
          .writeAsString('image bytes');

      await sourceDb.upsertDictionaryMeta(DictionaryMetadataCompanion.insert(
        name: 'JMdict',
        formatKey: 'yomichan',
        order: 7,
        type: const Value('term'),
        metadataJson: const Value('{"version":"2026"}'),
        hiddenLanguagesJson: const Value('["en"]'),
        collapsedLanguagesJson: const Value('["ja"]'),
      ));

      final SyncAssetPackageService service =
          SyncAssetPackageService(db: sourceDb);
      final File package = await service.exportDictionaryPackage(
        dictionaryName: 'JMdict',
        dictionaryResourceRoot: sourceResources,
        outputFile: File(p.join(temp.path, 'jmdict.hibiki-dictionary.zip')),
      );

      final Archive archive =
          ZipDecoder().decodeBytes(await package.readAsBytes());
      expect(archive.findFile('manifest.json'), isNotNull);
      expect(archive.findFile('resources/blobs.bin'), isNotNull);
      expect(archive.findFile('resources/media/pitch.png'), isNotNull);

      final SyncAssetPackageService targetService =
          SyncAssetPackageService(db: targetDb);
      await targetService.importDictionaryPackage(
        packageFile: package,
        dictionaryResourceRoot: targetResources,
      );

      final DictionaryMetaRow imported =
          (await targetDb.getAllDictionaryMetadata()).single;
      expect(imported.name, 'JMdict');
      expect(imported.formatKey, 'yomichan');
      expect(imported.order, 7);
      expect(imported.type, 'term');
      expect(imported.metadataJson, '{"version":"2026"}');
      expect(imported.hiddenLanguagesJson, '["en"]');
      expect(imported.collapsedLanguagesJson, '["ja"]');
      expect(
        await File(p.join(targetResources.path, 'JMdict', 'blobs.bin'))
            .readAsString(),
        'dictionary index',
      );
      expect(
        await File(p.join(targetResources.path, 'JMdict', 'media', 'pitch.png'))
            .readAsString(),
        'image bytes',
      );
    });

    test('import rejects dictionary package path traversal', () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'hibiki-dict-traversal-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);

      final Archive archive = Archive()
        ..addFile(_textFile(
            'manifest.json',
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'kind': 'dictionary',
              'dictionary': <String, Object?>{
                'name': 'Bad',
                'formatKey': 'yomichan',
                'order': 0,
                'type': 'term',
                'metadataJson': '{}',
                'hiddenLanguagesJson': '[]',
                'collapsedLanguagesJson': '[]',
              },
            })))
        ..addFile(_textFile('resources/../evil.txt', 'owned'));
      final File package = File(p.join(temp.path, 'bad.zip'))
        ..writeAsBytesSync(ZipEncoder().encode(archive)!);

      await expectLater(
        SyncAssetPackageService(db: db).importDictionaryPackage(
          packageFile: package,
          dictionaryResourceRoot: Directory(p.join(temp.path, 'dicts')),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(File(p.join(temp.path, 'evil.txt')).existsSync(), isFalse);
    });
  });

  group('Audio database sync packages', () {
    test('round trip rewrites paths and restores cues', () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'hibiki-audio-package-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final HibikiDatabase sourceDb = _testDb();
      final HibikiDatabase targetDb = _testDb();
      addTearDown(sourceDb.close);
      addTearDown(targetDb.close);

      final Directory sourceAudio =
          Directory(p.join(temp.path, 'source-audio'));
      await sourceAudio.create(recursive: true);
      final File track = File(p.join(sourceAudio.path, 'track01.m4b'))
        ..writeAsStringSync('audio bytes');
      final File alignment = File(p.join(sourceAudio.path, 'align.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhello\n');
      final File cover = File(p.join(sourceAudio.path, 'cover.jpg'))
        ..writeAsStringSync('cover bytes');

      await sourceDb.upsertAudiobook(AudiobooksCompanion.insert(
        bookUid: 'ttu-42',
        audioRoot: Value(sourceAudio.path),
        audioPathsJson: Value(jsonEncode(<String>[track.path])),
        alignmentFormat: 'srt',
        alignmentPath: alignment.path,
        healthKindRaw: const Value('healthy'),
        matchRatePct: const Value(98),
        healthMeasuredAt: Value(DateTime.utc(2026, 6)),
        healthReason: const Value('ok'),
        followAudio: const Value(true),
      ));
      await sourceDb.upsertSrtBook(SrtBooksCompanion.insert(
        uid: 'srt-42',
        title: 'Standalone',
        author: const Value('Author'),
        audioRoot: Value(sourceAudio.path),
        audioPathsJson: Value(jsonEncode(<String>[track.path])),
        srtPath: alignment.path,
        coverPath: Value(cover.path),
        importedAt: 1234,
        ttuBookId: const Value(42),
      ));
      await sourceDb.replaceCuesForBook('ttu-42', <AudioCuesCompanion>[
        AudioCuesCompanion.insert(
          bookUid: 'ttu-42',
          chapterHref: 'chapter.xhtml',
          sentenceIndex: 3,
          textFragmentId: 'frag-3',
          cueText: 'hello',
          startMs: 0,
          endMs: 1000,
          audioFileIndex: 0,
        ),
      ]);

      final File package = await SyncAssetPackageService(db: sourceDb)
          .exportAudioDatabasePackage(
        bookUid: 'ttu-42',
        srtBookUid: 'srt-42',
        outputFile: File(p.join(temp.path, 'audio.hibiki-audio-db.zip')),
      );

      final Directory targetAudio =
          Directory(p.join(temp.path, 'target-audio'));
      await SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
        packageFile: package,
        audioDatabaseRoot: targetAudio,
      );

      final AudiobookRow audiobook =
          (await targetDb.getAudiobookByBookUid('ttu-42'))!;
      expect(audiobook.alignmentPath,
          p.join(targetAudio.path, 'ttu-42', 'align.srt'));
      expect(audiobook.audioRoot, p.join(targetAudio.path, 'ttu-42'));
      expect(jsonDecode(audiobook.audioPathsJson!) as List<dynamic>, <String>[
        p.join(targetAudio.path, 'ttu-42', 'track01.m4b'),
      ]);
      expect(await File(audiobook.alignmentPath).readAsString(),
          contains('hello'));
      expect(
          await File(p.join(targetAudio.path, 'ttu-42', 'track01.m4b'))
              .readAsString(),
          'audio bytes');

      final List<AudioCueRow> cues = await targetDb.getCuesForBook('ttu-42');
      expect(cues, hasLength(1));
      expect(cues.single.chapterHref, 'chapter.xhtml');
      expect(cues.single.cueText, 'hello');

      final SrtBookRow srt = (await targetDb.getSrtBookByUid('srt-42'))!;
      expect(srt.srtPath, p.join(targetAudio.path, 'ttu-42', 'align.srt'));
      expect(srt.coverPath, p.join(targetAudio.path, 'ttu-42', 'cover.jpg'));
    });
  });
}

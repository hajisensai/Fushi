import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/local_audio_source_pref.dart';
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

    test('large audio file survives STORE export + streaming import intact',
        () async {
      // 行为级证明 STORE 导出 + rawContent 流式导入对大文件往返字节一致。
      // 用 >2MB（3MB）的伪随机内容，走过 archive 的分块 CRC / writeInputStream
      // 流式路径（小文件走不到），断言导入后磁盘字节与源完全一致。
      final Directory temp = await Directory.systemTemp.createTemp(
        'hibiki-audio-large-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final HibikiDatabase sourceDb = _testDb();
      final HibikiDatabase targetDb = _testDb();
      addTearDown(sourceDb.close);
      addTearDown(targetDb.close);

      final Directory sourceAudio =
          Directory(p.join(temp.path, 'source-audio'));
      await sourceAudio.create(recursive: true);

      // 3 MB 伪随机字节（可重复种子），覆盖 0..255 全字节值。
      const int sizeBytes = 3 * 1024 * 1024;
      final Uint8List big = Uint8List(sizeBytes);
      int state = 0x1234567;
      for (int i = 0; i < sizeBytes; i++) {
        state = (state * 1103515245 + 12345) & 0x7fffffff;
        big[i] = state & 0xff;
      }
      final File track = File(p.join(sourceAudio.path, 'big.m4b'))
        ..writeAsBytesSync(big);
      final File alignment = File(p.join(sourceAudio.path, 'align.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhello\n');

      await sourceDb.upsertAudiobook(AudiobooksCompanion.insert(
        bookUid: 'ttu-big',
        audioRoot: Value(sourceAudio.path),
        audioPathsJson: Value(jsonEncode(<String>[track.path])),
        alignmentFormat: 'srt',
        alignmentPath: alignment.path,
      ));
      await sourceDb.upsertSrtBook(SrtBooksCompanion.insert(
        uid: 'srt-big',
        title: 'Big',
        audioRoot: Value(sourceAudio.path),
        audioPathsJson: Value(jsonEncode(<String>[track.path])),
        srtPath: alignment.path,
        importedAt: 1,
        ttuBookId: const Value(99),
      ));
      await sourceDb.replaceCuesForBook('ttu-big', <AudioCuesCompanion>[
        AudioCuesCompanion.insert(
          bookUid: 'ttu-big',
          chapterHref: 'chapter.xhtml',
          sentenceIndex: 0,
          textFragmentId: 'frag-0',
          cueText: 'hello',
          startMs: 0,
          endMs: 1000,
          audioFileIndex: 0,
        ),
      ]);

      final File package = await SyncAssetPackageService(db: sourceDb)
          .exportAudioDatabasePackage(
        bookUid: 'ttu-big',
        srtBookUid: 'srt-big',
        outputFile: File(p.join(temp.path, 'big.hibiki-audio-db.zip')),
      );

      final Directory targetAudio =
          Directory(p.join(temp.path, 'target-audio'));
      await SyncAssetPackageService(db: targetDb).importAudioDatabasePackage(
        packageFile: package,
        audioDatabaseRoot: targetAudio,
      );

      final File restored =
          File(p.join(targetAudio.path, 'ttu-big', 'big.m4b'));
      expect(restored.existsSync(), isTrue);
      final Uint8List restoredBytes = restored.readAsBytesSync();
      expect(restoredBytes.length, sizeBytes);
      expect(_sha256Hex(restoredBytes), _sha256Hex(big),
          reason: '大文件 STORE 往返后字节哈希必须一致');
    });
  });

  group('Local audio sync packages', () {
    test('round trip carries config and restores db bytes (>2MB STORE)',
        () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'hibiki-local-audio-package-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final HibikiDatabase sourceDb = _testDb();
      final HibikiDatabase targetDb = _testDb();
      addTearDown(sourceDb.close);
      addTearDown(targetDb.close);

      // 3 MB 伪随机 .db（覆盖全字节值），确保走 STORE 流式分块路径而非整入内存。
      const int sizeBytes = 3 * 1024 * 1024;
      final Uint8List big = Uint8List(sizeBytes);
      int state = 0x0abcdef;
      for (int i = 0; i < sizeBytes; i++) {
        state = (state * 1103515245 + 12345) & 0x7fffffff;
        big[i] = state & 0xff;
      }
      final File dbFile = File(p.join(temp.path, 'local_audio_42.db'))
        ..writeAsBytesSync(big);

      final SyncAssetPackageService service =
          SyncAssetPackageService(db: sourceDb);
      final File package = await service.exportLocalAudioPackage(
        displayName: 'NHK Audio',
        enabled: true,
        sources: const <LocalAudioSourcePref>[
          LocalAudioSourcePref(name: 'nhk16', enabled: true),
          LocalAudioSourcePref(name: 'forvo', enabled: false),
        ],
        dbFile: dbFile,
        outputFile: File(p.join(temp.path, 'nhk.hibikiaudiolib')),
      );

      // STORE 验证：包内资源条目压缩方式必须是 STORE（compressionType==0）。
      final Archive archive =
          ZipDecoder().decodeBytes(await package.readAsBytes());
      final ArchiveFile? resource =
          archive.findFile('resources/local_audio_42.db');
      expect(resource, isNotNull);
      expect(resource!.compressionType, ArchiveFile.STORE,
          reason: '大 DB 必须 STORE，不能 deflate（会整文件入内存 OOM）');

      final Directory staging = Directory(p.join(temp.path, 'staging'))
        ..createSync();
      final LocalAudioPackageContents contents =
          await SyncAssetPackageService(db: targetDb).importLocalAudioPackage(
        packageFile: package,
        stagingDir: staging,
      );

      expect(contents.displayName, 'NHK Audio');
      expect(contents.enabled, isTrue);
      expect(contents.sources.length, 2);
      expect(contents.sources[0].name, 'nhk16');
      expect(contents.sources[0].enabled, isTrue);
      expect(contents.sources[1].name, 'forvo');
      expect(contents.sources[1].enabled, isFalse);

      expect(contents.dbFile.existsSync(), isTrue);
      final Uint8List restored = contents.dbFile.readAsBytesSync();
      expect(restored.length, sizeBytes);
      expect(_sha256Hex(restored), _sha256Hex(big),
          reason: '大 DB STORE 往返后字节哈希必须一致');
    });
  });
}

String _sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

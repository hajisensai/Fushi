import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/cloud_backup/backup_snapshot_service.dart';
import 'package:path/path.dart' as p;

void main() {
  group('BackupSnapshotService', () {
    late Directory sandbox;
    late Directory documents;
    late Directory support;
    late Directory staging;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('hibiki_backup_test_');
      documents = Directory(p.join(sandbox.path, 'documents'))
        ..createSync(recursive: true);
      support = Directory(p.join(sandbox.path, 'support'))
        ..createSync(recursive: true);
      staging = Directory(p.join(sandbox.path, 'staging'))
        ..createSync(recursive: true);
    });

    tearDown(() async {
      if (sandbox.existsSync()) {
        await sandbox.delete(recursive: true);
      }
    });

    test('creates a zip containing manifest and both app data roots', () async {
      File(p.join(documents.path, 'reader.txt')).writeAsStringSync('book');
      Directory(p.join(documents.path, 'nested')).createSync();
      File(p.join(documents.path, 'nested', 'font.ttf')).writeAsBytesSync([1, 2]);
      File(p.join(support.path, 'hibiki.db')).writeAsStringSync('sqlite');

      final service = BackupSnapshotService(
        documentsDirectory: documents,
        supportDirectory: support,
        stagingDirectory: staging,
      );

      final File snapshot = await service.createSnapshot(
        appVersion: '0.1.19',
      );

      final archive = ZipDecoder().decodeBytes(snapshot.readAsBytesSync());
      final names = archive.files.map((file) => file.name).toSet();

      expect(names, contains('manifest.json'));
      expect(names, contains('documents/reader.txt'));
      expect(names, contains('documents/nested/font.ttf'));
      expect(names, contains('support/hibiki.db'));

      final manifestFile =
          archive.files.singleWhere((file) => file.name == 'manifest.json');
      final manifest = jsonDecode(
        utf8.decode(manifestFile.content as List<int>),
      ) as Map<String, dynamic>;
      expect(manifest['formatVersion'], 1);
      expect(manifest['appVersion'], '0.1.19');
    });

    test('restores a snapshot without allowing paths outside target roots',
        () async {
      final archive = Archive()
        ..addFile(_textFile('manifest.json', '{}'))
        ..addFile(_textFile('documents/restored.txt', 'ok'))
        ..addFile(_textFile('../escape.txt', 'bad'));
      final File snapshot = File(p.join(staging.path, 'snapshot.zip'));
      snapshot.writeAsBytesSync(ZipEncoder().encode(archive)!);

      final service = BackupSnapshotService(
        documentsDirectory: documents,
        supportDirectory: support,
        stagingDirectory: staging,
      );

      await expectLater(
        service.restoreSnapshot(snapshot),
        throwsA(isA<FormatException>()),
      );
      expect(File(p.join(sandbox.path, 'escape.txt')).existsSync(), isFalse);
    });
  });
}

ArchiveFile _textFile(String name, String content) {
  final List<int> bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

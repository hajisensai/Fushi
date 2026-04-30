import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

class BackupSnapshotService {
  BackupSnapshotService({
    required this.documentsDirectory,
    required this.supportDirectory,
    required this.stagingDirectory,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const int formatVersion = 1;
  static const String snapshotFileName = 'hibiki-backup.zip';

  final Directory documentsDirectory;
  final Directory supportDirectory;
  final Directory stagingDirectory;
  final DateTime Function() _now;

  Future<File> createSnapshot({required String appVersion}) async {
    if (!stagingDirectory.existsSync()) {
      stagingDirectory.createSync(recursive: true);
    }

    final DateTime createdAt = _now().toUtc();
    final List<int> manifestBytes = utf8.encode(jsonEncode({
      'formatVersion': formatVersion,
      'appVersion': appVersion,
      'createdAt': createdAt.toIso8601String(),
    }));
    final Archive archive = Archive()
      ..addFile(
        ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
      );

    await _addDirectory(
      archive: archive,
      root: documentsDirectory,
      prefix: 'documents',
      excludedRoot: stagingDirectory,
    );
    await _addDirectory(
      archive: archive,
      root: supportDirectory,
      prefix: 'support',
      excludedRoot: stagingDirectory,
    );

    final String timestamp = createdAt
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '');
    final File out = File(p.join(stagingDirectory.path, 'hibiki-$timestamp.zip'));
    out.writeAsBytesSync(ZipEncoder().encode(archive)!);
    return out;
  }

  Future<void> restoreSnapshot(File snapshot) async {
    final Archive archive = ZipDecoder().decodeBytes(await snapshot.readAsBytes());
    _validateArchive(archive);

    await _replaceRootFromArchive(
      archive: archive,
      root: documentsDirectory,
      prefix: 'documents/',
    );
    await _replaceRootFromArchive(
      archive: archive,
      root: supportDirectory,
      prefix: 'support/',
    );
  }

  Future<void> validateSnapshot(File snapshot) async {
    final Archive archive = ZipDecoder().decodeBytes(await snapshot.readAsBytes());
    _validateArchive(archive);
  }

  Future<void> _addDirectory({
    required Archive archive,
    required Directory root,
    required String prefix,
    required Directory excludedRoot,
  }) async {
    if (!root.existsSync()) return;

    final String rootPath = p.normalize(root.absolute.path);
    final String excludedPath = p.normalize(excludedRoot.absolute.path);
    final List<FileSystemEntity> entities = root.listSync(recursive: true);
    for (final FileSystemEntity entity in entities) {
      final String entityPath = p.normalize(entity.absolute.path);
      if (entityPath == excludedPath || p.isWithin(excludedPath, entityPath)) {
        continue;
      }
      if (entity is! File) continue;

      final String relative = p.relative(entityPath, from: rootPath);
      final String archivePath = p.posix.join(
        prefix,
        p.split(relative).join('/'),
      );
      archive.addFile(
        ArchiveFile(
          archivePath,
          entity.lengthSync(),
          entity.readAsBytesSync(),
        ),
      );
    }
  }

  void _validateArchive(Archive archive) {
    final bool hasManifest =
        archive.files.any((ArchiveFile file) => file.name == 'manifest.json');
    if (!hasManifest) {
      throw const FormatException('Backup manifest missing.');
    }

    for (final ArchiveFile file in archive.files) {
      final String name = file.name.replaceAll('\\', '/');
      final bool allowed = name == 'manifest.json' ||
          name.startsWith('documents/') ||
          name.startsWith('support/');
      if (!allowed || name.contains('../') || name.startsWith('/')) {
        throw FormatException('Unsafe backup entry: ${file.name}');
      }
    }
  }

  Future<void> _replaceRootFromArchive({
    required Archive archive,
    required Directory root,
    required String prefix,
  }) async {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
    root.createSync(recursive: true);

    for (final ArchiveFile file in archive.files) {
      if (!file.isFile || !file.name.startsWith(prefix)) continue;

      final String relative = file.name.substring(prefix.length);
      if (relative.isEmpty) continue;

      final String outPath = p.normalize(
        p.joinAll(<String>[root.path, ...relative.split('/')]),
      );
      final String rootPath = p.normalize(root.absolute.path);
      if (outPath != rootPath &&
          !p.isWithin(rootPath, p.normalize(File(outPath).absolute.path))) {
        throw FormatException('Unsafe restore path: ${file.name}');
      }

      final File out = File(outPath);
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(file.content as List<int>);
    }
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

class SyncAssetPackageService {
  SyncAssetPackageService({required HibikiDatabase db}) : _db = db;

  final HibikiDatabase _db;

  Future<File> exportDictionaryPackage({
    required String dictionaryName,
    required Directory dictionaryResourceRoot,
    required File outputFile,
  }) async {
    final DictionaryMetaRow meta = (await _db.getAllDictionaryMetadata())
        .singleWhere((DictionaryMetaRow row) => row.name == dictionaryName);
    final Directory sourceDir = Directory(
      p.join(dictionaryResourceRoot.path, dictionaryName),
    );

    final Archive archive = Archive()
      ..addFile(_jsonFile('manifest.json', <String, Object?>{
        'schemaVersion': 1,
        'kind': 'dictionary',
        'dictionary': _dictionaryManifest(meta),
      }));
    await _addDirectoryFiles(
      archive: archive,
      root: sourceDir,
      archivePrefix: 'resources',
    );

    return _writeZip(outputFile, archive);
  }

  Future<void> importDictionaryPackage({
    required File packageFile,
    required Directory dictionaryResourceRoot,
  }) async {
    final Archive archive =
        ZipDecoder().decodeBytes(await packageFile.readAsBytes());
    final Map<String, Object?> manifest = _readManifest(
      archive,
      expectedKind: 'dictionary',
    );
    final Map<String, Object?> dictionary = _mapValue(manifest, 'dictionary');
    final String name = _stringValue(dictionary, 'name');

    await _db.upsertDictionaryMeta(DictionaryMetadataCompanion.insert(
      name: name,
      formatKey: _stringValue(dictionary, 'formatKey'),
      order: _intValue(dictionary, 'order'),
      type: Value(_stringValue(dictionary, 'type')),
      metadataJson: Value(_stringValue(dictionary, 'metadataJson')),
      hiddenLanguagesJson: Value(_stringValue(
        dictionary,
        'hiddenLanguagesJson',
      )),
      collapsedLanguagesJson: Value(_stringValue(
        dictionary,
        'collapsedLanguagesJson',
      )),
    ));

    final Directory targetDir = Directory(
      p.join(dictionaryResourceRoot.path, name),
    );
    await _extractArchivePrefix(
      archive: archive,
      prefix: 'resources',
      targetRoot: targetDir,
    );
  }

  Future<File> exportAudioDatabasePackage({
    required String bookUid,
    required String srtBookUid,
    required File outputFile,
  }) async {
    final AudiobookRow audiobook = (await _db.getAudiobookByBookUid(bookUid))!;
    final SrtBookRow srtBook = (await _db.getSrtBookByUid(srtBookUid))!;
    final List<AudioCueRow> cues = await _db.getCuesForBook(bookUid);
    final Map<String, String> resourceNames = <String, String>{};
    final List<File> files = _audioPackageFiles(audiobook, srtBook);

    final Archive archive = Archive();
    final Set<String> usedNames = <String>{};
    for (final File file in files) {
      if (!await file.exists()) continue;
      final String name = _uniqueFileName(file, usedNames);
      resourceNames[file.path] = name;
      archive.addFile(ArchiveFile(
        'resources/$name',
        await file.length(),
        await file.readAsBytes(),
      ));
    }
    archive.addFile(_jsonFile('manifest.json', <String, Object?>{
      'schemaVersion': 1,
      'kind': 'audioDatabase',
      'audiobook': _audiobookManifest(audiobook),
      'srtBook': _srtBookManifest(srtBook),
      'cues': cues.map(_audioCueManifest).toList(),
      'resources': resourceNames,
    }));

    return _writeZip(outputFile, archive);
  }

  /// Imports an audiobook package. [bookUidOverride] / [ttuBookIdOverride]
  /// re-key the imported audiobook + cues ([bookUidOverride]) and SRT book
  /// ([ttuBookIdOverride]) to the importing device's own book. This is required
  /// for cross-device sync: `bookUid` embeds the source device's local book id
  /// (`buildLegacyBookUid(book.id)`), which differs per device, so without
  /// re-keying the synced audiobook would never link to the target's book.
  Future<void> importAudioDatabasePackage({
    required File packageFile,
    required Directory audioDatabaseRoot,
    String? bookUidOverride,
    int? ttuBookIdOverride,
  }) async {
    final Archive archive =
        ZipDecoder().decodeBytes(await packageFile.readAsBytes());
    final Map<String, Object?> manifest = _readManifest(
      archive,
      expectedKind: 'audioDatabase',
    );
    final Map<String, Object?> audiobook = _mapValue(manifest, 'audiobook');
    final Map<String, Object?> srtBook = _mapValue(manifest, 'srtBook');
    final Map<String, Object?> resources = _mapValue(manifest, 'resources');
    final String bookUid =
        bookUidOverride ?? _stringValue(audiobook, 'bookUid');
    final int ttuBookId = ttuBookIdOverride ?? _intValue(srtBook, 'ttuBookId');
    // The on-disk directory name must be filesystem-safe: a real bookUid
    // (`reader_ttu/hoshi://book/<id>`) contains `:` and `/` which are invalid
    // path chars on Windows. The DB still keys rows by the logical [bookUid];
    // only the storage directory is sanitized.
    final Directory targetDir =
        Directory(p.join(audioDatabaseRoot.path, _safeDirName(bookUid)));

    await _extractArchivePrefix(
      archive: archive,
      prefix: 'resources',
      targetRoot: targetDir,
    );

    final String alignmentPath = p.join(
      targetDir.path,
      _resourceName(resources, _stringValue(audiobook, 'alignmentPath')),
    );
    final List<String> audioPaths = _stringList(
      audiobook,
      'audioPaths',
    ).map((String path) {
      return p.join(targetDir.path, _resourceName(resources, path));
    }).toList();

    await _db.upsertAudiobook(AudiobooksCompanion.insert(
      bookUid: bookUid,
      audioRoot: Value(targetDir.path),
      audioPathsJson: Value(jsonEncode(audioPaths)),
      alignmentFormat: _stringValue(audiobook, 'alignmentFormat'),
      alignmentPath: alignmentPath,
      healthKindRaw: Value(_nullableString(audiobook, 'healthKindRaw')),
      matchRatePct: Value(_nullableInt(audiobook, 'matchRatePct')),
      healthMeasuredAt: Value(_nullableDate(audiobook, 'healthMeasuredAt')),
      healthReason: Value(_nullableString(audiobook, 'healthReason')),
      followAudio: Value(_nullableBool(audiobook, 'followAudio')),
    ));

    await _db.upsertSrtBook(SrtBooksCompanion.insert(
      uid: _stringValue(srtBook, 'uid'),
      title: _stringValue(srtBook, 'title'),
      author: Value(_nullableString(srtBook, 'author')),
      audioRoot: Value(targetDir.path),
      audioPathsJson: Value(jsonEncode(audioPaths)),
      srtPath: p.join(
        targetDir.path,
        _resourceName(resources, _stringValue(srtBook, 'srtPath')),
      ),
      coverPath: Value(_nullablePathIn(
        targetDir,
        resources,
        srtBook,
        'coverPath',
      )),
      importedAt: _intValue(srtBook, 'importedAt'),
      ttuBookId: Value(ttuBookId),
    ));

    await _db.replaceCuesForBook(
      bookUid,
      _listValue(manifest, 'cues').map((Object? raw) {
        final Map<String, Object?> cue = _typedMap(raw);
        return AudioCuesCompanion.insert(
          bookUid: bookUid,
          chapterHref: _stringValue(cue, 'chapterHref'),
          sentenceIndex: _intValue(cue, 'sentenceIndex'),
          textFragmentId: _stringValue(cue, 'textFragmentId'),
          cueText: _stringValue(cue, 'cueText'),
          startMs: _intValue(cue, 'startMs'),
          endMs: _intValue(cue, 'endMs'),
          audioFileIndex: _intValue(cue, 'audioFileIndex'),
        );
      }).toList(),
    );
  }

  Map<String, Object?> _dictionaryManifest(DictionaryMetaRow row) {
    return <String, Object?>{
      'name': row.name,
      'formatKey': row.formatKey,
      'order': row.order,
      'type': row.type,
      'metadataJson': row.metadataJson,
      'hiddenLanguagesJson': row.hiddenLanguagesJson,
      'collapsedLanguagesJson': row.collapsedLanguagesJson,
    };
  }

  Map<String, Object?> _audiobookManifest(AudiobookRow row) {
    return <String, Object?>{
      'bookUid': row.bookUid,
      'audioPaths': _decodeStringList(row.audioPathsJson),
      'alignmentFormat': row.alignmentFormat,
      'alignmentPath': row.alignmentPath,
      'healthKindRaw': row.healthKindRaw,
      'matchRatePct': row.matchRatePct,
      'healthMeasuredAt': row.healthMeasuredAt?.toIso8601String(),
      'healthReason': row.healthReason,
      'followAudio': row.followAudio,
    };
  }

  Map<String, Object?> _srtBookManifest(SrtBookRow row) {
    return <String, Object?>{
      'uid': row.uid,
      'title': row.title,
      'author': row.author,
      'audioPaths': _decodeStringList(row.audioPathsJson),
      'srtPath': row.srtPath,
      'coverPath': row.coverPath,
      'importedAt': row.importedAt,
      'ttuBookId': row.ttuBookId,
    };
  }

  Map<String, Object?> _audioCueManifest(AudioCueRow row) {
    return <String, Object?>{
      'chapterHref': row.chapterHref,
      'sentenceIndex': row.sentenceIndex,
      'textFragmentId': row.textFragmentId,
      'cueText': row.cueText,
      'startMs': row.startMs,
      'endMs': row.endMs,
      'audioFileIndex': row.audioFileIndex,
    };
  }
}

/// Sanitizes a logical id into a filesystem-safe directory name (replaces the
/// Windows-invalid `\ / : * ? " < > |` with `_`). Filesystem-safe inputs (e.g.
/// `ttu-42`) pass through unchanged.
String _safeDirName(String id) => id.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

Future<File> _writeZip(File outputFile, Archive archive) async {
  outputFile.parent.createSync(recursive: true);
  await outputFile.writeAsBytes(ZipEncoder().encode(archive)!, flush: true);
  return outputFile;
}

ArchiveFile _jsonFile(String name, Object? json) {
  final List<int> bytes = utf8.encode(jsonEncode(json));
  return ArchiveFile(name, bytes.length, bytes);
}

Future<void> _addDirectoryFiles({
  required Archive archive,
  required Directory root,
  required String archivePrefix,
}) async {
  if (!await root.exists()) return;
  await for (final FileSystemEntity entity in root.list(recursive: true)) {
    if (entity is! File) continue;
    final String relativePath = p.relative(entity.path, from: root.path);
    final String archivePath =
        p.posix.join(archivePrefix, relativePath.replaceAll(r'\', '/'));
    archive.addFile(ArchiveFile(
      archivePath,
      await entity.length(),
      await entity.readAsBytes(),
    ));
  }
}

Future<void> _extractArchivePrefix({
  required Archive archive,
  required String prefix,
  required Directory targetRoot,
}) async {
  final String canonicalRoot = p.canonicalize(targetRoot.path);
  for (final ArchiveFile file in archive.files) {
    if (!file.isFile) continue;
    final String rawName = file.name.replaceAll(r'\', '/');
    if (!rawName.startsWith('$prefix/')) continue;
    final String relativePath = rawName.substring(prefix.length + 1);
    final String normalizedRelative = p.posix.normalize(relativePath);
    if (relativePath.isEmpty ||
        p.posix.isAbsolute(relativePath) ||
        normalizedRelative == '..' ||
        normalizedRelative.startsWith('../')) {
      throw FormatException('Invalid package path: ${file.name}');
    }
    final String targetPath = p.normalize(
      p.join(targetRoot.path, normalizedRelative),
    );
    if (p.canonicalize(targetPath) != canonicalRoot &&
        !p.isWithin(canonicalRoot, p.canonicalize(targetPath))) {
      throw FormatException('Invalid package path: ${file.name}');
    }
    final File targetFile = File(targetPath);
    targetFile.parent.createSync(recursive: true);
    await targetFile.writeAsBytes(file.content as List<int>, flush: true);
  }
}

Map<String, Object?> _readManifest(
  Archive archive, {
  required String expectedKind,
}) {
  final ArchiveFile? manifestFile = archive.findFile('manifest.json');
  if (manifestFile == null) {
    throw const FormatException('Package manifest is missing');
  }
  final Object? decoded =
      jsonDecode(utf8.decode(manifestFile.content as List<int>));
  final Map<String, Object?> manifest = _typedMap(decoded);
  if (manifest['kind'] != expectedKind) {
    throw FormatException('Unexpected package kind: ${manifest['kind']}');
  }
  return manifest;
}

List<File> _audioPackageFiles(AudiobookRow audiobook, SrtBookRow srtBook) {
  final List<String> paths = <String>[
    ..._decodeStringList(audiobook.audioPathsJson),
    audiobook.alignmentPath,
    ..._decodeStringList(srtBook.audioPathsJson),
    srtBook.srtPath,
    if (srtBook.coverPath != null) srtBook.coverPath!,
  ];
  return paths.toSet().map(File.new).toList();
}

String _uniqueFileName(File file, Set<String> usedNames) {
  final String basename = p.basename(file.path);
  if (usedNames.add(basename)) return basename;
  String candidate = basename;
  int index = 1;
  while (!usedNames.add(candidate)) {
    candidate = '$index-$basename';
    index++;
  }
  return candidate;
}

String _resourceName(Map<String, Object?> resources, String sourcePath) {
  final Object? name = resources[sourcePath];
  if (name is String) return name;
  return p.basename(sourcePath);
}

List<String> _decodeStringList(String? json) {
  if (json == null || json.isEmpty) return const <String>[];
  final Object? decoded = jsonDecode(json);
  if (decoded is! List) return const <String>[];
  return decoded.map((Object? value) => value.toString()).toList();
}

Map<String, Object?> _mapValue(Map<String, Object?> map, String key) {
  return _typedMap(map[key]);
}

List<Object?> _listValue(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is List) return value;
  throw FormatException('Expected list value for $key');
}

Map<String, Object?> _typedMap(Object? value) {
  if (value is! Map) throw const FormatException('Expected object value');
  return value.map((Object? key, Object? value) {
    if (key is! String) throw const FormatException('Expected string key');
    return MapEntry<String, Object?>(key, value);
  });
}

String _stringValue(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is String) return value;
  throw FormatException('Expected string value for $key');
}

int _intValue(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw FormatException('Expected int value for $key');
}

List<String> _stringList(Map<String, Object?> map, String key) {
  return _listValue(map, key).map((Object? value) => value.toString()).toList();
}

String? _nullableString(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value == null) return null;
  if (value is String) return value;
  throw FormatException('Expected nullable string value for $key');
}

int? _nullableInt(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw FormatException('Expected nullable int value for $key');
}

bool? _nullableBool(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value == null) return null;
  if (value is bool) return value;
  throw FormatException('Expected nullable bool value for $key');
}

DateTime? _nullableDate(Map<String, Object?> map, String key) {
  final Object? value = map[key];
  if (value == null) return null;
  if (value is String) return DateTime.parse(value);
  throw FormatException('Expected nullable date value for $key');
}

String? _nullablePathIn(
  Directory root,
  Map<String, Object?> resources,
  Map<String, Object?> map,
  String key,
) {
  final String? value = _nullableString(map, key);
  if (value == null) return null;
  return p.join(root.path, _resourceName(resources, value));
}

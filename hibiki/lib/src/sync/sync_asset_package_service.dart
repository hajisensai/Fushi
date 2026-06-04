import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
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

    // 主 isolate：收集文件清单（zip 内路径 → 磁盘路径），不读内容。
    final Map<String, String> archivePathToSource = <String, String>{};
    if (await sourceDir.exists()) {
      await for (final FileSystemEntity entity
          in sourceDir.list(recursive: true)) {
        if (entity is! File) continue;
        final String relativePath =
            p.relative(entity.path, from: sourceDir.path).replaceAll(r'\', '/');
        archivePathToSource['resources/$relativePath'] = entity.path;
      }
    }

    final String manifestJson = jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'kind': 'dictionary',
      'dictionary': _dictionaryManifest(meta),
    });

    outputFile.parent.createSync(recursive: true);
    await _zipPackageInIsolate(
      outputPath: outputFile.path,
      manifestJson: manifestJson,
      archivePathToSource: archivePathToSource,
    );
    return outputFile;
  }

  Future<void> importDictionaryPackage({
    required File packageFile,
    required Directory dictionaryResourceRoot,
  }) async {
    final String manifestJson = await _readManifestInIsolate(packageFile.path);
    final Map<String, Object?> manifest = _typedMap(jsonDecode(manifestJson));
    if (manifest['kind'] != 'dictionary') {
      throw FormatException('Unexpected package kind: ${manifest['kind']}');
    }
    final Map<String, Object?> dictionary = _mapValue(manifest, 'dictionary');
    final String name = _stringValue(dictionary, 'name');

    await _db.upsertDictionaryMeta(DictionaryMetadataCompanion.insert(
      name: name,
      formatKey: _stringValue(dictionary, 'formatKey'),
      order: _intValue(dictionary, 'order'),
      type: Value(_stringValue(dictionary, 'type')),
      metadataJson: Value(_stringValue(dictionary, 'metadataJson')),
      hiddenLanguagesJson: Value(_stringValue(dictionary, 'hiddenLanguagesJson')),
      collapsedLanguagesJson:
          Value(_stringValue(dictionary, 'collapsedLanguagesJson')),
    ));

    final Directory targetDir = Directory(
      p.join(dictionaryResourceRoot.path, name),
    );
    await _extractResourcesInIsolate(
      packagePath: packageFile.path,
      targetDirPath: targetDir.path,
      prefix: 'resources',
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
    final List<File> files = _audioPackageFiles(audiobook, srtBook);

    // 主 isolate：分配唯一文件名，建立 manifest 的 resources 映射（源路径→名）
    // 与 isolate 的 zip 内路径映射（resources/名→源路径）。
    final Map<String, String> resourceNames = <String, String>{}; // src -> name
    final Map<String, String> archivePathToSource = <String, String>{};
    final Set<String> usedNames = <String>{};
    for (final File file in files) {
      if (!await file.exists()) continue;
      final String name = _uniqueFileName(file, usedNames);
      resourceNames[file.path] = name;
      archivePathToSource['resources/$name'] = file.path;
    }

    final String manifestJson = jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'kind': 'audioDatabase',
      'audiobook': _audiobookManifest(audiobook),
      'srtBook': _srtBookManifest(srtBook),
      'cues': cues.map(_audioCueManifest).toList(),
      'resources': resourceNames,
    });

    outputFile.parent.createSync(recursive: true);
    await _zipPackageInIsolate(
      outputPath: outputFile.path,
      manifestJson: manifestJson,
      archivePathToSource: archivePathToSource,
    );
    return outputFile;
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
    final String manifestJson = await _readManifestInIsolate(packageFile.path);
    final Map<String, Object?> manifest = _typedMap(jsonDecode(manifestJson));
    if (manifest['kind'] != 'audioDatabase') {
      throw FormatException('Unexpected package kind: ${manifest['kind']}');
    }
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

    await _extractResourcesInIsolate(
      packagePath: packageFile.path,
      targetDirPath: targetDir.path,
      prefix: 'resources',
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

// ── 流式打包辅助（跑在后台 isolate，纯文件→文件，不依赖 DB / Flutter）─────────
//
// OOM 根因修复：旧实现把整个资源文件 readAsBytes、整个 zip 在内存里 encode/decode。
// 这里改用 archive_io 流式（ZipFileEncoder.addFile 经 InputFileStream 逐块读，
// ArchiveFile.writeContent 经 OutputFileStream 逐块写），并整体放进 Isolate.run，
// 让 deflate/inflate 的 CPU 与磁盘 IO 都离开 UI isolate。

/// 流式打 zip：把 [archivePathToSource]（zip 内路径 → 磁盘绝对路径）的每个文件
/// 流式写入 [outputPath]，并把 [manifestJson] 作为 `manifest.json` 写入。
Future<void> _zipPackageInIsolate({
  required String outputPath,
  required String manifestJson,
  required Map<String, String> archivePathToSource,
}) async {
  await Isolate.run(() async {
    final ZipFileEncoder encoder = ZipFileEncoder();
    encoder.create(outputPath);
    final List<int> manifestBytes = utf8.encode(manifestJson);
    encoder.addArchiveFile(
      ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
    );
    for (final MapEntry<String, String> entry in archivePathToSource.entries) {
      final File file = File(entry.value);
      if (!file.existsSync()) continue;
      // addFile 内部用 InputFileStream 流式读，不整文件入内存。
      await encoder.addFile(file, entry.key);
    }
    encoder.closeSync();
  });
}

/// 只读取包内 `manifest.json`（小，进内存）。decodeBuffer 只读中央目录 + 惰性流，
/// 不解压全部条目，因此很轻。
Future<String> _readManifestInIsolate(String packagePath) async {
  return Isolate.run(() {
    final InputFileStream input = InputFileStream(packagePath);
    try {
      final Archive archive = ZipDecoder().decodeBuffer(input);
      final ArchiveFile? manifestFile = archive.findFile('manifest.json');
      if (manifestFile == null) {
        throw const FormatException('Package manifest is missing');
      }
      return utf8.decode(manifestFile.content as List<int>);
    } finally {
      input.closeSync();
    }
  });
}

/// 流式把 [prefix]/ 下的资源解压到 [targetDirPath]。保留 zip-slip 路径安全校验
/// （与旧 _extractArchivePrefix 等价），每个文件经 OutputFileStream 逐块落盘。
Future<void> _extractResourcesInIsolate({
  required String packagePath,
  required String targetDirPath,
  required String prefix,
}) async {
  await Isolate.run(() {
    final InputFileStream input = InputFileStream(packagePath);
    try {
      final Archive archive = ZipDecoder().decodeBuffer(input);
      final String canonicalRoot = p.canonicalize(targetDirPath);
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
        final String targetPath =
            p.normalize(p.join(targetDirPath, normalizedRelative));
        final String canonicalTarget = p.canonicalize(targetPath);
        if (canonicalTarget != canonicalRoot &&
            !p.isWithin(canonicalRoot, canonicalTarget)) {
          throw FormatException('Invalid package path: ${file.name}');
        }
        File(targetPath).parent.createSync(recursive: true);
        final OutputFileStream out = OutputFileStream(targetPath);
        try {
          file.writeContent(out);
        } finally {
          out.closeSync();
        }
      }
    } finally {
      input.closeSync();
    }
  });
}

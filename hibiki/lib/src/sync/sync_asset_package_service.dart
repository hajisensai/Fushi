import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart';
import 'package:hibiki/src/models/local_audio_source_pref.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// [SyncAssetPackageService.importLocalAudioPackage] 的解析结果：已解压到本机
/// staging 目录的 .db 文件 + manifest 携带的配置。注册（拷进库目录 / 写 prefs /
/// 推 native）由调用方（`AppModel.importSyncedLocalAudioDb`）完成。
class LocalAudioPackageContents {
  const LocalAudioPackageContents({
    required this.dbFile,
    required this.displayName,
    required this.enabled,
    required this.sources,
  });
  final File dbFile;
  final String displayName;
  final bool enabled;
  final List<LocalAudioSourcePref> sources;
}

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
    // 词典 JSON 可压缩，保留 deflate 省上传体积；词典资源文件较小，单文件入内存可接受。
    await _zipPackageInIsolate(
      outputPath: outputFile.path,
      manifestJson: manifestJson,
      archivePathToSource: archivePathToSource,
      storeResources: false,
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
      hiddenLanguagesJson:
          Value(_stringValue(dictionary, 'hiddenLanguagesJson')),
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
    required String bookKey,
    required String srtBookUid,
    required File outputFile,
  }) async {
    final AudiobookRow audiobook = (await _db.getAudiobookByBookKey(bookKey))!;
    final SrtBookRow srtBook = (await _db.getSrtBookByUid(srtBookUid))!;
    final List<AudioCueRow> cues = await _db.getCuesForBook(bookKey);
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
    // 音频/字幕/封面已是压缩格式或很小，STORE 既流式（不整大文件入内存）又不浪费 CPU。
    await _zipPackageInIsolate(
      outputPath: outputFile.path,
      manifestJson: manifestJson,
      archivePathToSource: archivePathToSource,
      storeResources: true,
    );
    return outputFile;
  }

  /// Imports an audiobook package. [bookKeyOverride] re-keys the imported
  /// audiobook + cues AND the SRT book's bookKey to the importing device's own
  /// book. Cross-device sync needs this because bookKey = sanitized title is
  /// stable across devices, but the override lets the caller bind the package to
  /// the exact local book it resolved.
  Future<void> importAudioDatabasePackage({
    required File packageFile,
    required Directory audioDatabaseRoot,
    String? bookKeyOverride,
  }) async {
    final String manifestJson = await _readManifestInIsolate(packageFile.path);
    final Map<String, Object?> manifest = _typedMap(jsonDecode(manifestJson));
    if (manifest['kind'] != 'audioDatabase') {
      throw FormatException('Unexpected package kind: ${manifest['kind']}');
    }
    final Map<String, Object?> audiobook = _mapValue(manifest, 'audiobook');
    final Map<String, Object?> srtBook = _mapValue(manifest, 'srtBook');
    final Map<String, Object?> resources = _mapValue(manifest, 'resources');
    final String bookKey =
        bookKeyOverride ?? _stringValue(audiobook, 'bookKey');
    // The on-disk directory name must be filesystem-safe: a bookKey (sanitized
    // title) is mostly safe but may still contain spaces/unicode; _safeDirName
    // strips any Windows-invalid chars. The DB still keys rows by [bookKey];
    // only the storage directory name is sanitized.
    final Directory targetDir =
        Directory(p.join(audioDatabaseRoot.path, _safeDirName(bookKey)));

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
      bookKey: bookKey,
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
      bookKey: Value(bookKey),
    ));

    await _db.replaceCuesForBook(
      bookKey,
      _listValue(manifest, 'cues').map((Object? raw) {
        final Map<String, Object?> cue = _typedMap(raw);
        return AudioCuesCompanion.insert(
          bookKey: bookKey,
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

  /// 打包一个本地音频库：单个 .db（STORE 流式）+ manifest（displayName/enabled/子来源）。
  /// [dbFile] 是该库的本机 .db 主文件（不含 -wal/-shm，导入后由 sqlite 自建）。
  Future<File> exportLocalAudioPackage({
    required String displayName,
    required bool enabled,
    required List<LocalAudioSourcePref> sources,
    required File dbFile,
    required File outputFile,
  }) async {
    final String dbFileName = p.basename(dbFile.path);
    final String manifestJson = jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'kind': 'localAudio',
      'localAudio': <String, Object?>{
        'displayName': displayName,
        'enabled': enabled,
        'dbFileName': dbFileName,
        'sources': sources.map((LocalAudioSourcePref s) => s.toJson()).toList(),
      },
    });
    outputFile.parent.createSync(recursive: true);
    // 发音 DB 可达几百 MB：STORE 走真流式（不整文件入内存），且 sqlite 已是二进制
    // 难压缩，deflate 只是浪费 CPU 还会整文件入内存 OOM。
    await _zipPackageInIsolate(
      outputPath: outputFile.path,
      manifestJson: manifestJson,
      archivePathToSource: <String, String>{
        'resources/$dbFileName': dbFile.path
      },
      storeResources: true,
    );
    return outputFile;
  }

  /// 解析本地音频包：读 manifest + 把 .db 流式解压到 [stagingDir]，返回内容。
  /// 不写任何 prefs / 不推 native（注册由 AppModel 负责，保持双真相源一致 +
  /// 本机重建 path：远端 manifest 的绝对 path 在本机不存在，绝不能直接复用）。
  Future<LocalAudioPackageContents> importLocalAudioPackage({
    required File packageFile,
    required Directory stagingDir,
  }) async {
    final String manifestJson = await _readManifestInIsolate(packageFile.path);
    final Map<String, Object?> manifest = _typedMap(jsonDecode(manifestJson));
    if (manifest['kind'] != 'localAudio') {
      throw FormatException('Unexpected package kind: ${manifest['kind']}');
    }
    final Map<String, Object?> meta = _mapValue(manifest, 'localAudio');
    final String displayName = _stringValue(meta, 'displayName');
    final String dbFileName = _stringValue(meta, 'dbFileName');
    final bool enabled = _nullableBool(meta, 'enabled') ?? true;
    final List<LocalAudioSourcePref> sources =
        _listValue(meta, 'sources').map((Object? raw) {
      final Map<String, Object?> m = _typedMap(raw);
      return LocalAudioSourcePref(
        name: _stringValue(m, 'name'),
        enabled: _nullableBool(m, 'enabled') ?? true,
      );
    }).toList();

    await _extractResourcesInIsolate(
      packagePath: packageFile.path,
      targetDirPath: stagingDir.path,
      prefix: 'resources',
    );
    return LocalAudioPackageContents(
      dbFile: File(p.join(stagingDir.path, dbFileName)),
      displayName: displayName,
      enabled: enabled,
      sources: sources,
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
      'bookKey': row.bookKey,
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
      'bookKey': row.bookKey,
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

// ── 打包辅助（跑在后台 isolate，纯文件→文件，不依赖 DB / Flutter）─────────
//
// OOM 根因修复：旧实现把整个资源文件读进内存、整个 zip 在内存里编解码，且整条
// 编解码链跑在 UI isolate。这里整体放进 Isolate.run（deflate/inflate 的 CPU 与
// 磁盘 IO 都离开 UI isolate），不再整 zip 入内存，并按包类型选择压缩策略：
//
// - 音频包用 STORE（[storeResources]=true）：archive 3.6.1 的 STORE 分支对
//   `ArchiveFile.stream` 真流式（getFileCrc32 分块读 + writeInputStream 直接转发，
//   不 toUint8List），单个几百 MB 的音频/封面文件不会整入内存；音频/图片本就是
//   压缩格式，deflate 也只是浪费 CPU。
// - 词典包用 deflate（[storeResources]=false）：词典 JSON 可压缩省上传体积。注意
//   archive 3.6.1 的 GZIP/deflate 分支会 `toUint8List()` 把单个文件整入内存再整块
//   Deflate（addFile 的 InputFileStream 在此被 buffer 化），是 archive 3.6.1 的已知
//   限制；词典资源文件较小，逐文件入内存可接受（如需进一步降内存可改 STORE 词典）。
// - 导入用 ArchiveFile.decompress(OutputFileStream)：STORE→writeInputStream、
//   DEFLATE→Inflate.stream，两者都逐块落盘、无整文件入内存。

/// 把 [archivePathToSource]（zip 内路径 → 磁盘绝对路径）的每个文件写入
/// [outputPath]，并把 [manifestJson] 作为 `manifest.json` 写入。
/// [storeResources]=true 用 STORE（流式、不整文件入内存），false 用 deflate
/// （逐文件压缩、单文件入内存，详见上方说明）。
Future<void> _zipPackageInIsolate({
  required String outputPath,
  required String manifestJson,
  required Map<String, String> archivePathToSource,
  required bool storeResources,
}) async {
  await Isolate.run(() async {
    final ZipFileEncoder encoder = ZipFileEncoder();
    encoder.create(outputPath);
    try {
      final List<int> manifestBytes = utf8.encode(manifestJson);
      encoder.addArchiveFile(
        ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
      );
      for (final MapEntry<String, String> entry
          in archivePathToSource.entries) {
        final File file = File(entry.value);
        if (!file.existsSync()) continue;
        await encoder.addFile(
          file,
          entry.key,
          storeResources ? ZipFileEncoder.STORE : ZipFileEncoder.GZIP,
        );
      }
      encoder.closeSync();
    } catch (_) {
      // 释放底层 OutputFileStream 句柄；旧的 writeAsBytes(flush:true) 是原子的，
      // 不留半截 zip——流式化后必须手动删掉中途失败留下的半截包，避免被当成有效包。
      encoder.closeSync();
      try {
        final File partial = File(outputPath);
        if (partial.existsSync()) partial.deleteSync();
      } catch (_) {
        // best-effort：删半截包失败不掩盖原始导出异常，rethrow 才是真错。
      }
      rethrow;
    }
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

/// 把 [prefix]/ 下的资源解压到 [targetDirPath]。保留 zip-slip 路径安全校验
/// （与旧 _extractArchivePrefix 等价），每个文件经 [_streamArchiveFileTo] 逐块落盘
/// （STORE→writeInputStream、DEFLATE→Inflate.stream，均不整文件入内存）。
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
          _streamArchiveFileTo(file, out);
        } finally {
          out.closeSync();
        }
      }
    } finally {
      input.closeSync();
    }
  });
}

/// 把 `decodeBuffer` 出来的 [file] 流式写入 [out]，不整文件入内存。
///
/// 不能用 `ArchiveFile.decompress(out)`：archive 3.6.1 的 `ZipDecoder.decodeBuffer`
/// 把每个条目构造成 `ArchiveFile(name, size, ZipFile, compressionMethod)`，`ZipFile`
/// 是 `FileContent`，于是 `ArchiveFile._content` 被设为该 ZipFile（**非 null**），
/// `decompress(out)` 的前置 `_content==null && _rawContent!=null` 不成立 → 直接 no-op
/// 写出 0 字节。`writeContent(out)` 又会先 `_content.content`（`ZipFile.content` getter）
/// 把整文件解压进内存（STORE→toUint8List、DEFLATE→inflateBuffer）——正是导入侧 OOM 源。
///
/// 真正的流式落盘：直接消费条目的原始压缩流 [ArchiveFile.rawContent]（从
/// `InputFileStream` 解出来时是惰性窗口文件流，不在内存），按压缩类型分流：
/// - STORE：`out.writeInputStream(raw)` 逐块拷贝（raw 即未压缩字节）；
/// - DEFLATE：`Inflate.stream(raw, out)` 逐块 inflate 直接写 out。
void _streamArchiveFileTo(ArchiveFile file, OutputFileStream out) {
  final InputStreamBase? raw = file.rawContent;
  if (raw == null) {
    // 防御：无原始流时回退到 writeContent（会整文件入内存，但保证正确性）。
    file.writeContent(out);
    return;
  }
  switch (file.compressionType) {
    case ArchiveFile.STORE:
      out.writeInputStream(raw);
      break;
    case ArchiveFile.DEFLATE:
      Inflate.stream(raw, out);
      break;
    default:
      // 其它压缩（bzip2/aes 等）本打包格式不产出；回退到 writeContent 保正确。
      file.writeContent(out);
  }
}

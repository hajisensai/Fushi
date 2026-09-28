import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:fushi_engine/sync/ttu_models.dart';
import 'package:path/path.dart' as p;

/// 第三方阅读器备份的来源种类。目前只认 Hoshi Reader（iOS / Android 共用同一
/// `.hoshi` 书库备份格式）；以后再接别家时在这里加值，而不是另起一套模型。
enum ExternalReaderBackupKind { hoshi }

/// Hoshi 的时间戳（`metadata.lastAccess` / `bookmark.lastModified`）是 Apple
/// 纪元秒（2001-01-01 UTC 起，Swift `JSONEncoder` 对 `Date` 的默认编码；Android
/// 版刻意对齐同一口径），与 unix 纪元差这么多秒。
const int kAppleReferenceEpochOffsetSeconds = 978307200;

/// 单个 JSON sidecar 的读入上限。统计 / 书签 / bookinfo 正常都在 KB–MB 量级，
/// 超过这个数不是正常备份，按坏文件处理而不是整块读进内存。
const int _kMaxJsonEntryBytes = 64 * 1024 * 1024;

/// `yyyy-MM-dd`（补零）。统计读取面按字典序比较 dateKey、`statDateKeyToDay`
/// 遇到非法键会抛，所以不合这个形状的日记录一律丢弃。
final RegExp _dateKeyPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Hoshi 的书签：`chapterIndex` 是 spine 下标，`progress` 是章内 0..1，
/// `characterCount` 是全书绝对字符偏移（≈ ッツ `exploredCharCount`）。
class ExternalReaderBookmark {
  const ExternalReaderBookmark({
    required this.chapterIndex,
    required this.progress,
    required this.characterCount,
    required this.lastModifiedAt,
  });

  final int chapterIndex;
  final double progress;
  final int characterCount;

  /// unix 毫秒；Hoshi 没写 `lastModified` 时为 null。
  final int? lastModifiedAt;
}

/// `bookinfo.json` 里的一章：键是 manifest 路径（相对 OPF 目录），`currentTotal`
/// 是本章起点的全书字符偏移。
class ExternalReaderChapterSpan {
  const ExternalReaderChapterSpan({
    required this.manifestPath,
    required this.spineIndex,
    required this.currentTotal,
    required this.chapterCount,
  });

  final String manifestPath;
  final int? spineIndex;
  final int currentTotal;
  final int chapterCount;
}

class ExternalReaderBookInfo {
  const ExternalReaderBookInfo({
    required this.characterCount,
    required this.chapters,
  });

  final int characterCount;
  final List<ExternalReaderChapterSpan> chapters;
}

/// iOS 版 `statistics.json` 的一次阅读会话（会话 map 形态）。
class ExternalReaderSession {
  const ExternalReaderSession({
    required this.id,
    required this.modifiedAt,
    required this.startedAt,
    required this.endedAt,
    required this.charactersRead,
    required this.readingTimeSec,
  });

  final String id;

  /// unix 毫秒；缺失为 0。
  final int modifiedAt;
  final int startedAt;
  final int endedAt;
  final int charactersRead;
  final double readingTimeSec;
}

/// 备份里的一本书（或 `statistics_archive/` 里一本已删书的统计）。
class ExternalReaderBook {
  const ExternalReaderBook({
    required this.directory,
    required this.title,
    required this.author,
    required this.renamedTitle,
    required this.lastAccessAt,
    required this.epubEntry,
    required this.bookmark,
    required this.bookInfo,
    required this.sessions,
    required this.dailyRecords,
    required this.isArchived,
    required this.problems,
  });

  /// zip 内的目录路径（正斜杠、无尾斜杠），报告与定位用。
  final String directory;

  /// Hoshi 记录的原始书名（`metadata.title`，缺失时退回目录名）。
  final String title;
  final String? author;
  final String? renamedTitle;

  /// unix 毫秒；缺失为 null。
  final int? lastAccessAt;

  /// 原始 `.epub` 在 zip 内的条目名；已删书 / 老版本解压树形态为 null。
  final String? epubEntry;
  final ExternalReaderBookmark? bookmark;
  final ExternalReaderBookInfo? bookInfo;

  /// iOS 会话形态统计（已剔除 `value: null` 的删除标记）。
  final List<ExternalReaderSession> sessions;

  /// ッツ日记录形态统计（Android / 旧 iOS），已按 dateKey 去重（取
  /// `lastStatisticModified` 大者）。
  final List<TtuStatistics> dailyRecords;

  /// 来自 `statistics_archive/`：Hoshi 里已删掉的书，只剩统计。
  final bool isArchived;

  /// 读这本书时遇到的非致命问题（坏 JSON 等），进导入报告。
  final List<String> problems;

  bool get hasStatistics => sessions.isNotEmpty || dailyRecords.isNotEmpty;
}

class ExternalReaderBackup {
  const ExternalReaderBackup({
    required this.kind,
    required this.archivePath,
    required this.books,
  });

  final ExternalReaderBackupKind kind;
  final String archivePath;
  final List<ExternalReaderBook> books;
}

/// 备份文件本身读不了（不是 zip / 里面一本书都没有）。
class ExternalReaderBackupFormatException implements Exception {
  const ExternalReaderBackupFormatException(this.message);

  final String message;

  @override
  String toString() => 'ExternalReaderBackupFormatException($message)';
}

/// 扫描一份 Hoshi Reader 的 `Books_*.hoshi` 书库备份（纯 zip）。
///
/// 只解析中央目录和各书的小 JSON（`metadata` / `bookinfo` / `bookmark` /
/// `statistics`），`.epub` 本体留到导入时再按条目抽取，所以多 GB 的备份也只
/// 占用 JSON 那点内存。在后台 isolate 里跑。
Future<ExternalReaderBackup> scanExternalReaderBackup(String archivePath) =>
    Isolate.run(() => scanExternalReaderBackupSync(archivePath));

/// [scanExternalReaderBackup] 的同步实现（测试与 isolate 共用）。
ExternalReaderBackup scanExternalReaderBackupSync(String archivePath) {
  final InputFileStream input = InputFileStream(archivePath);
  try {
    final Archive archive;
    try {
      // verify 必须保持 false：true 会把每个条目都解压一遍算 CRC。
      archive = ZipDecoder().decodeBuffer(input);
    } catch (e) {
      throw ExternalReaderBackupFormatException('not a zip archive: $e');
    }
    final Map<String, ArchiveFile> filesByName = <String, ArchiveFile>{};
    for (final ArchiveFile file in archive.files) {
      if (!file.isFile) continue;
      final String name = _normalizeEntryName(file.name);
      if (name.isEmpty || _isIgnoredEntry(name)) continue;
      filesByName[name] = file;
    }
    final List<String> bookDirectories = <String>[
      for (final String name in filesByName.keys)
        if (p.posix.basename(name) == 'metadata.json') p.posix.dirname(name),
    ]..sort();
    final List<ExternalReaderBook> books = <ExternalReaderBook>[];
    for (final String directory in bookDirectories) {
      final ExternalReaderBook? book = _readBook(directory, filesByName);
      if (book != null) books.add(book);
    }
    if (books.isEmpty) {
      throw const ExternalReaderBackupFormatException('no books found');
    }
    return ExternalReaderBackup(
      kind: ExternalReaderBackupKind.hoshi,
      archivePath: archivePath,
      books: books,
    );
  } finally {
    input.closeSync();
  }
}

/// 把备份里 [entryName] 这个条目解压到 [outPath]（后台 isolate）。导入时一本
/// 一本调用：内存峰值是单本 epub 的大小，与 `EpubParser` 读整本进内存同量级。
Future<void> extractExternalReaderBackupEntry({
  required String archivePath,
  required String entryName,
  required String outPath,
}) => Isolate.run(() {
  final InputFileStream input = InputFileStream(archivePath);
  try {
    final Archive archive = ZipDecoder().decodeBuffer(input);
    ArchiveFile? match;
    for (final ArchiveFile file in archive.files) {
      if (file.isFile && _normalizeEntryName(file.name) == entryName) {
        match = file;
        break;
      }
    }
    if (match == null) {
      throw ExternalReaderBackupFormatException('missing entry $entryName');
    }
    File(outPath).parent.createSync(recursive: true);
    final OutputFileStream output = OutputFileStream(outPath);
    try {
      match.writeContent(output);
    } finally {
      output.closeSync();
    }
  } finally {
    input.closeSync();
  }
});

String _normalizeEntryName(String raw) {
  String name = raw.replaceAll('\\', '/');
  while (name.startsWith('/')) {
    name = name.substring(1);
  }
  if (name.endsWith('/')) name = name.substring(0, name.length - 1);
  return name;
}

/// macOS 压缩器塞进来的 `__MACOSX/`、任何以 `.` 开头的段（`.sync.json`、
/// `.DS_Store`）都不是书的数据。
bool _isIgnoredEntry(String name) {
  for (final String segment in name.split('/')) {
    if (segment == '__MACOSX' || segment.startsWith('.')) return true;
  }
  return false;
}

ExternalReaderBook? _readBook(
  String directory,
  Map<String, ArchiveFile> filesByName,
) {
  final List<String> problems = <String>[];
  String entry(String fileName) =>
      directory == '.' ? fileName : '$directory/$fileName';

  final Object? metadataJson = _readJson(
    filesByName[entry('metadata.json')],
    'metadata.json',
    problems,
  );
  if (metadataJson is! Map) {
    // 书目录的判据就是有一份能读的 metadata；读不了的不当书（也可能是 epub
    // 解压树里恰好叫 metadata.json 的别的文件）。
    return null;
  }
  final String folderName = directory == '.' ? '' : p.posix.basename(directory);
  final String? metadataTitle = _nonBlankString(metadataJson['title']);
  final String title = metadataTitle ?? folderName;
  if (title.isEmpty) return null;

  final bool isArchived =
      directory != '.' &&
      p.posix.basename(p.posix.dirname(directory)) == 'statistics_archive';
  // 两种统计形态按顶层类型分流：对象 = iOS 会话 map，数组 = ッツ日记录。
  final Object? statisticsJson = _readJson(
    filesByName[entry('statistics.json')],
    'statistics.json',
    problems,
  );

  return ExternalReaderBook(
    directory: directory,
    title: title,
    author: _nonBlankString(metadataJson['author']),
    renamedTitle: _nonBlankString(metadataJson['renamedTitle']),
    lastAccessAt: _appleSecondsToUnixMs(metadataJson['lastAccess']),
    epubEntry: isArchived
        ? null
        : _findEpubEntry(
            directory: directory,
            declared: _nonBlankString(metadataJson['epub']),
            folderName: folderName,
            filesByName: filesByName,
          ),
    bookmark: _parseBookmark(
      _readJson(filesByName[entry('bookmark.json')], 'bookmark.json', problems),
    ),
    bookInfo: _parseBookInfo(
      _readJson(filesByName[entry('bookinfo.json')], 'bookinfo.json', problems),
    ),
    sessions: _parseSessions(statisticsJson),
    dailyRecords: _parseDailyRecords(statisticsJson),
    isArchived: isArchived,
    problems: problems,
  );
}

Object? _readJson(ArchiveFile? file, String label, List<String> problems) {
  if (file == null) return null;
  if (file.size > _kMaxJsonEntryBytes) {
    problems.add('$label: too large (${file.size} bytes)');
    return null;
  }
  try {
    final List<int> bytes = file.content as List<int>;
    return jsonDecode(utf8.decode(bytes, allowMalformed: true));
  } on ArchiveException catch (e) {
    // 条目本身解压失败（备份在传输中损坏）：只作废这一个文件。
    // （ArchiveException 是 FormatException 的子类，必须排在前面。）
    problems.add('$label: unreadable ($e)');
    return null;
  } on FormatException catch (e) {
    problems.add('$label: invalid json (${e.message})');
    return null;
  }
}

/// 本书的原始 epub 条目：优先 `metadata.epub`（iOS 存的是用户当初选的源文件
/// 名），否则目录里唯一的 `*.epub`（Android 恒为 `<folder>.epub`）。
String? _findEpubEntry({
  required String directory,
  required String? declared,
  required String folderName,
  required Map<String, ArchiveFile> filesByName,
}) {
  final String prefix = directory == '.' ? '' : '$directory/';
  if (declared != null) {
    final String candidate = '$prefix${p.posix.basename(declared)}';
    if (filesByName.containsKey(candidate)) return candidate;
  }
  final List<String> direct = <String>[
    for (final String name in filesByName.keys)
      if (name.startsWith(prefix) &&
          !name.substring(prefix.length).contains('/') &&
          name.toLowerCase().endsWith('.epub'))
        name,
  ];
  if (direct.length == 1) return direct.single;
  final String byFolder = '$prefix$folderName.epub';
  if (direct.contains(byFolder)) return byFolder;
  return null;
}

ExternalReaderBookmark? _parseBookmark(Object? json) {
  if (json is! Map) return null;
  final num? chapterIndex = _asNum(json['chapterIndex']);
  final num? characterCount = _asNum(json['characterCount']);
  if (chapterIndex == null || characterCount == null) return null;
  return ExternalReaderBookmark(
    chapterIndex: chapterIndex.toInt(),
    progress: (_asNum(json['progress']) ?? 0).toDouble(),
    characterCount: characterCount.toInt(),
    lastModifiedAt: _appleSecondsToUnixMs(json['lastModified']),
  );
}

ExternalReaderBookInfo? _parseBookInfo(Object? json) {
  if (json is! Map) return null;
  final Object? chapterInfo = json['chapterInfo'];
  final List<ExternalReaderChapterSpan> chapters =
      <ExternalReaderChapterSpan>[];
  if (chapterInfo is Map) {
    for (final MapEntry<Object?, Object?> e in chapterInfo.entries) {
      final Object? key = e.key;
      final Object? value = e.value;
      if (key is! String || value is! Map) continue;
      final num? currentTotal = _asNum(value['currentTotal']);
      final num? chapterCount = _asNum(value['chapterCount']);
      if (currentTotal == null || chapterCount == null) continue;
      chapters.add(
        ExternalReaderChapterSpan(
          manifestPath: key,
          spineIndex: _asNum(value['spineIndex'])?.toInt(),
          currentTotal: currentTotal.toInt(),
          chapterCount: chapterCount.toInt(),
        ),
      );
    }
  }
  chapters.sort(
    (ExternalReaderChapterSpan a, ExternalReaderChapterSpan b) =>
        a.currentTotal.compareTo(b.currentTotal),
  );
  return ExternalReaderBookInfo(
    characterCount: (_asNum(json['characterCount']) ?? 0).toInt(),
    chapters: chapters,
  );
}

/// iOS 会话 map：`{uuid: {modified, value: {startedAt, endedAt, charactersRead,
/// readingTime} | null}}`。`value == null` 是 Hoshi 的删除标记，跳过。
List<ExternalReaderSession> _parseSessions(Object? json) {
  if (json is! Map) return const <ExternalReaderSession>[];
  final List<ExternalReaderSession> sessions = <ExternalReaderSession>[];
  for (final MapEntry<Object?, Object?> e in json.entries) {
    final Object? id = e.key;
    final Object? wrapper = e.value;
    if (id is! String || id.isEmpty || wrapper is! Map) continue;
    final Object? value = wrapper['value'];
    if (value is! Map) continue;
    final num? startedAt = _asNum(value['startedAt']);
    final num? endedAt = _asNum(value['endedAt']);
    if (startedAt == null || endedAt == null || startedAt <= 0) continue;
    sessions.add(
      ExternalReaderSession(
        id: id,
        modifiedAt: (_asNum(wrapper['modified']) ?? 0).toInt(),
        startedAt: startedAt.toInt(),
        endedAt: endedAt.toInt(),
        charactersRead: (_asNum(value['charactersRead']) ?? 0).toInt(),
        readingTimeSec: (_asNum(value['readingTime']) ?? 0).toDouble(),
      ),
    );
  }
  sessions.sort(
    (ExternalReaderSession a, ExternalReaderSession b) =>
        a.startedAt.compareTo(b.startedAt),
  );
  return sessions;
}

/// ッツ日记录数组。逐元素容错（坏元素 / 非法 dateKey 跳过，不整份作废），同一
/// dateKey 多条取 `lastStatisticModified` 大者（与 Hoshi Android 的读取口径一致）。
List<TtuStatistics> _parseDailyRecords(Object? json) {
  if (json is! List) return const <TtuStatistics>[];
  final Map<String, TtuStatistics> byDate = <String, TtuStatistics>{};
  for (final Object? item in json) {
    if (item is! Map) continue;
    final TtuStatistics record = TtuStatistics.fromJson(
      Map<String, dynamic>.from(item),
    );
    if (!_dateKeyPattern.hasMatch(record.dateKey)) continue;
    final TtuStatistics? existing = byDate[record.dateKey];
    if (existing == null ||
        record.lastStatisticModified > existing.lastStatisticModified) {
      byDate[record.dateKey] = record;
    }
  }
  final List<String> keys = byDate.keys.toList()..sort();
  return <TtuStatistics>[for (final String k in keys) byDate[k]!];
}

int? _appleSecondsToUnixMs(Object? value) {
  final num? seconds = _asNum(value);
  if (seconds == null || seconds <= 0) return null;
  return ((seconds + kAppleReferenceEpochOffsetSeconds) * 1000).round();
}

num? _asNum(Object? value) => value is num ? value : null;

String? _nonBlankString(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

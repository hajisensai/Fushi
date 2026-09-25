import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show FushiDicts;
import 'package:sqlite3/sqlite3.dart';

/// 读 Anki 备份（`.colpkg` / `.apkg`）里每条笔记的**第一个字段**。
///
/// 这是 iOS（AnkiMobile 后端）上唯一能拿到「Anki 里已经有哪些词」的办法：
/// AnkiMobile 的 URL scheme 没有回读 collection 的入口（见
/// `AnkiMobileMinedLedger`），但它能导出备份。做法对齐 Hoshi Reader iOS 的
/// 「Import Anki Backup」（`AnkiManager.importAnkiBackup`）：解包 → 取 collection
/// → `SELECT flds FROM notes` → 取第一字段。与它不同的两处：
///
/// * 三代 collection 都认：`collection.anki21b`（2.1.50+，zstd 压缩的 SQLite）
///   优先，其次 `collection.anki21`、`collection.anki2`（未压缩的 SQLite）。
///   新版导出会**同时**带一个只有一条「请升级 Anki」占位笔记的
///   `collection.anki2`，所以顺序不能反。Hoshi 只认 anki21b，旧备份直接失败。
/// * 字段先去 HTML 再比较：Anki 自己判重也是去 HTML 后比第一字段
///   （`strip_html_preserving_media_filenames`），`<b>見物</b>` 与 `見物` 是同一个词。
///
/// 整个过程在后台 isolate 里跑：一份 collection 解压后几十到上百 MB、笔记数万
/// 条，放在 UI isolate 上会卡住设置页。[workDir] 放中间文件，结束即删。
Future<Set<String>> readAnkiBackupFirstFields({
  required String backupPath,
  required String workDir,
}) {
  return Isolate.run(
    () =>
        readAnkiBackupFirstFieldsSync(backupPath: backupPath, workDir: workDir),
  );
}

/// zstd 文件 → 文件解压。生产是 [FushiDicts.zstdDecompressFile]（原生 libzstd）。
typedef ZstdFileDecompressor = void Function(String inPath, String outPath);

/// [readAnkiBackupFirstFields] 的同步本体（测试直接调，不起 isolate）。
///
/// [decompressZstd] 只供测试替换：单测宿主上没有 fushidicts 原生库，真解压路径
/// 由 iOS 模拟器集成测试覆盖。
Set<String> readAnkiBackupFirstFieldsSync({
  required String backupPath,
  required String workDir,
  ZstdFileDecompressor decompressZstd = FushiDicts.zstdDecompressFile,
}) {
  final Directory scratch = Directory(workDir)..createSync(recursive: true);
  final InputFileStream input = InputFileStream(backupPath);
  try {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBuffer(input);
    } on ArchiveException catch (e) {
      throw AnkiBackupFormatException('not a zip archive: $e');
    }
    final ArchiveFile? entry = _pickCollectionEntry(archive);
    if (entry == null) {
      throw const AnkiBackupFormatException('no collection in backup');
    }
    final String extracted = '${scratch.path}/${entry.name}';
    final OutputFileStream out = OutputFileStream(extracted);
    try {
      entry.writeContent(out);
    } finally {
      out.closeSync();
    }
    String dbPath = extracted;
    if (entry.name == _kCollectionZstd) {
      dbPath = '${scratch.path}/collection.db';
      decompressZstd(extracted, dbPath);
    }
    return _readFirstFields(dbPath);
  } finally {
    input.closeSync();
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // 临时目录删不掉只是占点空间，不影响导入结果。
    }
  }
}

const String _kCollectionZstd = 'collection.anki21b';

/// 新到旧：见 [readAnkiBackupFirstFields] 的顺序说明。
const List<String> _kCollectionNames = <String>[
  _kCollectionZstd,
  'collection.anki21',
  'collection.anki2',
];

ArchiveFile? _pickCollectionEntry(Archive archive) {
  for (final String name in _kCollectionNames) {
    final ArchiveFile? file = archive.findFile(name);
    if (file != null && file.isFile) return file;
  }
  return null;
}

Set<String> _readFirstFields(String dbPath) {
  final Database db;
  try {
    db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  } on SqliteException catch (e) {
    throw AnkiBackupFormatException('cannot open collection: $e');
  }
  try {
    final ResultSet rows = db.select('SELECT flds FROM notes');
    final Set<String> words = <String>{};
    for (final Row row in rows) {
      final Object? flds = row['flds'];
      if (flds is! String) continue;
      final String word = ankiFirstFieldKey(flds);
      if (word.isNotEmpty) words.add(word);
    }
    return words;
  } on SqliteException catch (e) {
    throw AnkiBackupFormatException('not an Anki collection: $e');
  } finally {
    db.dispose();
  }
}

final RegExp _htmlTag = RegExp(r'<[^>]*>');
final RegExp _numericEntity = RegExp(r'&#(x[0-9a-fA-F]+|[0-9]+);');
const Map<String, String> _namedEntities = <String, String>{
  '&nbsp;': ' ',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&apos;': "'",
  '&amp;': '&',
};

/// Anki 笔记 `flds`（字段以 U+001F 分隔）→ 第一字段的判重键：去 HTML 标签、
/// 解常见实体、trim。与 `AnkiMobileMinedLedger` 的口径（仅 trim）兼容——
/// Fushi 自己制出的卡第一字段本就是纯文本词头。
String ankiFirstFieldKey(String flds) {
  final int sep = flds.indexOf('\u001f');
  String field = sep < 0 ? flds : flds.substring(0, sep);
  field = field.replaceAll(_htmlTag, '');
  field = field.replaceAllMapped(_numericEntity, (Match m) {
    final String body = m.group(1)!;
    final int? code = body.startsWith('x')
        ? int.tryParse(body.substring(1), radix: 16)
        : int.tryParse(body);
    return code == null ? m.group(0)! : String.fromCharCode(code);
  });
  _namedEntities.forEach((String entity, String value) {
    field = field.replaceAll(entity, value);
  });
  return field.trim();
}

/// 选中的文件不是可读的 Anki 备份（没有 collection / collection 不是 SQLite）。
class AnkiBackupFormatException implements Exception {
  const AnkiBackupFormatException(this.message);

  final String message;

  @override
  String toString() => 'AnkiBackupFormatException: $message';
}

/// Anki 包（.apkg / .colpkg）解包与来源集合读取。新旧两种格式解出 SQLite 之后走同一个模型：
///
/// - 新格式：`collection.anki21b`（zstd 压缩的 schema 18 SQLite，配置是 protobuf blob）
///   + `media`（zstd 压缩的 protobuf MediaEntries）+ zstd 压缩的媒体文件；
/// - 旧格式：`collection.anki21` / `collection.anki2`（schema 11，配置在 col 表的 JSON）
///   + JSON 媒体清单 + 原样媒体文件。
///
/// 只读来源，不碰本机状态。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:fushi_engine/srs/apkg/anki_collection_db.dart';
import 'package:fushi_engine/srs/apkg/srs_protobuf.dart';
import 'package:fushi_engine/srs/apkg/srs_zip_file_reader.dart';

/// 导入失败（整包不可用）。单条笔记 / 卡片的问题不抛，进导入报告。
class SrsImportException implements Exception {
  const SrsImportException(this.code, this.message);

  /// 新格式需要 zstd，而排程内核（native/fushi_fsrs）不可用。
  static const String needsKernel = 'needsKernel';

  /// 包里没有集合文件。
  static const String noCollection = 'noCollection';

  /// 包 / 集合损坏。
  static const String corrupt = 'corrupt';

  final String code;
  final String message;

  @override
  String toString() => 'SrsImportException($code): $message';
}

/// zstd 解码函数（库不可用或数据非法时返回 null）。
typedef SrsZstdDecoder = Uint8List? Function(Uint8List data);

/// zstd 文件到文件解码：库不可用返回 null，成功 true，数据非法 / 读写失败 false。
typedef SrsZstdFileDecoder = bool? Function(String inPath, String outPath);

const List<int> _zstdMagic = <int>[0x28, 0xB5, 0x2F, 0xFD];

bool _isZstd(Uint8List b) =>
    b.length >= 4 &&
    b[0] == _zstdMagic[0] &&
    b[1] == _zstdMagic[1] &&
    b[2] == _zstdMagic[2] &&
    b[3] == _zstdMagic[3];

/// fushi-ext 条目名（Fushi 导出时附带的完整日志与设置）。
const String srsFushiExtEntry = 'fushi-ext';

/// 按条目名取一个原始媒体文件（没有返回 null）。异步：本机 Anki 媒体目录的文件读不能卡 UI isolate。
typedef SrsAnkiMediaEntryLoader = Future<Uint8List?> Function(String entry);

/// 解开的包。
///
/// 两种来源：[open] 解 .apkg / .colpkg 压缩包；[fromCollectionFolder] 是本机 Anki
/// 用户数据目录里的「活集合」（collection.anki2 的快照 + collection.media 平铺目录，
/// 见 anki_collection_snapshot.dart）。导入流程只经 [mediaIndex] / [mediaBytes] /
/// [fushiExt] / [latestFormat] 读来源，两种来源走同一条导入路径。
class SrsAnkiPackage {
  SrsAnkiPackage._(
    this._loadEntry,
    this._zstd,
    this.collectionBytes,
    this.latestFormat,
    this.mediaIndex,
    this.fushiExt, {
    this.collectionFile,
  });

  /// 本机 Anki 用户数据目录里的集合：媒体是 `collection.media` 下的平铺文件
  /// （[mediaIndex] 的条目名就是文件名本身），不压缩、没有 fushi-ext。
  ///
  /// 集合 SQLite 不经这里（[collectionBytes] 为空）：调用方直接打开快照文件，
  /// 不把几百 MB 的集合读进内存再写回临时文件。
  factory SrsAnkiPackage.fromCollectionFolder({
    required Map<String, String> mediaIndex,
    required SrsAnkiMediaEntryLoader loadEntry,
  }) => SrsAnkiPackage._(
    loadEntry,
    _noZstd,
    Uint8List(0),
    false,
    mediaIndex,
    null,
  );

  static Uint8List? _noZstd(Uint8List data) => null;

  final SrsAnkiMediaEntryLoader _loadEntry;
  final SrsZstdDecoder _zstd;

  /// 解压后的 SQLite 字节（[open] 解内存里的包时才有；[openFile] 为空，见 [collectionFile]）。
  final Uint8List collectionBytes;

  /// [openFile] 解出的集合 SQLite 文件（在调用方给的工作目录里）。
  final File? collectionFile;

  /// 新格式（collection.anki21b）。
  final bool latestFormat;

  /// 媒体名 → 包内条目名（"0"、"1"…）。
  final Map<String, String> mediaIndex;

  /// fushi-ext JSON（没有为 null）。
  final Map<String, Object?>? fushiExt;

  static Uint8List _bytesOf(ArchiveFile f) {
    final Object? c = f.content;
    if (c is Uint8List) return c;
    if (c is List<int>) return Uint8List.fromList(c);
    return Uint8List(0);
  }

  /// 解包。[zstd] 只在新格式时用到；它返回 null 视为排程内核不可用。
  static SrsAnkiPackage open(Uint8List bytes, {required SrsZstdDecoder zstd}) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } on Object catch (e) {
      throw SrsImportException(SrsImportException.corrupt, 'not a zip: $e');
    }
    ArchiveFile? find(String name) => archive.findFile(name);

    Uint8List unzstd(Uint8List data, String what) {
      final Uint8List? out = _tryZstd(zstd, data);
      if (out == null) {
        throw SrsImportException(
          SrsImportException.needsKernel,
          '$what is zstd-compressed (new .apkg format) and the scheduling '
          'kernel library is unavailable',
        );
      }
      return out;
    }

    Uint8List collection;
    bool latest = false;
    final ArchiveFile? c21b = find('collection.anki21b');
    final ArchiveFile? c21 = find('collection.anki21');
    final ArchiveFile? c2 = find('collection.anki2');
    if (c21b != null) {
      collection = unzstd(_bytesOf(c21b), 'collection.anki21b');
      latest = true;
    } else if (c21 != null) {
      collection = _bytesOf(c21);
    } else if (c2 != null) {
      collection = _bytesOf(c2);
    } else {
      throw const SrsImportException(
        SrsImportException.noCollection,
        'no collection.anki21b / anki21 / anki2 in package',
      );
    }
    if (_isZstd(collection)) {
      collection = unzstd(collection, 'collection');
    }

    final ArchiveFile? m = find('media');
    final Map<String, String> media = m == null
        ? <String, String>{}
        : _parseMediaManifest(_bytesOf(m), unzstd);
    final ArchiveFile? x = find(srsFushiExtEntry);
    final Map<String, Object?>? ext = x == null
        ? null
        : _parseFushiExt(_bytesOf(x), unzstd);
    ArchiveFile? entryFile(String entry) => archive.findFile(entry);
    return SrsAnkiPackage._(
      (String entry) async {
        final ArchiveFile? f = entryFile(entry);
        return f == null ? null : _bytesOf(f);
      },
      zstd,
      collection,
      latest,
      media,
      ext,
    );
  }

  /// 媒体清单（旧格式 JSON `{"0": "a.mp3"}` / 新格式 protobuf MediaEntries）→ 媒体名 → 条目名。
  static Map<String, String> _parseMediaManifest(
    Uint8List raw,
    Uint8List Function(Uint8List data, String what) unzstd,
  ) {
    final Map<String, String> media = <String, String>{};
    if (_isZstd(raw)) raw = unzstd(raw, 'media manifest');
    final String text = utf8.decode(raw, allowMalformed: true).trimLeft();
    if (text.startsWith('{')) {
      final Object? j = jsonDecode(text);
      if (j is Map) {
        for (final MapEntry<Object?, Object?> e in j.entries) {
          if (e.value is String) media[e.value! as String] = '${e.key}';
        }
      }
    } else if (raw.isNotEmpty) {
      // MediaEntries { repeated MediaEntry entries = 1; }
      // MediaEntry { name = 1; size = 2; sha1 = 3; legacy_zip_filename = 255 }
      final List<SrsProtoMessage> entries = SrsProtoMessage.parse(
        raw,
      ).messagesOf(1);
      for (int i = 0; i < entries.length; i++) {
        final SrsProtoMessage e = entries[i];
        final int idx = e.optInt(255) ?? i;
        media[e.stringOf(1)] = '$idx';
      }
    }
    return media;
  }

  static Map<String, Object?>? _parseFushiExt(
    Uint8List raw,
    Uint8List Function(Uint8List data, String what) unzstd,
  ) {
    if (_isZstd(raw)) raw = unzstd(raw, srsFushiExtEntry);
    final Object? j = jsonDecode(utf8.decode(raw));
    return j is Map ? j.cast<String, Object?>() : null;
  }

  static Uint8List Function(Uint8List data, String what) _unzstdOrThrow(
    SrsZstdDecoder zstd,
  ) => (Uint8List data, String what) {
    final Uint8List? out = _tryZstd(zstd, data);
    if (out == null) {
      throw SrsImportException(
        SrsImportException.needsKernel,
        '$what is zstd-compressed (new .apkg format) and the scheduling '
        'kernel library is unavailable',
      );
    }
    return out;
  };

  /// 从文件解包，**不把整个包读进内存**（Android 上带媒体的 .colpkg 动辄上 GB，整包读入
  /// 会 Out of Memory）。同步、纯 CPU / IO：调用方放进后台 isolate。
  ///
  /// - zip 只读中央目录（[srsReadZipIndex]），条目数据按偏移从文件取；
  /// - 集合条目流式解压到 [workDir]（[srsExtractZipEntrySync]）；新格式（collection.anki21b）
  ///   再经 [zstdFile] 文件到文件解 zstd（排程内核 `ffsrs_zstd_decompress_file`，一次 FFI
  ///   调用流式解完；以前整段读进内存解码再写回，峰值是压缩后 + 解压后的集合大小）；
  /// - 媒体清单 / fushi-ext 很小，一次读出；
  /// - 媒体文件不在这里读：[mediaBytes] 按需从文件里逐个取，峰值 ≈ 单个媒体文件。
  ///
  /// [workDir] 由调用方建、调用方删（集合用完后 [SrsAnkiCollection.openExtracted] 关闭时删）。
  static SrsAnkiPackage openFile(
    String path, {
    required SrsZstdDecoder zstd,
    required SrsZstdFileDecoder zstdFile,
    required String workDir,
  }) {
    final Map<String, SrsZipEntry> index;
    try {
      index = srsReadZipIndex(path);
    } on Object catch (e) {
      throw SrsImportException(SrsImportException.corrupt, 'not a zip: $e');
    }
    final Uint8List Function(Uint8List data, String what) unzstd =
        _unzstdOrThrow(zstd);
    final SrsZipEntry? c21b = index['collection.anki21b'];
    final SrsZipEntry? colEntry =
        c21b ?? index['collection.anki21'] ?? index['collection.anki2'];
    if (colEntry == null) {
      throw const SrsImportException(
        SrsImportException.noCollection,
        'no collection.anki21b / anki21 / anki2 in package',
      );
    }
    final File collection = File(
      '$workDir${Platform.pathSeparator}collection.db',
    );
    final Map<String, String> media;
    final Map<String, Object?>? ext;
    final RandomAccessFile raf = File(path).openSync();
    try {
      final File raw = File('$workDir${Platform.pathSeparator}collection.raw');
      srsExtractZipEntrySync(raf, colEntry, raw);
      if (_fileStartsWithZstd(raw)) {
        final String what = c21b != null ? 'collection.anki21b' : 'collection';
        final bool? ok = _tryZstdFile(zstdFile, raw.path, collection.path);
        if (ok == null) {
          throw SrsImportException(
            SrsImportException.needsKernel,
            '$what is zstd-compressed (new .apkg format) and the scheduling '
            'kernel library is unavailable',
          );
        }
        if (!ok) {
          throw SrsImportException(
            SrsImportException.corrupt,
            '$what: invalid zstd data',
          );
        }
        raw.deleteSync();
      } else {
        raw.renameSync(collection.path);
      }
      final SrsZipEntry? m = index['media'];
      media = m == null
          ? <String, String>{}
          : _parseMediaManifest(srsReadZipEntrySync(raf, m), unzstd);
      final SrsZipEntry? x = index[srsFushiExtEntry];
      ext = x == null
          ? null
          : _parseFushiExt(srsReadZipEntrySync(raf, x), unzstd);
    } on SrsImportException {
      rethrow;
    } on SrsZipFormatException catch (e) {
      throw SrsImportException(SrsImportException.corrupt, e.message);
    } on FileSystemException {
      rethrow;
    } on Object catch (e) {
      throw SrsImportException(SrsImportException.corrupt, '$e');
    } finally {
      raf.closeSync();
    }
    return SrsAnkiPackage._(
      (String entry) async {
        final SrsZipEntry? e = index[entry];
        if (e == null) return null;
        try {
          return await srsReadZipEntry(path, e);
        } on SrsZipFormatException catch (err) {
          throw SrsImportException(SrsImportException.corrupt, err.message);
        }
      },
      zstd,
      Uint8List(0),
      c21b != null,
      media,
      ext,
      collectionFile: collection,
    );
  }

  static bool? _tryZstdFile(
    SrsZstdFileDecoder zstd,
    String inPath,
    String outPath,
  ) {
    try {
      return zstd(inPath, outPath);
    } on Object {
      return false;
    }
  }

  static bool _fileStartsWithZstd(File f) {
    final RandomAccessFile r = f.openSync();
    try {
      return _isZstd(r.readSync(4));
    } finally {
      r.closeSync();
    }
  }

  static Uint8List? _tryZstd(SrsZstdDecoder zstd, Uint8List data) {
    try {
      return zstd(data);
    } on Object {
      return null;
    }
  }

  /// 包里的媒体文件（zstd 压缩的自动解压；没有返回 null）。
  Future<Uint8List?> mediaBytes(String name) async {
    final String? entry = mediaIndex[name];
    if (entry == null) return null;
    final Uint8List? raw = await _loadEntry(entry);
    if (raw == null) return null;
    if (!_isZstd(raw)) return raw;
    final Uint8List? out = _tryZstd(_zstd, raw);
    if (out == null) {
      throw SrsImportException(
        SrsImportException.needsKernel,
        'media "$name" is zstd-compressed and the scheduling kernel library '
        'is unavailable',
      );
    }
    return out;
  }
}

// ---------------------------------------------------------------------- 模型

class SrsAnkiField {
  const SrsAnkiField({
    required this.name,
    required this.ord,
    this.configId,
    this.description = '',
  });

  final String name;
  final int ord;

  /// Field.Config.id（Anki 23.10+）。
  final int? configId;

  /// Field.Config.description（Anki 2.1.50+ 编辑器里字段下方的说明）。
  final String description;
}

class SrsAnkiTemplate {
  const SrsAnkiTemplate({
    required this.name,
    required this.ord,
    required this.qfmt,
    required this.afmt,
    this.configId,
  });

  final String name;
  final int ord;
  final String qfmt;
  final String afmt;

  /// Template.Config.id（Anki 23.10+）。
  final int? configId;
}

class SrsAnkiNoteType {
  const SrsAnkiNoteType({
    required this.id,
    required this.name,
    required this.isCloze,
    required this.css,
    required this.fields,
    required this.templates,
    this.originalId,
    this.mtimeSecs = 0,
  });

  final int id;
  final String name;
  final bool isCloze;
  final String css;

  /// 按 ord 排好。
  final List<SrsAnkiField> fields;

  /// 按 ord 排好。
  final List<SrsAnkiTemplate> templates;

  /// NotetypeConfig.original_id（导入别人的笔记类型后 Anki 记下的来源 id）。
  final int? originalId;

  /// 来源最后修改时刻（秒；旧 schema 的 `mod` / 新 schema 的 `mtime_secs`）。
  /// 导入选项「更新笔记类型：较新时」按它比。
  final int mtimeSecs;

  /// 身份用的 ankiNum：config.original_id，没有就取来源笔记类型 id。
  int get ankiNum => originalId ?? id;
}

class SrsAnkiDeck {
  const SrsAnkiDeck({
    required this.id,
    required this.name,
    required this.filtered,
    required this.configId,
    this.collapsed = false,
  });

  final int id;

  /// 「父::子」全名。
  final String name;
  final bool filtered;
  final int configId;

  /// 牌组列表里收起了子牌组：旧格式 decks JSON 的 `collapsed`；
  /// 新格式 Deck.Common.study_collapsed（decks 表 common 列，字段 1）。
  final bool collapsed;
}

class SrsAnkiPreset {
  const SrsAnkiPreset({
    required this.id,
    required this.name,
    required this.learnSteps,
    required this.relearnSteps,
    required this.newPerDay,
    required this.reviewsPerDay,
    required this.maxIntervalDays,
    required this.desiredRetention,
    required this.fsrs6Params,
    required this.fsrs7Params,
    required this.fsrsVersion,
    required this.rwkvEnabled,
    this.autoplay = true,
    this.replayQuestion = true,
  });

  final int id;
  final String name;
  final List<double> learnSteps;
  final List<double> relearnSteps;
  final int newPerDay;
  final int reviewsPerDay;
  final int maxIntervalDays;
  final double desiredRetention;
  final List<double> fsrs6Params;

  /// JSchoreels fork（FSRS-7）的 fsrs_params_7。
  final List<double> fsrs7Params;

  /// fork 的 fsrs_version（0 = 七，1 = 六…）；主线没有。
  final int? fsrsVersion;

  /// fork 的 rwkv_review_enabled。
  final bool rwkvEnabled;

  /// 自动播放音频（旧 JSON `autoplay`；新 schema `disable_autoplay` = 23 取反）。
  final bool autoplay;

  /// 答案面重播时包含问题音频（旧 JSON `replayq`；新 schema
  /// `skip_question_when_replaying_answer` = 26 取反）。
  final bool replayQuestion;
}

/// 来源集合的元信息（笔记 / 卡片 / revlog 由导入流程按需流式读）。
class SrsAnkiCollection {
  SrsAnkiCollection._(this.db, this.file, {this.deleteDirOnClose = true});

  final Database db;
  final File file;

  /// [close] 时删掉 [file] 所在的临时目录（[open] 自己建的目录）。
  final bool deleteDirOnClose;

  late final int crtSecs;
  late final int utcOffsetMin;
  late final int rolloverHour;
  late final bool fsrsEnabled;
  late final bool newSchema;
  final Map<int, SrsAnkiNoteType> noteTypes = <int, SrsAnkiNoteType>{};
  final Map<int, SrsAnkiDeck> decks = <int, SrsAnkiDeck>{};
  final Map<int, SrsAnkiPreset> presets = <int, SrsAnkiPreset>{};

  /// 把 SQLite 字节写进临时文件并打开（只读）。用完必须 [close]。
  static Future<SrsAnkiCollection> open(Uint8List sqliteBytes) async {
    final Directory dir = await Directory.systemTemp.createTemp('fushi_apkg_');
    final File f = File('${dir.path}${Platform.pathSeparator}collection.db');
    await f.writeAsBytes(sqliteBytes, flush: true);
    final Database db;
    try {
      // 新 schema 的 fields / notetypes / decks… 用 COLLATE unicase（BUG-3428）。
      db = openAnkiCollectionDb(f.path);
    } on Object catch (e) {
      await dir.delete(recursive: true);
      throw SrsImportException(SrsImportException.corrupt, 'sqlite: $e');
    }
    return _loaded(SrsAnkiCollection._(db, f));
  }

  /// 打开 [SrsAnkiPackage.openFile] 解到工作目录里的集合：[close] 时连同工作目录一起删
  /// （打开失败也删）。
  static Future<SrsAnkiCollection> openExtracted(File sqlite) async {
    final Database db;
    try {
      db = openAnkiCollectionDb(sqlite.path);
    } on Object catch (e) {
      try {
        await sqlite.parent.delete(recursive: true);
      } on FileSystemException {
        // 临时目录留给系统清理。
      }
      throw SrsImportException(SrsImportException.corrupt, 'sqlite: $e');
    }
    return _loaded(SrsAnkiCollection._(db, sqlite));
  }

  /// 直接只读打开一份**调用方拥有的** SQLite 文件（本机集合的快照）。
  /// [close] 不删文件，快照目录由调用方清理。
  static Future<SrsAnkiCollection> openFile(File sqlite) async {
    final Database db;
    try {
      db = openAnkiCollectionDb(sqlite.path);
    } on Object catch (e) {
      throw SrsImportException(SrsImportException.corrupt, 'sqlite: $e');
    }
    return _loaded(SrsAnkiCollection._(db, sqlite, deleteDirOnClose: false));
  }

  static Future<SrsAnkiCollection> _loaded(SrsAnkiCollection c) async {
    try {
      c._load();
    } on SrsImportException {
      await c.close();
      rethrow;
    } on Object catch (e) {
      await c.close();
      throw SrsImportException(SrsImportException.corrupt, '$e');
    }
    return c;
  }

  Future<void> close() async {
    db.close();
    if (!deleteDirOnClose) return;
    try {
      await file.parent.delete(recursive: true);
    } on FileSystemException {
      // Windows 上句柄偶尔晚释放：临时目录留给系统清理。
    }
  }

  bool _hasTable(String name) => db.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[name],
  ).isNotEmpty;

  void _load() {
    final ResultSet col = db.select(
      'SELECT crt, conf, models, decks, dconf FROM col',
    );
    if (col.isEmpty) {
      throw const SrsImportException(SrsImportException.corrupt, 'empty col');
    }
    final Row r = col.first;
    crtSecs = (r['crt'] as int?) ?? 0;
    newSchema = _hasTable('notetypes');
    final Map<String, Object?> conf = newSchema
        ? _configTable()
        : _jsonMap(r['conf']);
    fsrsEnabled = conf['fsrs'] == true;
    final Object? rollover = conf['rollover'];
    rolloverHour = rollover is int && rollover >= 0 && rollover <= 23
        ? rollover
        : 4;
    // Anki 的 localOffset / creationOffset 是「UTC 以西的分钟数」。
    final Object? off = conf['localOffset'] ?? conf['creationOffset'];
    utcOffsetMin = off is int ? -off : 0;
    if (newSchema) {
      _loadNoteTypesProto();
      _loadDecksProto();
      _loadPresetsProto();
    } else {
      _loadNoteTypesJson(_jsonMap(r['models']));
      _loadDecksJson(_jsonMap(r['decks']));
      _loadPresetsJson(_jsonMap(r['dconf']));
    }
  }

  static Map<String, Object?> _jsonMap(Object? v) {
    if (v is! String || v.trim().isEmpty) return <String, Object?>{};
    final Object? j = jsonDecode(v);
    return j is Map ? j.cast<String, Object?>() : <String, Object?>{};
  }

  Map<String, Object?> _configTable() {
    final Map<String, Object?> out = <String, Object?>{};
    if (!_hasTable('config')) return out;
    for (final Row row in db.select('SELECT key AS k, val AS v FROM config')) {
      final Object? val = row['v'];
      final String text = val is Uint8List
          ? utf8.decode(val, allowMalformed: true)
          : '$val';
      try {
        out[row['k'] as String] = jsonDecode(text);
      } on FormatException {
        // 不是 JSON 的配置项与导入无关。
      }
    }
    return out;
  }

  // ---- 旧 schema（JSON）

  static int? _int(Object? v) => switch (v) {
    final int i => i,
    final String s => int.tryParse(s),
    final double d => d.toInt(),
    _ => null,
  };

  static List<double> _doubles(Object? v) => v is List
      ? <double>[
          for (final Object? x in v)
            if (x is num) x.toDouble(),
        ]
      : const <double>[];

  void _loadNoteTypesJson(Map<String, Object?> models) {
    for (final Object? m in models.values) {
      if (m is! Map) continue;
      final int? id = _int(m['id']);
      if (id == null) continue;
      final List<SrsAnkiField> fields = <SrsAnkiField>[
        for (final (int i, Object? f)
            in ((m['flds'] as List?) ?? const <Object?>[]).indexed)
          if (f is Map)
            SrsAnkiField(
              name: '${f['name'] ?? ''}',
              ord: _int(f['ord']) ?? i,
              configId: _int(f['id']),
              description: f['description'] is String
                  ? f['description'] as String
                  : '',
            ),
      ]..sort((SrsAnkiField a, SrsAnkiField b) => a.ord.compareTo(b.ord));
      final List<SrsAnkiTemplate> tmpls = <SrsAnkiTemplate>[
        for (final (int i, Object? t)
            in ((m['tmpls'] as List?) ?? const <Object?>[]).indexed)
          if (t is Map)
            SrsAnkiTemplate(
              name: '${t['name'] ?? ''}',
              ord: _int(t['ord']) ?? i,
              qfmt: '${t['qfmt'] ?? ''}',
              afmt: '${t['afmt'] ?? ''}',
              configId: _int(t['id']),
            ),
      ]..sort((SrsAnkiTemplate a, SrsAnkiTemplate b) => a.ord.compareTo(b.ord));
      noteTypes[id] = SrsAnkiNoteType(
        id: id,
        name: '${m['name'] ?? ''}',
        isCloze: _int(m['type']) == 1,
        css: '${m['css'] ?? ''}',
        fields: fields,
        templates: tmpls,
        originalId: _int(m['originalId']),
        mtimeSecs: _int(m['mod']) ?? 0,
      );
    }
  }

  void _loadDecksJson(Map<String, Object?> decksJson) {
    for (final Object? d in decksJson.values) {
      if (d is! Map) continue;
      final int? id = _int(d['id']);
      if (id == null) continue;
      decks[id] = SrsAnkiDeck(
        id: id,
        name: '${d['name'] ?? ''}',
        filtered: _int(d['dyn']) == 1 || d['dyn'] == true,
        configId: _int(d['conf']) ?? 1,
        collapsed: d['collapsed'] == true || _int(d['collapsed']) == 1,
      );
    }
  }

  void _loadPresetsJson(Map<String, Object?> dconf) {
    for (final Object? c in dconf.values) {
      if (c is! Map) continue;
      final int? id = _int(c['id']);
      if (id == null) continue;
      final Map<Object?, Object?> nw =
          (c['new'] as Map?) ?? const <Object?, Object?>{};
      final Map<Object?, Object?> rev =
          (c['rev'] as Map?) ?? const <Object?, Object?>{};
      final Map<Object?, Object?> lapse =
          (c['lapse'] as Map?) ?? const <Object?, Object?>{};
      presets[id] = SrsAnkiPreset(
        id: id,
        name: '${c['name'] ?? ''}',
        learnSteps: _doubles(nw['delays']),
        relearnSteps: _doubles(lapse['delays']),
        newPerDay: _int(nw['perDay']) ?? 20,
        reviewsPerDay: _int(rev['perDay']) ?? 200,
        maxIntervalDays: _int(rev['maxIvl']) ?? 36500,
        desiredRetention: (c['desiredRetention'] as num?)?.toDouble() ?? 0,
        fsrs6Params: _doubles(c['fsrsParams6']),
        fsrs7Params: _doubles(c['fsrsParams7']),
        fsrsVersion: _int(c['fsrsVersion']),
        rwkvEnabled: c['rwkvReviewEnabled'] == true,
        autoplay: c['autoplay'] != false,
        replayQuestion: c['replayq'] != false,
      );
    }
  }

  // ---- 新 schema（protobuf）

  static double _f32(double v) => double.parse(v.toStringAsPrecision(7));

  static Uint8List _blob(Object? v) => v is Uint8List ? v : Uint8List(0);

  void _loadNoteTypesProto() {
    final Map<int, List<SrsAnkiField>> fields = <int, List<SrsAnkiField>>{};
    for (final Row row in db.select(
      'SELECT ntid, ord, name, config FROM fields',
    )) {
      // Field.Config.id = 9（optional int64）；description = 5（string）。
      final SrsProtoMessage cfg = SrsProtoMessage.parse(_blob(row['config']));
      (fields[row['ntid'] as int] ??= <SrsAnkiField>[]).add(
        SrsAnkiField(
          name: row['name'] as String,
          ord: row['ord'] as int,
          configId: cfg.optInt(9),
          description: cfg.stringOf(5),
        ),
      );
    }
    final Map<int, List<SrsAnkiTemplate>> tmpls =
        <int, List<SrsAnkiTemplate>>{};
    for (final Row row in db.select(
      'SELECT ntid, ord, name, config FROM templates',
    )) {
      // Template.Config: q_format = 1, a_format = 2, id = 8（optional int64）。
      final SrsProtoMessage cfg = SrsProtoMessage.parse(_blob(row['config']));
      (tmpls[row['ntid'] as int] ??= <SrsAnkiTemplate>[]).add(
        SrsAnkiTemplate(
          name: row['name'] as String,
          ord: row['ord'] as int,
          qfmt: cfg.stringOf(1),
          afmt: cfg.stringOf(2),
          configId: cfg.optInt(8),
        ),
      );
    }
    for (final Row row in db.select(
      'SELECT id, name, mtime_secs, config FROM notetypes',
    )) {
      // NotetypeConfig: kind = 1（1 = cloze）、css = 3、original_id = 10（optional int64）。
      final SrsProtoMessage cfg = SrsProtoMessage.parse(_blob(row['config']));
      final int id = row['id'] as int;
      noteTypes[id] = SrsAnkiNoteType(
        id: id,
        name: row['name'] as String,
        isCloze: cfg.intOf(1) == 1,
        css: cfg.stringOf(3),
        fields: (fields[id] ?? <SrsAnkiField>[])
          ..sort((SrsAnkiField a, SrsAnkiField b) => a.ord.compareTo(b.ord)),
        templates: (tmpls[id] ?? <SrsAnkiTemplate>[])
          ..sort(
            (SrsAnkiTemplate a, SrsAnkiTemplate b) => a.ord.compareTo(b.ord),
          ),
        originalId: cfg.optInt(10),
        mtimeSecs: (row['mtime_secs'] as int?) ?? 0,
      );
    }
  }

  void _loadDecksProto() {
    for (final Row row in db.select(
      'SELECT id, name, common, kind FROM decks',
    )) {
      // Deck.KindContainer: normal = 1（Normal.config_id = 1）、filtered = 2。
      final SrsProtoMessage kind = SrsProtoMessage.parse(_blob(row['kind']));
      // Deck.Common: study_collapsed = 1、browser_collapsed = 2。
      final SrsProtoMessage common = SrsProtoMessage.parse(
        _blob(row['common']),
      );
      final bool filtered = kind.has(2);
      final int id = row['id'] as int;
      // proto3：config_id 缺失 = 0（BUG-3455，解码层不填非零默认）。0 不是任何
      // 预设的 id；Anki 取不到牌组的预设时用默认预设 1，这里照它在语义层换算。
      final int configId = filtered ? 0 : kind.messageOf(1).intOf(1);
      decks[id] = SrsAnkiDeck(
        id: id,
        name: (row['name'] as String).replaceAll('\x1f', '::'),
        filtered: filtered,
        configId: filtered || configId != 0 ? configId : 1,
        collapsed: common.boolOf(1),
      );
    }
  }

  void _loadPresetsProto() {
    for (final Row row in db.select(
      'SELECT id, name, config FROM deck_config',
    )) {
      // DeckConfig.Config: learn_steps = 1, relearn_steps = 2, fsrs_params_6 = 6,
      // new_per_day = 9, reviews_per_day = 10, maximum_review_interval = 16,
      // desired_retention = 37；JSchoreels fork: fsrs_params_7 = 52,
      // fsrs_version = 53, rwkv_review_enabled = 67；disable_autoplay = 23、
      // skip_question_when_replaying_answer = 26（对照 ankitects/anki
      // proto/anki/deck_config.proto 核实）。
      //
      // BUG-3455：除 fork 的 optional fsrs_version 外都是 proto3 标量，proto3 不写
      // 零值——字段缺失就是 0 / false / 空，不是「没设置」。一律按零值解码：每日
      // 新卡上限设成 0 的预设绝不能读成 20。非零默认只属于旧格式 JSON 缺键
      // （_loadPresetsJson）。最大间隔 0 是无效值，导入时不写、走本机默认。
      final SrsProtoMessage c = SrsProtoMessage.parse(_blob(row['config']));
      final int id = row['id'] as int;
      presets[id] = SrsAnkiPreset(
        id: id,
        name: row['name'] as String,
        learnSteps: c.floatsOf(1).map(_f32).toList(),
        relearnSteps: c.floatsOf(2).map(_f32).toList(),
        newPerDay: c.intOf(9),
        reviewsPerDay: c.intOf(10),
        maxIntervalDays: c.intOf(16),
        desiredRetention: _f32(c.floatOf(37)),
        fsrs6Params: c.floatsOf(6).map(_f32).toList(),
        fsrs7Params: c.floatsOf(52).map(_f32).toList(),
        fsrsVersion: c.optInt(53),
        rwkvEnabled: c.boolOf(67),
        autoplay: !c.boolOf(23),
        replayQuestion: !c.boolOf(26),
      );
    }
  }
}

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

const List<int> _zstdMagic = <int>[0x28, 0xB5, 0x2F, 0xFD];

bool _isZstd(Uint8List b) =>
    b.length >= 4 &&
    b[0] == _zstdMagic[0] &&
    b[1] == _zstdMagic[1] &&
    b[2] == _zstdMagic[2] &&
    b[3] == _zstdMagic[3];

/// fushi-ext 条目名（Fushi 导出时附带的完整日志与设置）。
const String srsFushiExtEntry = 'fushi-ext';

/// 解开的包。
class SrsAnkiPackage {
  SrsAnkiPackage._(
    this._archive,
    this._zstd,
    this.collectionBytes,
    this.latestFormat,
    this.mediaIndex,
    this.fushiExt,
  );

  final Archive _archive;
  final SrsZstdDecoder _zstd;

  /// 解压后的 SQLite 字节。
  final Uint8List collectionBytes;

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

    final Map<String, String> media = <String, String>{};
    final ArchiveFile? m = find('media');
    if (m != null) {
      Uint8List raw = _bytesOf(m);
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
    }

    Map<String, Object?>? ext;
    final ArchiveFile? x = find(srsFushiExtEntry);
    if (x != null) {
      Uint8List raw = _bytesOf(x);
      if (_isZstd(raw)) raw = unzstd(raw, srsFushiExtEntry);
      final Object? j = jsonDecode(utf8.decode(raw));
      if (j is Map) ext = j.cast<String, Object?>();
    }
    return SrsAnkiPackage._(archive, zstd, collection, latest, media, ext);
  }

  static Uint8List? _tryZstd(SrsZstdDecoder zstd, Uint8List data) {
    try {
      return zstd(data);
    } on Object {
      return null;
    }
  }

  /// 包里的媒体文件（zstd 压缩的自动解压；没有返回 null）。
  Uint8List? mediaBytes(String name) {
    final String? entry = mediaIndex[name];
    if (entry == null) return null;
    final ArchiveFile? f = _archive.findFile(entry);
    if (f == null) return null;
    final Uint8List raw = _bytesOf(f);
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
  const SrsAnkiField({required this.name, required this.ord, this.configId});

  final String name;
  final int ord;

  /// Field.Config.id（Anki 23.10+）。
  final int? configId;
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
  SrsAnkiCollection._(this.db, this.file);

  final Database db;
  final File file;

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
    final SrsAnkiCollection c = SrsAnkiCollection._(db, f);
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
      // Field.Config.id = 9（optional int64）。
      final SrsProtoMessage cfg = SrsProtoMessage.parse(_blob(row['config']));
      (fields[row['ntid'] as int] ??= <SrsAnkiField>[]).add(
        SrsAnkiField(
          name: row['name'] as String,
          ord: row['ord'] as int,
          configId: cfg.optInt(9),
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

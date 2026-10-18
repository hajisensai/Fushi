/// Anki .apkg / .colpkg 导入（PR3b，铁律 C）。
///
/// 新旧两种格式解出 SQLite 之后走同一条路径（见 srs_anki_package.dart）。导入事件的身份与内容只由来源决定：
/// 笔记类型 / 字段 / 模板 / 笔记 / 卡片的 ID 按 SrsIds 规则派生，revlog 日志与导入锚点按
/// anki_import_rules.dart 的规则写；多台设备各自导入同一个包，同步后不出重复。
///
/// 包里有 `fushi-ext`（Fushi 自己导出的包）时按它恢复 Fushi 日志与牌组设置，revlog 只作校验；
/// Anki 端在导出之后新增的 revlog 照常按来源规则导入。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:fushi_engine/srs/apkg/srs_anki_package.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_common.dart';
import 'package:fushi_engine/srs/apkg/srs_import_options.dart';
import 'package:fushi_engine/srs/apkg/srs_import_report.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

export 'package:fushi_engine/srs/apkg/srs_anki_package.dart'
    show SrsImportException, SrsZstdDecoder;
export 'package:fushi_engine/srs/apkg/srs_import_options.dart';
export 'package:fushi_engine/srs/apkg/srs_import_report.dart';

/// 媒体落盘回调：返回存储后的文件名（例如按内容哈希改名），字段里的引用按它改写。
typedef SrsImportMediaSink =
    Future<String> Function(String name, Uint8List bytes);

/// 导入一个 .apkg / .colpkg（新旧格式都支持）。
///
/// - [options]：对齐 Anki 导入页的五个选项（合并笔记类型 / 更新笔记 / 更新笔记类型 /
///   包含排程 / 包含牌组预设），默认值与 Anki 相同，见 [SrsAnkiImportOptions]。
///   .colpkg（整库包）也走这条合并路径：Anki 会用它替换整个集合，Fushi 不替换、不删本机任何数据。
/// - [zstdDecompress]：新格式需要的 zstd 解码，缺省用排程内核（FfiFsrsEngine.zstdDecompress）；
///   内核不可用时新格式抛 [SrsImportException]（code = needsKernel）。
Future<SrsImportReport> importAnkiPackage({
  required SrsDbStore store,
  required Uint8List bytes,
  required SrsImportMediaSink storeMedia,
  SrsAnkiImportOptions options = const SrsAnkiImportOptions(),
  void Function(double progress)? onProgress,
  SrsZstdDecoder? zstdDecompress,
}) async {
  final SrsAnkiPackage pkg = SrsAnkiPackage.open(
    bytes,
    zstd: zstdDecompress ?? FfiFsrsEngine.zstdDecompress,
  );
  final SrsAnkiCollection col = await SrsAnkiCollection.open(
    pkg.collectionBytes,
  );
  try {
    final _Importer imp = _Importer(
      store: store,
      pkg: pkg,
      col: col,
      storeMedia: storeMedia,
      options: options,
      onProgress: onProgress,
    );
    return await imp.run();
  } finally {
    await col.close();
  }
}

/// 同 [importAnkiPackage]，从文件读。
Future<SrsImportReport> importAnkiPackageFile({
  required SrsDbStore store,
  required File file,
  required SrsImportMediaSink storeMedia,
  SrsAnkiImportOptions options = const SrsAnkiImportOptions(),
  void Function(double progress)? onProgress,
  SrsZstdDecoder? zstdDecompress,
}) async => importAnkiPackage(
  store: store,
  bytes: await file.readAsBytes(),
  storeMedia: storeMedia,
  options: options,
  onProgress: onProgress,
  zstdDecompress: zstdDecompress,
);

/// 一个来源笔记类型映射到本机的结果。
class _NtMap {
  _NtMap({
    required this.id,
    required this.name,
    required this.isCloze,
    required this.fieldIds,
    required this.templateIdByOrd,
    this.conflict,
  });

  final String id;
  final String name;
  final bool isCloze;

  /// 按来源字段顺序（= notes.flds 的顺序）。
  final List<String> fieldIds;
  final Map<int, String> templateIdByOrd;

  /// 非 null = 不导入这个笔记类型的笔记（原因代码）。
  final String? conflict;
}

class _SrcCard {
  _SrcCard(Row r)
    : id = r['id'] as int,
      did = r['did'] as int,
      odid = r['odid'] as int,
      ord = r['ord'] as int,
      type = r['type'] as int,
      queue = r['queue'] as int,
      due = r['due'] as int,
      odue = r['odue'] as int,
      ivl = r['ivl'] as int,
      factor = r['factor'] as int,
      reps = r['reps'] as int,
      lapses = r['lapses'] as int,
      data = (r['data'] as String?) ?? '';

  final int id;
  final int did;
  final int odid;
  final int ord;
  final int type;
  final int queue;
  final int due;
  final int odue;
  final int ivl;
  final int factor;
  final int reps;
  final int lapses;
  final String data;

  /// 在筛选牌组里的卡按原牌组算。
  int get homeDeck => odid != 0 ? odid : did;
}

class _SrcRevlog {
  _SrcRevlog(Row r)
    : id = r['id'] as int,
      ease = r['ease'] as int,
      ivl = r['ivl'] as int,
      factor = r['factor'] as int,
      time = r['time'] as int,
      type = r['type'] as int;

  final int id;
  final int ease;
  final int ivl;
  final int factor;
  final int time;
  final int type;

  SrsAnkiRevlogRow get row => SrsAnkiRevlogRow(
    id: id,
    ease: ease,
    type: type,
    ivl: ivl,
    factor: factor,
  );

  /// 评分类：type 0/1/2 且 ease 1–4。
  bool get isRating => type <= 2 && type >= 0 && ease >= 1 && ease <= 4;

  bool get isFiltered => type == 3;
}

class _Importer {
  _Importer({
    required this.store,
    required this.pkg,
    required this.col,
    required this.storeMedia,
    required this.options,
    required this.onProgress,
  }) : srcDay = SrsDayContext(
         utcOffsetMin: col.utcOffsetMin,
         rolloverHour: col.rolloverHour,
       );

  final SrsDbStore store;
  final SrsAnkiPackage pkg;
  final SrsAnkiCollection col;
  final SrsImportMediaSink storeMedia;
  final SrsAnkiImportOptions options;
  final void Function(double progress)? onProgress;

  /// 来源集合的「今天」口径（日志里的 utcOffset / 翻日也取它，保证多台设备导出同一份内容）。
  final SrsDayContext srcDay;
  late final int crtDay;
  final SrsImportReport report = SrsImportReport();

  final Map<int, _NtMap> _nts = <int, _NtMap>{};
  final Map<int, String> _deckOf = <int, String>{};
  final Map<String, String> _mediaRenames = <String, String>{};
  final Set<String> _mediaDone = <String>{};
  final List<SrsEvent> _pending = <SrsEvent>[];

  // fushi-ext
  bool _extSameProfile = false;
  final Map<int, List<SrsReviewLog>> _extLogsByCard =
      <int, List<SrsReviewLog>>{};
  final Map<String, int> _extRevlogIds = <String, int>{};

  /// fushi-ext 的 logCards：前身卡日志（更改笔记类型继承来的）→ 它在包里归的 Anki 卡 id。
  final Map<String, int> _extLogCards = <String, int>{};

  /// 同 profile 回导时补的「前身」链接（日志原样保留在前身卡上）。
  final List<SrsEditSpec> _historyLinks = <SrsEditSpec>[];
  final Map<String, Map<String, Object?>> _extDecks =
      <String, Map<String, Object?>>{};
  final Map<String, Object?> _extNotes = <String, Object?>{};

  String get profileUid => store.profileUid;

  /// Anki 的排程系统标签（gather.rs `remove_system_tags`）。
  static const Set<String> _schedulingTags = <String>{'marked', 'leech'};

  Future<SrsImportReport> run() async {
    report.latestFormat = pkg.latestFormat;
    report.options = options;
    // Anki review 卡的 due 是「相对 crt 的天数」：crt（秒）在来源时区 / 翻日下的日历日。
    final DateTime crtDate = DateTime.fromMillisecondsSinceEpoch(
      col.crtSecs * 1000 +
          col.utcOffsetMin * 60000 -
          col.rolloverHour * 3600000,
      isUtc: true,
    );
    crtDay = srsDateToDay(crtDate.year, crtDate.month, crtDate.day);
    _readExt();

    for (final String name in pkg.mediaIndex.keys) {
      if (name.startsWith('_')) await _media(name);
    }
    for (final SrsAnkiNoteType nt in col.noteTypes.values) {
      _nts[nt.id] = await _mapNoteType(nt);
    }
    await _mapDecks();
    await _importNotes();
    if (!options.withScheduling) {
      report.reviewLogsSkipped =
          col.db.select('SELECT count(*) AS n FROM revlog').first['n'] as int;
    }
    await _flush(force: true);
    if (_historyLinks.isNotEmpty) await store.writeEdits(_historyLinks);
    onProgress?.call(1);
    return report;
  }

  // ------------------------------------------------------------------ fushi-ext

  void _readExt() {
    final Map<String, Object?>? ext = pkg.fushiExt;
    if (ext == null || ext['format'] != srsFushiExtFormat) return;
    final Object? v = ext['version'];
    if (v is! int || v > srsFushiExtVersion) return;
    _extSameProfile = ext['profileUid'] == profileUid;
    final Object? logCards = ext['logCards'];
    if (logCards is Map) {
      for (final MapEntry<Object?, Object?> e in logCards.entries) {
        if (e.value is int) _extLogCards['${e.key}'] = e.value! as int;
      }
    }
    final Object? logs = ext['logs'];
    if (logs is List) {
      for (final Object? j in logs) {
        if (j is! Map) continue;
        final SrsReviewLog l = SrsReviewLog.fromJson(j.cast<String, Object?>());
        final int cid = _extLogCards[l.id] ?? SrsIds.ankiNumericId(l.cardId);
        (_extLogsByCard[cid] ??= <SrsReviewLog>[]).add(l);
      }
    }
    final Object? ids = ext['revlogIds'];
    if (ids is Map) {
      for (final MapEntry<Object?, Object?> e in ids.entries) {
        if (e.value is int) _extRevlogIds['${e.key}'] = e.value! as int;
      }
    }
    final Object? decks = ext['decks'];
    if (decks is List) {
      for (final Object? d in decks) {
        if (d is Map && d['name'] is String) {
          final Object? values = d['values'];
          _extDecks[d['name']! as String] = values is Map
              ? values.cast<String, Object?>()
              : <String, Object?>{};
        }
      }
    }
    final Object? notes = ext['notes'];
    if (notes is Map) _extNotes.addAll(notes.cast<String, Object?>());
  }

  // ------------------------------------------------------------------ 媒体

  Future<String> _media(String name) async {
    if (_mediaDone.contains(name)) return _mediaRenames[name] ?? name;
    _mediaDone.add(name);
    final Uint8List? bytes = pkg.mediaBytes(name);
    if (bytes == null) {
      report.mediaMissing.add(name);
      return name;
    }
    final String stored = await storeMedia(name, bytes);
    report.mediaStored++;
    if (stored != name) _mediaRenames[name] = stored;
    return stored;
  }

  Future<String> _withMedia(String html, {bool includeStatic = false}) async {
    html = _inlinePackagedStyles(html);
    final Set<String> refs = srsMediaRefsIn(html, includeStatic: includeStatic);
    if (refs.isEmpty) return html;
    for (final String r in refs) {
      await _media(r);
    }
    return srsRewriteMediaRefs(html, _mediaRenames);
  }

  /// 包里带着共享样式文件、字段里是它的引用行（没展开就导出的包）：按包内文件展开回内联
  /// `<style>`，落库时再统一去重成本机的共享样式文件。文件缺失或内容与文件名的哈希不符时原样保留。
  String _inlinePackagedStyles(String html) {
    if (srsStyleRefsIn(html).isEmpty) return html;
    return srsExpandStyles(html, (String name) {
      final Uint8List? bytes = pkg.mediaBytes(name);
      if (bytes == null) return null;
      try {
        final String css = utf8.decode(bytes);
        return srsStyleMediaName(css) == name ? css : null;
      } on FormatException {
        return null;
      }
    });
  }

  // ------------------------------------------------------------------ 笔记类型

  /// 本机最后一次改某实体「内容」的时刻（导入选项「较新时」的比较基准）：
  /// [relevant] 选出的键里所有在场修改记录的 HLC 物理时刻取最大，没有就取 [fallback]。
  static int _lastEditMs(
    SrsEntityEdits edits,
    bool Function(String key) relevant,
    int fallback,
  ) {
    int out = fallback;
    for (final SrsRegister r in edits.registers) {
      if (!relevant(r.key)) continue;
      for (final SrsFieldEdit e in r.live) {
        if (e.hlc.physical > out) out = e.hlc.physical;
      }
    }
    return out;
  }

  static bool _isNoteTypeContentKey(String key) =>
      key == SrsFieldKeys.name ||
      key == SrsFieldKeys.css ||
      key.startsWith('fieldDef/') ||
      key.startsWith('tmplDef/');

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _isNoteContentKey(String key) =>
      key.startsWith('f/') || key == SrsFieldKeys.noteTags;

  /// 字段 / 模板 → 本机 ID（铁律 C）。
  static String _resolveId(
    int? configId,
    String name,
    Iterable<(String, int?)> have,
    String Function(int) byNum,
    String Function(String) byName,
  ) {
    final Map<String, int?> h = <String, int?>{
      for (final (String id, int? n) in have) id: n,
    };
    if (configId != null) {
      // ankiNum 已记成某项的别名 → 那一项。
      for (final MapEntry<String, int?> e in h.entries) {
        if (e.value == configId) return e.key;
      }
      final String direct = byNum(configId);
      if (h.containsKey(direct)) return direct;
      // 先前按名字回退生成、还没有 ankiNum 的项：只把 ankiNum 记成它的别名，ID 不换。
      final String named = byName(name);
      if (h.containsKey(named) && h[named] == null) return named;
      return direct;
    }
    return byName(name);
  }

  /// 本机已有的全部定义（含已删除的、内置默认值）。
  static (Map<String, SrsFieldDef>, Map<String, SrsTemplateDef>) _haveDefs(
    SrsNoteTypeView? view,
  ) {
    final Map<String, SrsFieldDef> fields = <String, SrsFieldDef>{
      if (view != null)
        for (final SrsFieldDef f in view.fields) f.id: f,
    };
    final Map<String, SrsTemplateDef> tmpls = <String, SrsTemplateDef>{
      if (view != null)
        for (final SrsTemplateDef t in view.templates) t.id: t,
    };
    if (view == null) return (fields, tmpls);
    for (final String key in view.edits.keys) {
      if (key.startsWith('fieldDef/')) {
        final String id = key.substring('fieldDef/'.length);
        fields[id] = SrsFieldDef.fromValue(id, view.edits.value(key));
      } else if (key.startsWith('tmplDef/')) {
        final String id = key.substring('tmplDef/'.length);
        tmpls[id] = SrsTemplateDef.fromValue(id, view.edits.value(key));
      }
    }
    return (fields, tmpls);
  }

  static List<String> _resolveFields(
    String ntId,
    SrsAnkiNoteType src,
    Map<String, SrsFieldDef> have,
  ) => <String>[
    for (final SrsAnkiField f in src.fields)
      _resolveId(
        f.configId,
        f.name,
        have.values.map((SrsFieldDef d) => (d.id, d.ankiNum)),
        (int n) => SrsIds.field(ntId, n),
        (String n) => SrsIds.fieldByName(ntId, n),
      ),
  ];

  static Map<int, String> _resolveTemplates(
    String ntId,
    SrsAnkiNoteType src,
    Map<String, SrsTemplateDef> have,
  ) => <int, String>{
    for (final SrsAnkiTemplate t in src.templates)
      t.ord: _resolveId(
        t.configId,
        t.name,
        have.values.map((SrsTemplateDef d) => (d.id, d.ankiNum)),
        (int n) => SrsIds.template(ntId, n),
        (String n) => SrsIds.templateByName(ntId, n),
      ),
  };

  /// 来源与本机笔记类型的字段 / 模板是不是同一组（Anki `equal_schema` 的对应：
  /// 来源的每一项都解析到本机一个未删除的项，且本机没有多出来的未删除项）。
  static bool _equalSchema(SrsNoteTypeView view, SrsAnkiNoteType src) {
    final (
      Map<String, SrsFieldDef> haveFields,
      Map<String, SrsTemplateDef> haveTmpls,
    ) = _haveDefs(
      view,
    );
    final Set<String> liveFields = <String>{
      for (final SrsFieldDef f in haveFields.values)
        if (!f.deleted) f.id,
    };
    final Set<String> liveTmpls = <String>{
      for (final SrsTemplateDef t in haveTmpls.values)
        if (!t.deleted) t.id,
    };
    final List<String> fields = _resolveFields(view.id, src, haveFields);
    final Iterable<String> tmpls = _resolveTemplates(
      view.id,
      src,
      haveTmpls,
    ).values;
    return fields.length == liveFields.length &&
        fields.toSet().length == fields.length &&
        liveFields.containsAll(fields) &&
        tmpls.length == liveTmpls.length &&
        tmpls.toSet().length == tmpls.length &&
        liveTmpls.containsAll(tmpls);
  }

  /// 「不合并笔记类型」时另建的那一份的 ankiNum：由来源身份 + 字段 / 模板组成确定性派生，
  /// 两台设备导入同一个包得到同一个 ID（铁律 C）；同一种结构再导入回到同一份副本
  /// （对应 Anki 的 get_previously_duplicated_notetype）。
  static int _duplicateAnkiNum(SrsAnkiNoteType src) => hash53(
    'notetype-dup/${src.ankiNum}/${srsCanonicalJson(<String, Object?>{
      'cloze': src.isCloze,
      'fields': <Object?>[for (final SrsAnkiField f in src.fields) f.configId ?? 'name:${f.name}'],
      'tmpls': <Object?>[for (final SrsAnkiTemplate t in src.templates) t.configId ?? 'name:${t.name}'],
    })}',
  );

  Future<_NtMap> _mapNoteType(SrsAnkiNoteType src) async {
    final String baseId = SrsIds.noteType(profileUid, src.ankiNum);
    final String kind = src.isCloze
        ? SrsNoteTypeKind.cloze
        : SrsNoteTypeKind.standard;
    final SrsNoteTypeView? base = await store.noteType(baseId);
    if (base != null && base.kind != kind) {
      return _NtMap(
        id: baseId,
        name: src.name,
        isCloze: src.isCloze,
        fieldIds: const <String>[],
        templateIdByOrd: const <int, String>{},
        conflict: SrsImportIssueReason.noteTypeKindMismatch,
      );
    }
    if (base != null && !options.mergeNoteTypes && !_equalSchema(base, src)) {
      // 不合并：本机那一个不动，来源笔记类型另建一份。
      final int dupNum = _duplicateAnkiNum(src);
      final String dupId = SrsIds.noteType(profileUid, dupNum);
      final SrsNoteTypeView? dup = await store.noteType(dupId);
      if (dup == null) report.noteTypesDuplicated.add(src.name);
      return _mapInto(src, dupId, dupNum, dup);
    }
    return _mapInto(src, baseId, src.ankiNum, base);
  }

  Future<_NtMap> _mapInto(
    SrsAnkiNoteType src,
    String ntId,
    int ankiNum,
    SrsNoteTypeView? existing,
  ) async {
    final String kind = src.isCloze
        ? SrsNoteTypeKind.cloze
        : SrsNoteTypeKind.standard;
    final bool created = existing == null;
    // 来源较新 / 总是 / 从不：只管名字、CSS、模板正文、已有项的名字与顺序。
    final bool update =
        existing == null ||
        options.updateNoteTypes.shouldUpdate(
          localMs: _lastEditMs(existing.edits, _isNoteTypeContentKey, 0),
          sourceMs: src.mtimeSecs * 1000,
        );
    final SrsNoteTypeView view;
    if (existing != null) {
      view = existing;
    } else {
      await store.importEvents(<SrsEvent>[
        SrsEntityEvent(
          SrsEntityRecord(
            id: ntId,
            profileUid: profileUid,
            kind: SrsEntityKind.noteType,
            payload: <String, Object?>{
              'ankiNum': ankiNum,
              'ntKind': kind,
              'createdAt': src.ankiNum,
            },
          ),
        ),
      ]);
      view = (await store.noteType(ntId))!;
    }

    final (
      Map<String, SrsFieldDef> haveFields,
      Map<String, SrsTemplateDef> haveTmpls,
    ) = _haveDefs(
      view,
    );
    final List<String> fieldIds = _resolveFields(ntId, src, haveFields);
    final Map<int, String> tmplByOrd = _resolveTemplates(ntId, src, haveTmpls);

    final Map<String, Object?> edits = <String, Object?>{};
    final Map<String, String> nameToId = <String, String>{};
    for (final (int i, SrsAnkiField f) in src.fields.indexed) {
      final String id = fieldIds[i];
      nameToId[f.name] = id;
      final SrsFieldDef? have = haveFields[id];
      final bool keepLocal = have != null && !update;
      final SrsFieldDef want = SrsFieldDef(
        id: id,
        name: keepLocal ? have.name : f.name,
        ord: keepLocal ? have.ord : f.ord,
        ankiNum: f.configId ?? have?.ankiNum,
      );
      if (have == null ||
          srsCanonicalJson(have.toValue()) !=
              srsCanonicalJson(want.toValue())) {
        edits[SrsFieldKeys.fieldDef(id)] = want.toValue();
      }
    }

    for (final SrsAnkiTemplate t in src.templates) {
      final String id = tmplByOrd[t.ord]!;
      final SrsTemplateDef? have = haveTmpls[id];
      final bool writeBody = have == null || update;
      final SrsTemplateDef want = SrsTemplateDef(
        id: id,
        name: writeBody ? t.name : have.name,
        ord: writeBody ? t.ord : have.ord,
        front: writeBody
            ? templateNamesToIds(
                await _withMedia(t.qfmt, includeStatic: true),
                nameToId,
              )
            : have.front,
        back: writeBody
            ? templateNamesToIds(
                await _withMedia(t.afmt, includeStatic: true),
                nameToId,
              )
            : have.back,
        ankiNum: t.configId ?? have?.ankiNum,
      );
      if (have == null ||
          srsCanonicalJson(have.toValue()) !=
              srsCanonicalJson(want.toValue())) {
        edits[SrsFieldKeys.templateDef(id)] = want.toValue();
      }
    }

    // 来源删掉的项本地不删，只进报告。
    final Set<String> fieldSet = fieldIds.toSet();
    for (final SrsFieldDef f in haveFields.values) {
      if (!f.deleted && !fieldSet.contains(f.id)) {
        report.removedInSource.add(
          SrsImportRemovedItem(
            noteType: src.name,
            name: f.name,
            isTemplate: false,
          ),
        );
      }
    }
    final Set<String> tmplSet = tmplByOrd.values.toSet();
    for (final SrsTemplateDef t in haveTmpls.values) {
      if (!t.deleted && !tmplSet.contains(t.id)) {
        report.removedInSource.add(
          SrsImportRemovedItem(
            noteType: src.name,
            name: t.name,
            isTemplate: true,
          ),
        );
      }
    }

    if (update) {
      if (view.name != src.name) edits[SrsFieldKeys.name] = src.name;
      final String css = await _withMedia(src.css, includeStatic: true);
      if (view.css != css) edits[SrsFieldKeys.css] = css;
    }
    if (edits.isNotEmpty) {
      await store.editFields(SrsEntityKind.noteType, ntId, edits);
      if (!created) report.noteTypesUpdated++;
    }
    return _NtMap(
      id: ntId,
      name: src.name,
      isCloze: src.isCloze,
      fieldIds: fieldIds,
      templateIdByOrd: tmplByOrd,
    );
  }

  // ------------------------------------------------------------------ 牌组

  Future<void> _mapDecks() async {
    final Set<int> used = <int>{
      for (final Row r in col.db.select(
        'SELECT DISTINCT CASE WHEN odid != 0 THEN odid ELSE did END AS d FROM cards',
      ))
        r['d'] as int,
    };
    final Map<String, SrsAnkiDeck> byName = <String, SrsAnkiDeck>{
      for (final SrsAnkiDeck d in col.decks.values)
        if (!d.filtered) d.name: d,
    };
    final Set<String> names = <String>{};
    for (final int id in used) {
      final SrsAnkiDeck? d = col.decks[id];
      if (d == null || d.filtered) continue;
      final List<String> parts = _parts(d.name);
      for (int i = 1; i <= parts.length; i++) {
        names.add(parts.sublist(0, i).join('::'));
      }
    }
    final List<String> ordered = names.toList()
      ..sort((String a, String b) {
        final int c = _parts(a).length.compareTo(_parts(b).length);
        return c != 0 ? c : a.compareTo(b);
      });

    SrsDeckTree tree = await store.deckTree();
    final Map<String, String> idByName = <String, String>{};
    final Set<String> created = <String>{};
    for (final String full in ordered) {
      final List<String> parts = _parts(full);
      final String leaf = parts.last;
      final String? parent = parts.length == 1
          ? null
          : idByName[parts.sublist(0, parts.length - 1).join('::')];
      String? found;
      for (final SrsDeckView d in tree.decks) {
        if (d.name == leaf && tree.parentOf(d.id) == parent) {
          found = d.id;
          break;
        }
      }
      if (found != null) {
        idByName[full] = found;
        continue;
      }
      final String id = srsImportedDeckId(profileUid, full);
      if (tree[id] != null) {
        // 用户把先前导入的同名牌组改了名 / 挪了位置：不复用，另建一个。
        idByName[full] = await store.createDeck(leaf, parentId: parent);
      } else {
        await store.importEvents(<SrsEvent>[
          SrsEntityEvent(
            SrsEntityRecord(
              id: id,
              profileUid: profileUid,
              kind: SrsEntityKind.deck,
              payload: const <String, Object?>{'createdAt': 0},
            ),
          ),
        ]);
        await store.editFields(SrsEntityKind.deck, id, <String, Object?>{
          SrsFieldKeys.name: leaf,
          if (parent != null) SrsFieldKeys.deckParent: parent,
          // 先前导入过、后来被删：重新导入即恢复。
          if (await _deckDeleted(id)) SrsFieldKeys.deleted: null,
        });
        idByName[full] = id;
        created.add(full);
      }
      tree = await store.deckTree();
    }

    for (final SrsAnkiDeck d in col.decks.values) {
      final String? id = idByName[d.name];
      if (id != null) _deckOf[d.id] = id;
    }

    // 不含牌组预设：新建的牌组用本机默认设置（Anki：预设 id 重置为默认预设）。
    if (!options.withDeckConfigs) {
      report.deckPresetsSkipped = <int>{
        for (final String full in ordered)
          if (created.contains(full) && byName[full] != null)
            byName[full]!.configId,
      }.where(col.presets.containsKey).length;
      return;
    }

    // 牌组设置：只在首次建牌组时写。
    final Set<int> reportedPresets = <int>{};
    for (final String full in ordered) {
      if (!created.contains(full)) continue;
      final SrsAnkiDeck? src = byName[full];
      final SrsAnkiPreset? preset = src == null
          ? null
          : col.presets[src.configId];
      final List<String> parts = _parts(full);
      final String? parentName = parts.length == 1
          ? null
          : parts.sublist(0, parts.length - 1).join('::');
      final SrsAnkiDeck? parentSrc = parentName == null
          ? null
          : byName[parentName];
      // 同一预设：父牌组也是本次新建、且用同一预设 → 继承；否则 own（顶层恒 own）。
      final bool inherit =
          preset != null &&
          parentName != null &&
          created.contains(parentName) &&
          parentSrc != null &&
          parentSrc.configId == preset.id;
      final Map<String, Object?> values = preset == null
          ? <String, Object?>{}
          : _presetValues(
              preset,
              own: !inherit,
              report: reportedPresets.add(preset.id),
            );
      if (parentName != null) {
        values[SrsFieldKeys.deckParamsMode] = inherit ? 'inherit' : 'own';
      }
      // Anki 里收起的牌组导入后同样收起（缺省展开，不写记录）。
      if (src != null && src.collapsed) {
        values[SrsFieldKeys.deckCollapsed] = true;
      }
      final Map<String, Object?>? ext = _extDecks[full];
      if (ext != null) {
        for (final String k in srsFushiExtDeckKeys) {
          if (ext.containsKey(k)) values[k] = ext[k];
        }
      }
      if (values.isNotEmpty) {
        await store.editFields(SrsEntityKind.deck, idByName[full]!, values);
      }
    }
  }

  /// 身份记录已存在、却不在牌组树里 = 先前导入过、后来被删。
  Future<bool> _deckDeleted(String id) async {
    final SrsEntityRow? row = await (store.db.select(
      store.db.srsEntities,
    )..where(($SrsEntitiesTable t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return false;
    return (await store.deckTree())[id] == null;
  }

  static List<String> _parts(String full) => full
      .split('::')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList();

  Map<String, Object?> _presetValues(
    SrsAnkiPreset p, {
    required bool own,
    required bool report,
  }) {
    final Map<String, Object?> v = <String, Object?>{};
    List<double> steps(List<double> src, List<double> fallback, String kind) {
      final List<double> kept = srsSanitizeSteps(src, fallback);
      final List<double> removed = <double>[
        for (final double s in src)
          if (!(s > 0 && s < 1440)) s,
      ];
      if (removed.isNotEmpty && report) {
        this.report.truncatedSteps.add(
          SrsImportTruncatedSteps(
            preset: p.name,
            kind: kind,
            removed: removed,
            kept: kept,
          ),
        );
      }
      return kept;
    }

    v[SrsFieldKeys.deckSteps] = <String, Object?>{
      'learn': steps(p.learnSteps, SrsDeckView.defaultLearnSteps, 'learn'),
      'relearn': steps(
        p.relearnSteps,
        SrsDeckView.defaultRelearnSteps,
        'relearn',
      ),
    };
    v[SrsFieldKeys.deckLimits] = <String, Object?>{
      'new': p.newPerDay,
      'review': p.reviewsPerDay,
    };
    if (p.maxIntervalDays > 0) {
      v[SrsFieldKeys.deckMaxInterval] = p.maxIntervalDays;
    }
    if (!own) return v;
    // 音频两项随参数继承（只写在 own 牌组上）；与缺省值相同时不写，不产生多余记录。
    if (!p.autoplay) v[SrsFieldKeys.deckAutoplay] = false;
    if (!p.replayQuestion) v[SrsFieldKeys.deckReplayQuestion] = false;
    if (p.desiredRetention > 0 && p.desiredRetention < 1) {
      v[SrsFieldKeys.deckRetention] = p.desiredRetention;
    }
    SrsAlgorithm alg = srsDefaultAlgorithm;
    List<double>? params;
    if (col.fsrsEnabled) {
      if (p.rwkvEnabled && report) this.report.rwkvPresetsFellBack.add(p.name);
      if (p.fsrs7Params.length == SrsAlgorithm.fsrs7.paramCount &&
          (p.fsrsVersion ?? 0) == 0) {
        alg = SrsAlgorithm.fsrs7;
        params = p.fsrs7Params;
      } else if (p.fsrs6Params.length == SrsAlgorithm.fsrs6.paramCount) {
        alg = SrsAlgorithm.fsrs6;
        params = p.fsrs6Params;
      }
    }
    v[SrsFieldKeys.deckAlgorithm] = <String, Object?>{
      'alg': alg.wire,
      'auto': true,
    };
    if (params != null) {
      final String? bad = _validate(alg, params);
      if (bad != null) {
        if (report) this.report.invalidParams[p.name] = bad;
      } else {
        v[alg == SrsAlgorithm.fsrs6
            ? SrsFieldKeys.deckFsrs6Params
            : SrsFieldKeys.deckFsrs7Params] = SrsParamSet(
          params: params,
        ).toValue();
      }
    }
    return v;
  }

  String? _validate(SrsAlgorithm alg, List<double> params) {
    if (params.length != alg.paramCount) {
      return 'expected ${alg.paramCount} params, got ${params.length}';
    }
    if (params.any((double x) => !x.isFinite)) return 'non-finite parameter';
    return store.engine?.validateParams(alg, params);
  }

  // ------------------------------------------------------------------ 笔记 / 卡片 / 日志

  Future<void> _importNotes() async {
    final int total = max(
      1,
      col.db.select('SELECT count(*) AS n FROM notes').first['n'] as int,
    );
    final PreparedStatement cardsOf = col.db.prepare(
      'SELECT id, did, odid, ord, type, queue, due, odue, ivl, factor, reps, '
      'lapses, data FROM cards WHERE nid = ? ORDER BY ord, id',
    );
    final PreparedStatement revlogOf = col.db.prepare(
      'SELECT id, ease, ivl, factor, time, type FROM revlog WHERE cid = ? ORDER BY id',
    );
    final PreparedStatement notes = col.db.prepare(
      'SELECT id, guid, mid, mod, tags, flds FROM notes ORDER BY id',
    );
    try {
      final IteratingCursor cur = notes.selectCursor();
      int done = 0;
      while (cur.moveNext()) {
        final Row n = cur.current;
        await _importNote(n, <_SrcCard>[
          for (final Row r in cardsOf.select(<Object?>[n['id']])) _SrcCard(r),
        ], revlogOf);
        done++;
        if (done % 50 == 0) onProgress?.call(done / total);
        await _flush();
      }
    } finally {
      cardsOf.close();
      revlogOf.close();
      notes.close();
    }
  }

  Future<void> _flush({bool force = false}) async {
    if (_pending.isEmpty || (!force && _pending.length < 500)) return;
    final List<SrsEvent> batch = List<SrsEvent>.of(_pending);
    _pending.clear();
    await store.importEvents(batch);
  }

  Future<void> _importNote(
    Row n,
    List<_SrcCard> cards,
    PreparedStatement revlogOf,
  ) async {
    final String guid = n['guid'] as String;
    final int mid = n['mid'] as int;
    final _NtMap? nt = _nts[mid];
    if (nt == null || nt.conflict != null) {
      report.conflictNotes.add(
        SrsImportNoteIssue(
          guid: guid,
          noteType: nt?.name ?? '$mid',
          reason: nt?.conflict ?? SrsImportIssueReason.missingNoteType,
        ),
      );
      return;
    }
    final List<String> raw = (n['flds'] as String).split('\x1f');
    final Map<String, String> fields = <String, String>{};
    for (int i = 0; i < nt.fieldIds.length; i++) {
      fields[nt.fieldIds[i]] = i < raw.length ? await _withMedia(raw[i]) : '';
    }
    final List<String> tags = (n['tags'] as String)
        .split(RegExp(r'\s+'))
        .where((String t) => t.isNotEmpty)
        // 不含排程：与 Anki 相同，去掉 marked / leech 这两个排程系统标签。
        .where(
          (String t) =>
              options.withScheduling ||
              !_schedulingTags.contains(t.toLowerCase()),
        )
        .toList();
    final String noteId = SrsIds.note(profileUid, guid);
    final SrsNoteView? existing = await store.note(noteId);
    final String firstDeck = cards.isEmpty
        ? store.defaultDeckId
        : (_deckOf[cards.first.homeDeck] ?? store.defaultDeckId);

    final bool isNew = existing == null;
    bool update = false;
    if (isNew) {
      await store.createNote(
        noteTypeId: nt.id,
        fieldsById: fields,
        deckId: firstDeck,
        tags: tags,
        source: SrsSourceRef.fromJson(_extNotes[guid]),
        guid: guid,
        createdAt: n['id'] as int,
      );
      report.notesAdded++;
      report.cardsAdded += cards.length;
    } else if (existing.noteTypeId != nt.id) {
      report.conflictNotes.add(
        SrsImportNoteIssue(
          guid: guid,
          noteType: nt.name,
          reason: SrsImportIssueReason.noteTypeChanged,
        ),
      );
      return;
    } else if (options.updateNotes.shouldUpdate(
      localMs: _lastEditMs(
        existing.edits,
        _isNoteContentKey,
        existing.createdAt,
      ),
      sourceMs: ((n['mod'] as int?) ?? 0) * 1000,
    )) {
      update = true;
      final List<SrsFieldEdit>? written = await store.editFields(
        SrsEntityKind.note,
        noteId,
        <String, Object?>{
          // 只写与本机物化值不同的项（缺记录的字段读作空、空标签不必再写一遍）。
          for (final MapEntry<String, String> f in fields.entries)
            if (existing.field(f.key) != f.value)
              SrsFieldKeys.noteField(f.key): f.value,
          if (!_sameList(existing.tags, tags)) SrsFieldKeys.noteTags: tags,
        },
      );
      if (written != null && written.isNotEmpty) {
        report.notesUpdated++;
      } else {
        report.notesSkipped++;
      }
    } else {
      report.notesSkipped++;
    }

    for (final _SrcCard c in cards) {
      final String? tplId = nt.isCloze
          ? (nt.templateIdByOrd.isEmpty
                ? null
                : nt.templateIdByOrd[nt.templateIdByOrd.keys.reduce(min)])
          : nt.templateIdByOrd[c.ord];
      if (tplId == null) continue;
      final String cardId = SrsIds.card(
        noteId,
        tplId,
        nt.isCloze ? c.ord + 1 : 0,
      );
      await _importCardFlags(
        cardId,
        c,
        firstDeck,
        isNew: isNew,
        update: update,
      );
      if (options.withScheduling) {
        await _importCardSchedule(cardId, c, revlogOf, noteExisted: !isNew);
      } else if (isNew && (c.type != 0 || c.queue < 0)) {
        report.cardsResetToNew++;
      }
    }
  }

  Future<void> _importCardFlags(
    String cardId,
    _SrcCard c,
    String noteDeck, {
    required bool isNew,
    required bool update,
  }) async {
    if (!isNew && !update) return;
    final String deck = _deckOf[c.homeDeck] ?? store.defaultDeckId;
    // 暂停属于排程（Anki 不含排程时整卡 schedule_as_new，暂停一并清掉）。
    final bool suspended = c.queue == -1;
    final bool withSuspend = options.withScheduling;
    if (isNew) {
      if (deck != noteDeck) await store.moveCard(cardId, deck);
      if (withSuspend && suspended) await store.setSuspended(cardId, true);
      return;
    }
    final SrsCardCacheRow? row = await store.cardRow(cardId);
    if (row == null) return;
    if (row.deckId != deck) await store.moveCard(cardId, deck);
    if (withSuspend && row.suspended != suspended) {
      await store.setSuspended(cardId, suspended);
    }
  }

  Future<void> _importCardSchedule(
    String cardId,
    _SrcCard c,
    PreparedStatement revlogOf, {
    required bool noteExisted,
  }) async {
    final List<_SrcRevlog> revlogs = <_SrcRevlog>[
      for (final Row r in revlogOf.select(<Object?>[c.id])) _SrcRevlog(r),
    ];
    final (int nowMs, _) = store.now();
    final int latest = revlogs.isEmpty ? 0 : revlogs.last.id;
    if (latest > nowMs + srsClockToleranceMs) {
      report.futureCards.add(c.id);
      return;
    }

    // fushi-ext：恢复 Fushi 日志；它导出的 revlog 只作校验。
    final List<SrsReviewLog> extLogs =
        _extLogsByCard[c.id] ?? const <SrsReviewLog>[];
    final Set<int> extRevlogs = <int>{};
    if (extLogs.isNotEmpty) {
      for (final SrsReviewLog l in extLogs) {
        final int? rid = _extRevlogIds[l.id];
        if (rid != null) extRevlogs.add(rid);
        _pending.add(SrsLogEvent(_remapExtLog(l, cardId)));
        report.fushiLogsRestored++;
      }
    }

    List<SrsReviewLog>? native;
    if (noteExisted) {
      native = (await store.history(
        cardId,
      )).all.where((SrsReviewLog l) => l.origin == SrsLogOrigin.fushi).toList();
    }

    int reps = 0;
    int lapses = 0;
    int? lastRated;
    for (final _SrcRevlog r in revlogs) {
      final bool rating = r.isRating;
      if (rating) {
        reps++;
        if (r.type == 1 && r.ease == 1) lapses++;
        lastRated = r.id;
      } else if (!r.isFiltered && r.row.isReset) {
        reps = 0;
        lapses = 0;
      }
      if (extRevlogs.contains(r.id)) {
        report.revlogsVerifiedByExt++;
        continue;
      }
      if (pkg.fushiExt != null) report.revlogsNotInExt++;
      _pending.add(
        SrsLogEvent(
          _revlogLog(
            cardId,
            r,
            reps: reps,
            lapses: lapses,
            lastRated: lastRated,
          ),
        ),
      );
      report.reviewLogsImported++;
    }

    final SrsAnchorDecision d = srsDecideAnchor(
      sourceIsNew: c.type == 0,
      revlogs: <SrsAnkiRevlogRow>[for (final _SrcRevlog r in revlogs) r.row],
      collectionCreatedMs: col.crtSecs * 1000,
      equivalentToNative: (SrsAnkiRevlogRow last) {
        if (extRevlogs.contains(last.id)) return true;
        final List<SrsReviewLog>? nat = native;
        if (nat == null || nat.isEmpty) return false;
        final _SrcRevlog src = revlogs.lastWhere(
          (_SrcRevlog r) => r.id == last.id,
        );
        final SrsReviewLog imported = _revlogLog(
          cardId,
          src,
          reps: 0,
          lapses: 0,
          lastRated: null,
        );
        // native 是这张卡的整份历史（含前身卡的日志），同一张逻辑卡。
        return nat.any(
          (SrsReviewLog l) => srsImportEquivalent(imported, l, sameCard: true),
        );
      },
    );
    if (!d.write) return;
    final int t = d.anchorMs!;
    final SrsMemory? mem = _memoryOf(c.data);
    _pending.add(
      SrsLogEvent(
        SrsReviewLog(
          id: SrsIds.importAnchor(cardId, t),
          profileUid: profileUid,
          cardId: cardId,
          kind: SrsLogKind.importAnchor,
          hlc: srsImportAnchorHlc(t),
          occurredAt: t,
          timeSource: SrsTimeSource.wall,
          origin: SrsLogOrigin.anki,
          reviewType: SrsReviewType.manual,
          utcOffsetMin: srcDay.utcOffsetMin,
          dayRolloverHour: srcDay.rolloverHour,
          result: _cardState(c, lastRated, mem),
          extra: mem == null
              ? const <String, Object?>{}
              : <String, Object?>{'memAlg': SrsAlgorithm.fsrs6.wire},
        ),
      ),
    );
    report.anchorsWritten++;
  }

  SrsReviewLog _remapExtLog(SrsReviewLog l, String cardId) {
    if (_extSameProfile && l.cardId == cardId) return l;
    if (_extSameProfile && _extLogCards.containsKey(l.id)) {
      // 同 profile：前身卡的身份在本 profile 下不变，日志原样落回前身卡，再补上前身链接。
      _historyLinks.add(
        SrsEditSpec(
          SrsEntityKind.card,
          cardId,
          SrsFieldKeys.cardHistoryFrom(l.cardId),
          true,
        ),
      );
      return l;
    }
    final Map<String, Object?> j = l.toJson();
    j['id'] = SrsIds.remappedLog(cardId, l.id);
    if (l.revokesId != null) {
      j['revokes'] = SrsIds.remappedLog(cardId, l.revokesId!);
    }
    j['card'] = cardId;
    j['p'] = profileUid;
    return SrsReviewLog.fromJson(j);
  }

  SrsReviewLog _revlogLog(
    String cardId,
    _SrcRevlog r, {
    required int reps,
    required int lapses,
    required int? lastRated,
  }) {
    final bool manual = !r.isFiltered && !r.isRating;
    return SrsReviewLog(
      id: SrsIds.importedRevlog(cardId, r.id),
      profileUid: profileUid,
      cardId: cardId,
      kind: manual ? SrsLogKind.manual : SrsLogKind.review,
      rating: r.ease >= 1 && r.ease <= 4 ? r.ease : null,
      hlc: srsImportedRevlogHlc(r.id),
      occurredAt: r.id,
      timeSource: SrsTimeSource.wall,
      origin: SrsLogOrigin.anki,
      reviewType: SrsReviewType.fromAnki(r.type),
      durationMs: r.time,
      algorithm: 'anki',
      utcOffsetMin: srcDay.utcOffsetMin,
      dayRolloverHour: srcDay.rolloverHour,
      result: r.isFiltered
          ? null
          : _revlogResult(r, reps: reps, lapses: lapses, lastRated: lastRated),
      ankiRevlogId: r.id,
    );
  }

  /// 该次之后 Anki 的状态近似。
  SrsScheduleResult _revlogResult(
    _SrcRevlog r, {
    required int reps,
    required int lapses,
    required int? lastRated,
  }) {
    final int day = srcDay.dayIndexOf(r.id);
    final int? ease = r.factor > 0 ? r.factor : null;
    SrsScheduleResult review() => SrsScheduleResult(
      queue: SrsQueue.review,
      dueDay: day + max(0, r.ivl),
      scheduledDays: max(0, r.ivl),
      lastReviewedAt: lastRated,
      reps: reps,
      lapses: lapses,
      ease: ease,
    );
    SrsScheduleResult learning(SrsQueue q) => SrsScheduleResult(
      queue: q,
      dueAt: r.id + (r.ivl < 0 ? -r.ivl * 1000 : 0),
      lastReviewedAt: lastRated,
      reps: reps,
      lapses: lapses,
      ease: ease,
    );
    if (!r.isRating) {
      if (r.row.isReset) {
        return const SrsScheduleResult(queue: SrsQueue.newCard);
      }
      return r.ivl < 0 ? learning(SrsQueue.learning) : review();
    }
    return switch (r.type) {
      0 => r.ivl > 0 ? review() : learning(SrsQueue.learning),
      1 => r.ease == 1 && r.ivl <= 0 ? learning(SrsQueue.relearning) : review(),
      _ => r.ivl > 0 ? review() : learning(SrsQueue.relearning),
    };
  }

  /// 锚点结果：来源卡的状态。
  SrsScheduleResult _cardState(_SrcCard c, int? lastRated, SrsMemory? mem) {
    final SrsQueue q = switch (c.type) {
      1 => SrsQueue.learning,
      2 => SrsQueue.review,
      3 => SrsQueue.relearning,
      _ => SrsQueue.newCard,
    };
    final int due = c.odid != 0 && c.odue != 0 ? c.odue : c.due;
    int? dueDay;
    int? dueAt;
    switch (q) {
      case SrsQueue.review:
        dueDay = crtDay + due;
      case SrsQueue.learning:
      case SrsQueue.relearning:
        // queue 1 的 due 是秒级时间戳；跨天学习（queue 3）的 due 是相对 crt 的天数。
        dueAt = c.queue == 3 || due < 1000000000
            ? srcDay.dayStartMs(crtDay + due)
            : due * 1000;
      case SrsQueue.newCard:
        break;
    }
    return SrsScheduleResult(
      queue: q,
      dueDay: dueDay,
      dueAt: dueAt,
      scheduledDays: max(0, c.ivl),
      memory: mem,
      lastReviewedAt: q == SrsQueue.newCard ? null : lastRated,
      reps: c.reps,
      lapses: c.lapses,
      scheduler: srsAnchorScheduler,
      ease: c.factor > 0 ? c.factor : null,
    );
  }

  static SrsMemory? _memoryOf(String data) {
    if (data.isEmpty) return null;
    try {
      final Object? j = jsonDecode(data);
      if (j is! Map) return null;
      final Object? s = j['s'];
      final Object? d = j['d'];
      if (s is! num || d is! num) return null;
      return SrsMemory(stability: s.toDouble(), difficulty: d.toDouble());
    } on FormatException {
      return null;
    }
  }
}

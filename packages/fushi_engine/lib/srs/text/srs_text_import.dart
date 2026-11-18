/// 复习卡的文本导入（CSV / TSV / TXT，对齐 Anki「导入 → 文本文件」）。
///
/// - 解析在原生内核（native/fushi_fsrs/src/text_import.rs 的 `text_import_parse`）：一次调用读完整个文件，
///   回文件头（Anki 文本导出写的 `#separator:` / `#html:` / `#columns:` / `#notetype:` / `#deck:` / `… column:`
///   / `#if matches:` / `#match scope:`）、定下来的分隔符与 HTML 判定、全部记录。[parseSrsTextFile] 在后台
///   isolate 里调它。
/// - 写库在这里（[runSrsTextImport]），走与新建笔记相同的事件路径（[SrsDbStore.newNoteDrafts] 攒批
///   [SrsDbStore.importDrafts]；更新已有笔记分批走 [SrsDbStore.editFieldsBatch]），不另开写入通道。
/// - 已有笔记的匹配照 Anki：GUID 列命中优先；否则按首字段（查重规范形，与 AnkiConnect 查重同一份
///   `anki_dupes`，整份文件一条原生命令）在同一笔记类型（[SrsTextMatchScope.noteTypeAndDeck] 时再限同一牌组）
///   里找；GUID 列有值的行只按 GUID 匹配（库里没有这个 GUID 就是新笔记，不再退回首字段）。命中后按
///   [SrsTextDupeMode]：更新 / 保留（跳过）/ 照样另加一条。只和导入前库里已有的笔记匹配，同一份文件里的行
///   互不匹配（Anki 的 `existing_checksums` / `existing_guids` 同样只在开始时建一次），首字段相同的两行导成两条。
///
/// 不支持 Anki 的「笔记类型列」（每行各自的笔记类型）：一次导入一个笔记类型，文件头的 `#notetype:` 只用来预选。
library;

import 'dart:isolate';
import 'dart:math' show min;

import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_card_gate.dart';

/// 文本导入能选的文件扩展名（文件选择器用）。
const Set<String> kSrsTextImportExtensions = <String>{'csv', 'tsv', 'txt'};

/// [path] 是不是文本导入的文件（按扩展名）。
bool srsIsTextImportPath(String path) {
  final String lower = path.toLowerCase();
  final int dot = lower.lastIndexOf('.');
  return dot >= 0 &&
      kSrsTextImportExtensions.contains(lower.substring(dot + 1));
}

/// 首字段已存在时怎么办（Anki 文本导入的「已存在的笔记」，文件头 `#if matches:`）。
enum SrsTextDupeMode {
  /// 用文件里的值更新已有笔记（映射到的字段；标签追加）。
  update('update'),

  /// 保留已有笔记，这一行跳过。
  preserve('preserve'),

  /// 照样另加一条。
  duplicate('duplicate');

  const SrsTextDupeMode(this.wire);
  final String wire;

  static SrsTextDupeMode? parse(Object? v) {
    for (final SrsTextDupeMode m in values) {
      if (m.wire == v) return m;
    }
    return null;
  }
}

/// 匹配已有笔记的范围（文件头 `#match scope:`）。
enum SrsTextMatchScope {
  /// 同一笔记类型。
  noteType('notetype'),

  /// 同一笔记类型且同一牌组。
  noteTypeAndDeck('notetypeDeck');

  const SrsTextMatchScope(this.wire);
  final String wire;

  static SrsTextMatchScope? parse(Object? v) {
    for (final SrsTextMatchScope m in values) {
      if (m.wire == v) return m;
    }
    return null;
  }
}

/// 一个解析好的文本文件（`text_import_parse` 的结果）。列号都是 1 起的。
class SrsTextFile {
  const SrsTextFile({
    required this.delimiter,
    required this.html,
    required this.columnCount,
    required this.total,
    required this.rows,
    this.delimiterFromHeader = false,
    this.htmlFromHeader = false,
    this.columns = const <String>[],
    this.tags = const <String>[],
    this.noteType,
    this.deck,
    this.noteTypeColumn,
    this.deckColumn,
    this.tagsColumn,
    this.guidColumn,
    this.ifMatches,
    this.matchScope,
  });

  factory SrsTextFile.fromJson(Map<String, Object?> j) {
    List<String> strings(Object? v) => v is List
        ? <String>[for (final Object? s in v) '${s ?? ''}']
        : const <String>[];
    int? column(Object? v) => v is int && v > 0 ? v : null;
    final Object? rows = j['rows'];
    return SrsTextFile(
      delimiter: j['delimiter'] as String? ?? ',',
      html: j['html'] == true,
      delimiterFromHeader: j['delimiterFromHeader'] == true,
      htmlFromHeader: j['htmlFromHeader'] == true,
      columns: strings(j['columns']),
      columnCount: j['columnCount'] as int? ?? 0,
      total: j['total'] as int? ?? 0,
      rows: rows is List
          ? <List<String>>[for (final Object? r in rows) strings(r)]
          : const <List<String>>[],
      tags: strings(j['tags']),
      noteType: j['notetype'] as String?,
      deck: j['deck'] as String?,
      noteTypeColumn: column(j['notetypeColumn']),
      deckColumn: column(j['deckColumn']),
      tagsColumn: column(j['tagsColumn']),
      guidColumn: column(j['guidColumn']),
      ifMatches: SrsTextDupeMode.parse(j['ifMatches']),
      matchScope: SrsTextMatchScope.parse(j['matchScope']),
    );
  }

  /// 实际用的分隔符（单个字符）。
  final String delimiter;

  /// 字段按 HTML 导入；false 时 [rows] 里的值已转义（`&` `<` `>`、换行变 `<br>`）。
  final bool html;
  final bool delimiterFromHeader;
  final bool htmlFromHeader;

  /// `#columns:` 给的列名（可能为空）。
  final List<String> columns;

  /// 最宽一行的列数。
  final int columnCount;

  /// 全部记录数（[rows] 在预览时只有前几条）。
  final int total;
  final List<List<String>> rows;

  /// `#tags:`：加到每条笔记上的标签。
  final List<String> tags;
  final String? noteType;
  final String? deck;
  final int? noteTypeColumn;
  final int? deckColumn;
  final int? tagsColumn;
  final int? guidColumn;
  final SrsTextDupeMode? ifMatches;
  final SrsTextMatchScope? matchScope;

  /// 文件头里有没有说明列的用途（笔记类型 / 牌组 / 标签 / GUID 列）。
  Set<int> get metaColumns => <int>{
    ?noteTypeColumn,
    ?deckColumn,
    ?tagsColumn,
    ?guidColumn,
  };
}

/// 在后台 isolate 里解析 [path]（原生内核 `text_import_parse`）。[delimiter] / [html] 为 null 时按文件头或猜；
/// [limit] 只取前几条（预览）。内核不可用抛 [SrsImportException]（needsKernel）。
Future<SrsTextFile> parseSrsTextFile(
  String path, {
  String? delimiter,
  bool? html,
  int? limit,
}) async {
  final FushiFsrs? lib = FushiFsrs.instance;
  if (lib == null) {
    throw const SrsImportException(
      SrsImportException.needsKernel,
      'scheduling kernel unavailable',
    );
  }
  final String? libraryPath = lib.libraryPath;
  final Map<String, Object?> raw = await Isolate.run(() {
    final FfiFsrsEngine? engine = FfiFsrsEngine.tryCreate(
      libraryPath: libraryPath,
    );
    if (engine == null) {
      throw const SrsImportException(
        SrsImportException.needsKernel,
        'scheduling kernel unavailable',
      );
    }
    return engine.textImportParse(
      path,
      delimiter: delimiter,
      html: html,
      limit: limit,
    );
  });
  return SrsTextFile.fromJson(raw);
}

/// 一次文本导入的设置（对话框选的）。
class SrsTextImportOptions {
  const SrsTextImportOptions({
    required this.noteTypeId,
    required this.deckId,
    required this.fieldColumns,
    this.tagsColumn,
    this.deckColumn,
    this.guidColumn,
    this.tags = const <String>[],
    this.dupeMode = SrsTextDupeMode.update,
    this.matchScope = SrsTextMatchScope.noteType,
  });

  final String noteTypeId;

  /// 默认牌组（牌组列空或没设牌组列时用）。
  final String deckId;

  /// 笔记类型字段顺序上每个字段取哪一列（1 起；0 = 不导入，留空）。
  final List<int> fieldColumns;

  /// 标签列（空白分隔的标签）。
  final int? tagsColumn;

  /// 牌组列（「父::子」全名；没有的牌组会建）。
  final int? deckColumn;

  /// GUID 列（命中已有笔记时按它匹配；新笔记用它当 GUID）。
  final int? guidColumn;

  /// 加到每条笔记上的标签。
  final List<String> tags;
  final SrsTextDupeMode dupeMode;
  final SrsTextMatchScope matchScope;
}

/// Anki 的默认列映射：文件头给了列名且与字段名相同（不分大小写）的按名字对上；其余字段按顺序取还没用到的
/// 普通列（文件头声明了用途的列不参与）。
List<int> srsTextDefaultFieldColumns(
  List<String> fieldNames,
  SrsTextFile file,
) {
  final Set<int> used = <int>{...file.metaColumns};
  final List<int> out = List<int>.filled(fieldNames.length, 0);
  for (int i = 0; i < fieldNames.length; i++) {
    final String want = fieldNames[i].trim().toLowerCase();
    for (int c = 0; c < file.columns.length; c++) {
      final int col = c + 1;
      if (!used.contains(col) && file.columns[c].trim().toLowerCase() == want) {
        out[i] = col;
        used.add(col);
        break;
      }
    }
  }
  int next = 1;
  for (int i = 0; i < fieldNames.length; i++) {
    if (out[i] != 0) continue;
    while (next <= file.columnCount && used.contains(next)) {
      next++;
    }
    if (next > file.columnCount) break;
    out[i] = next;
    used.add(next);
  }
  return out;
}

/// 非 HTML 文件里，内核已把每个字段转义成 HTML；牌组 / 标签 / GUID 列要的是原文，转回来。
String _plain(String v, bool html) => html
    ? v
    : v
          .replaceAll('<br>', '\n')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&amp;', '&');

String _cell(List<String> row, int? column) =>
    column != null && column > 0 && column <= row.length ? row[column - 1] : '';

/// 一批的大小：逐行决定阶段每处理这么多行（不论新增、更新还是跳过）落一次库、报一次进度、看一次叫停；更新阶段
/// 每批这么多条笔记一个事务。叫停在批间生效。
const int _kBatch = 500;

/// 一行要写成的笔记。
class _Row {
  _Row(this.fields, this.tags, this.deckId, this.deckPath, this.guid);

  final Map<String, String> fields;
  final List<String> tags;

  /// 牌组 id；null = 牌组列里的牌组库里还没有，真要写进这一行的新笔记时才按 [deckPath] 建（叫停、跳过、只更新的行
  /// 不留下空牌组）。
  final String? deckId;

  /// 牌组列的全名（`父::子`，已去空段）；[deckId] 有值时不用。
  final String deckPath;

  /// GUID 列的值（空 = 没有）。
  final String guid;
}

/// 把 [file] 的全部记录按 [options] 导进 [store]，回导入报告（新增 / 更新 / 跳过的笔记数、新增卡片数）。
///
/// 首字段为空、或按笔记类型生成不出任何卡的行跳过（Anki 同样不加）。逐行阶段每 [_kBatch] 行、更新阶段每
/// [_kBatch] 条笔记报一次 [onProgress]，并看一次 [shouldStop]：返回 true 时抛 [SrsImportStopped]（已落库的批保留）。
/// 牌组列里库中没有的牌组在它的第一条新笔记落库前才建，叫停时不留下空牌组。[dupeNormBatch] 是首字段查重规范形
/// （测试注入；缺省原生内核）。
Future<SrsImportReport> runSrsTextImport({
  required SrsDbStore store,
  required SrsTextFile file,
  required SrsTextImportOptions options,
  void Function(double progress)? onProgress,
  bool Function()? shouldStop,
  List<String> Function(List<String> fields)? dupeNormBatch,
}) async {
  final SrsImportReport report = SrsImportReport();
  final SrsNoteTypeView? type = (await store.noteTypes())
      .where((SrsNoteTypeView t) => t.id == options.noteTypeId)
      .firstOrNull;
  if (type == null || type.fields.isEmpty) {
    throw SrsImportException(
      SrsImportException.corrupt,
      'note type not found: ${options.noteTypeId}',
    );
  }
  final List<String> fieldIds = <String>[
    for (final SrsFieldDef f in type.fields) f.id,
  ];

  // 1. 每行 → 字段 / 标签 / 牌组（牌组列的名字一次解析；库里没有的先只记名字，第一条要写进去的新笔记落库前再建）。
  final SrsDeckTree tree = await store.deckTree();
  final Map<String, String> deckByName = <String, String>{
    for (final SrsDeckView d in tree.decks)
      tree.fullName(d.id).toLowerCase(): d.id,
  };
  String deckPathOf(String name) => name
      .split('::')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .join('::');
  Future<String> deckOf(_Row r) async =>
      r.deckId ??
      (deckByName[r.deckPath.toLowerCase()] ??= await store.ensureDeckPath(
        r.deckPath,
      ));

  final List<_Row> rows = <_Row>[];
  for (final List<String> r in file.rows) {
    final Map<String, String> fields = <String, String>{
      for (int i = 0; i < fieldIds.length; i++)
        fieldIds[i]: i < options.fieldColumns.length
            ? _cell(r, options.fieldColumns[i])
            : '',
    };
    final List<String> tags = <String>[
      ...options.tags,
      ..._plain(
        _cell(r, options.tagsColumn),
        file.html,
      ).split(RegExp(r'\s+')).where((String s) => s.isNotEmpty),
    ];
    final String deckPath = options.deckColumn == null
        ? ''
        : deckPathOf(_plain(_cell(r, options.deckColumn), file.html));
    final String? deckId = deckPath.isEmpty
        ? options.deckId
        : deckByName[deckPath.toLowerCase()];
    rows.add(
      _Row(
        fields,
        tags.toSet().toList(),
        deckId,
        deckPath,
        _plain(_cell(r, options.guidColumn), file.html).trim(),
      ),
    );
  }

  // 2. 首字段查重规范形整批一次算完；库内匹配整份一条原生命令。
  final List<String> norms = (dupeNormBatch ?? srsDupeNormBatch)(<String>[
    for (final _Row r in rows) r.fields[fieldIds.first] ?? '',
  ]);
  final bool byDeck = options.matchScope == SrsTextMatchScope.noteTypeAndDeck;
  final List<List<String>> dbHits = List<List<String>>.filled(
    rows.length,
    const <String>[],
  );
  if (options.dupeMode != SrsTextDupeMode.duplicate) {
    final List<int> at = <int>[
      for (int i = 0; i < rows.length; i++)
        // GUID 列有值的行只按 GUID 匹配（Anki `find_duplicates`），不进首字段查重。
        if (norms[i].isNotEmpty && rows[i].guid.isEmpty) i,
    ];
    if (at.isNotEmpty) {
      final Object? ids = (await store.browseCommand(<String, Object?>{
        'op': 'anki_dupes',
        'owner': 'text_import',
        'first': <String, Object?>{type.id: fieldIds.first},
        'cands': <Map<String, Object?>>[
          for (final int i in at)
            <String, Object?>{
              'norm': norms[i],
              'type': type.id,
              'all': false,
              // 还没建的牌组里不会有已有笔记：范围是空集。
              'decks': byDeck
                  ? <String>[if (rows[i].deckId case final String d) d]
                  : null,
            },
        ],
      })).map['ids'];
      if (ids is List) {
        for (int k = 0; k < at.length && k < ids.length; k++) {
          final Object? hit = ids[k];
          if (hit is List) {
            dbHits[at[k]] = <String>[for (final Object? h in hit) '$h'];
          }
        }
      }
    }
  }

  // GUID 列命中的已有笔记（未删除的才算）。
  final Map<String, String> guidNote = <String, String>{};
  final Set<String> deletedGuids = <String>{};
  if (options.guidColumn != null) {
    final Map<String, String> idOfGuid = <String, String>{
      for (final _Row r in rows)
        if (r.guid.isNotEmpty) r.guid: store.kernelIds.note(r.guid),
    };
    if (idOfGuid.isNotEmpty) {
      final Map<String, SrsNoteView?> found = await store.notes(
        idOfGuid.values,
      );
      for (final MapEntry<String, String> e in idOfGuid.entries) {
        final SrsNoteView? n = found[e.value];
        if (n == null) continue;
        if (n.deletedAt == null && n.noteTypeId == type.id) {
          guidNote[e.key] = e.value;
        } else {
          deletedGuids.add(e.key);
        }
      }
    }
  }

  // 要更新的已有笔记的现有标签（标签只追加）。
  final Set<String> toUpdate = <String>{
    if (options.dupeMode == SrsTextDupeMode.update) ...<String>{
      for (final List<String> h in dbHits) ...h,
      ...guidNote.values,
    },
  };
  final Map<String, SrsNoteView?> existing = toUpdate.isEmpty
      ? const <String, SrsNoteView?>{}
      : await store.notes(toUpdate);

  // 3. 逐行决定：新增 / 更新 / 跳过。只和导入前库里的笔记匹配（上面一次查齐），同一份文件里的行互不匹配。
  final bool matching = options.dupeMode != SrsTextDupeMode.duplicate;
  final Set<String> usedGuids = <String>{};
  final List<_NewNote> batch = <_NewNote>[];
  // 要更新的笔记：id → (字段 id → 新值, 更新后的标签)。
  final Map<String, (Map<String, String>, Set<String>)> updates =
      <String, (Map<String, String>, Set<String>)>{};
  final List<String> mappedFieldIds = <String>[
    for (int f = 0; f < fieldIds.length; f++)
      if (f < options.fieldColumns.length && options.fieldColumns[f] > 0)
        fieldIds[f],
  ];

  void updateExisting(String id, Set<String> currentTags, _Row r) {
    final (Map<String, String>, Set<String>) u = updates[id] ??= (
      <String, String>{},
      <String>{...currentTags},
    );
    for (final String f in mappedFieldIds) {
      u.$1[f] = r.fields[f] ?? '';
    }
    u.$2.addAll(r.tags);
  }

  Future<void> flush() async {
    if (batch.isEmpty) return;
    final List<String> deckIds = <String>[
      for (final _NewNote n in batch) await deckOf(n.row),
    ];
    await store.importDrafts(<SrsEventDraft>[
      for (int k = 0; k < batch.length; k++)
        ...store.newNoteDrafts(
          noteTypeId: type.id,
          fieldsById: batch[k].row.fields,
          guid: batch[k].guid,
          noteId: batch[k].noteId,
          deckId: deckIds[k],
          tags: batch[k].row.tags,
        ),
    ]);
    batch.clear();
  }

  // 进度：逐行阶段每行一份、更新阶段每条要更新的笔记一份（上界 = 要读的已有笔记数），收尾一份。
  final int progressTotal = rows.length + toUpdate.length + 1;
  void checkpoint(int done) {
    onProgress?.call(done / progressTotal);
    if (shouldStop?.call() ?? false) throw const SrsImportStopped();
  }

  for (int i = 0; i < rows.length; i++) {
    if (i > 0 && i % _kBatch == 0) {
      await flush();
      checkpoint(i);
    }
    final _Row r = rows[i];
    // Anki 只跳过首字段是字面空串的行；只有图片 / 音频的首字段查重规范形为空，但照样导入。
    if ((r.fields[fieldIds.first] ?? '').isEmpty ||
        !srsNoteProducesCard(type, r.fields)) {
      report.notesSkipped++;
      continue;
    }
    // GUID 列有值：只认 GUID 命中，没命中就是新笔记（不退回首字段，免得覆盖不相干的同名笔记）。
    final List<String> hits = r.guid.isEmpty
        ? dbHits[i]
        : <String>[if (guidNote[r.guid] case final String id) id];
    if (matching && hits.isNotEmpty) {
      if (options.dupeMode == SrsTextDupeMode.preserve) {
        report.notesSkipped++;
        continue;
      }
      for (final String id in hits) {
        final SrsNoteView? n = existing[id];
        if (n != null) updateExisting(id, n.tags.toSet(), r);
      }
      continue;
    }
    String guid = r.guid;
    if (guid.isEmpty ||
        guidNote.containsKey(guid) ||
        deletedGuids.contains(guid) ||
        !usedGuids.add(guid)) {
      guid = newNoteGuid();
    }
    final _NewNote n = _NewNote(guid, store.kernelIds.note(guid), r);
    batch.add(n);
    report.notesAdded++;
  }
  await flush();

  // 4. 更新已有笔记：每 [_kBatch] 条一个事务（批间报进度、看叫停），值没变的键内核不落；有键真的落了才算「已更新」。
  final List<MapEntry<String, (Map<String, String>, Set<String>)>> pending =
      updates.entries.toList();
  for (int from = 0; from < pending.length; from += _kBatch) {
    checkpoint(rows.length + from);
    final List<MapEntry<String, (Map<String, String>, Set<String>)>> chunk =
        pending.sublist(from, min(from + _kBatch, pending.length));
    final List<SrsFieldEdit> written = await store.editFieldsBatch(
      <SrsFieldChange>[
        for (final MapEntry<String, (Map<String, String>, Set<String>)> e
            in chunk) ...<SrsFieldChange>[
          for (final MapEntry<String, String> f in e.value.$1.entries)
            SrsFieldChange(
              SrsEntityKind.note,
              e.key,
              SrsFieldKeys.noteField(f.key),
              f.value,
            ),
          SrsFieldChange(
            SrsEntityKind.note,
            e.key,
            SrsFieldKeys.noteTags,
            e.value.$2.toList(),
          ),
        ],
      ],
    );
    final Set<String> touched = <String>{
      for (final SrsFieldEdit e in written) e.entityId,
    };
    report.notesUpdated += touched.length;
    report.notesSkipped += chunk.length - touched.length;
  }
  onProgress?.call(1);
  return report;
}

/// 本次导入新增的笔记。
class _NewNote {
  _NewNote(this.guid, this.noteId, this.row);

  final String guid;
  final String noteId;
  final _Row row;
}

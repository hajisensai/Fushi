/// 卡片浏览（对齐 Anki 浏览器）：一次性快照 + Anki 搜索语法筛选 + 排序 + 卡片 / 笔记两种模式。
///
/// 求值对象 [SrsCardSearchSubject] 同时给 AnkiConnect 兼容层与统计页筛选用（findNotes /
/// findCards），搜索语义只有这一份；笔记那一半经 [SrsSubjectNote] 抽象：那两处拿完整物化的
/// [SrsNoteView]，浏览快照只拿笔记缓存行（[SrsBrowseNoteHeader]），字段原文与最后改动时刻
/// 等搜索 / 排序真用到时才分块读（见 srs_browse_query.dart）。
library;

import 'package:fushi_anki/fushi_anki_core.dart'
    show FushiCardFields, ankiStripHtml;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_browse_query.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

export 'package:fushi_engine/srs/srs_browse_query.dart'
    show SrsBrowseNoteHeader, srsEditsModifiedAt;

/// 笔记最后一次改动的时刻（全部字段键当前生效记录里 HLC 物理时刻最大的一条；没有记录 = 创建时刻）。
int srsNoteModifiedAt(SrsNoteView note) =>
    srsEditsModifiedAt(note.createdAt, note.edits);

/// 求值对象用到的那一半笔记数据。
abstract interface class SrsSubjectNote {
  String get id;
  int get createdAt;
  List<String> get tags;

  /// 内容类待裁决（[SrsNoteView.hasPendingDecision]）。
  bool get hasPendingDecision;

  /// 最后改动时刻；按需装载的笔记还没取到时抛 [StateError]。
  int get modifiedAt;

  /// 字段原文（fieldId；没有值 = 空串）；不常驻字段的笔记抛 [StateError]。
  String field(String fieldId);

  /// 排序字段（[type] 的第一个字段）去 HTML、trim 后的文本。
  String sortText(SrsNoteTypeView type);
}

/// 完整物化的笔记（AnkiConnect / 统计页）。
class _ViewNote implements SrsSubjectNote {
  _ViewNote(this.view);

  final SrsNoteView view;

  @override
  String get id => view.id;

  @override
  int get createdAt => view.createdAt;

  @override
  List<String> get tags => view.tags;

  @override
  bool get hasPendingDecision => view.hasPendingDecision;

  @override
  late final int modifiedAt = srsNoteModifiedAt(view);

  @override
  String field(String fieldId) => view.field(fieldId);

  @override
  String sortText(SrsNoteTypeView type) => type.fields.isEmpty
      ? ''
      : ankiStripHtml(view.field(type.fields.first.id)).trim();
}

/// 浏览快照的笔记：笔记缓存行，字段原文不常驻。
class _HeaderNote implements SrsSubjectNote {
  _HeaderNote(this.header);

  final SrsBrowseNoteHeader header;

  @override
  String get id => header.id;

  @override
  int get createdAt => header.createdAt;

  @override
  List<String> get tags => header.tags;

  @override
  bool get hasPendingDecision => header.hasPendingDecision;

  @override
  int get modifiedAt =>
      header.loadedModifiedAt ??
      (throw StateError(
        'note ${header.id}: modifiedAt not loaded (SrsBrowseSnapshot loads '
        'it on demand)',
      ));

  @override
  String field(String fieldId) => throw StateError(
    'note ${header.id}: field values are not resident in the browse snapshot '
    '(load them via SrsSearchFieldLoader / browseNoteFieldValues)',
  );

  @override
  String sortText(SrsNoteTypeView type) => header.sortField;
}

/// Anki 搜索里的字面量：通配符（`*` `_` `\`）与语法字符（`"` `:`）全部转义。
String _searchLiteral(String text) =>
    text.replaceAllMapped(RegExp(r'[\\*_":]'), (Match m) => '\\${m.group(0)}');

/// 「不用记语法」的按字段搜索：在 [field] 字段里包含 [text]（不区分大小写、去 HTML 比较），
/// 生成等价的 Anki 查询 `"字段:*文本*"`。[text] 为空返回空串（= 全部）。
String srsFieldContainsQuery(String field, String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) return '';
  return '"${_searchLiteral(field)}:*${_searchLiteral(trimmed)}*"';
}

/// 「浏览此牌组的卡片」的查询：`deck:"全名"`（Anki 语义，含子牌组）。牌组名里的通配符
/// （`*` `_`）、反斜杠与引号转义成字面量；层级分隔符 `::` 在引号内照原样保留。
String srsDeckQuery(String deckFullName) =>
    'deck:"${deckFullName.replaceAllMapped(RegExp(r'[\\*_"]'), (Match m) => '\\${m.group(0)}')}"';

/// 搜索语料的字段别名（[SrsSearchFieldAliases]）：内置 Fushi 卡片改过名的 9 个字段带上改名前后的
/// 另一个名字（[FushiCardFields]），`Expression:食べる`（Yomitan 查重的 findNotes）仍查到 `Term` 字段；
/// 字段定义记录里还是旧名时 `Term:…` 也认。其它笔记类型（含 Lapis、自建）没有别名。
Map<String, String> srsCardSearchFieldAliases(SrsSearchSubject subject) {
  final SrsNoteTypeView type = (subject as SrsCardSearchSubject).noteType;
  if (type.builtinKey != kSrsBuiltinFushiCardKey) {
    return const <String, String>{};
  }
  return _aliasesByType[type] ??= <String, String>{
    for (final SrsFieldDef f in type.fields)
      if (FushiCardFields.aliasOf(f.name) case final String alias)
        f.name: alias,
  };
}

final Expando<Map<String, String>> _aliasesByType =
    Expando<Map<String, String>>('srsCardSearchFieldAliases');

/// 一张卡（连同笔记、笔记类型）作为 Anki 搜索的求值对象。
class SrsCardSearchSubject implements SrsSearchSubject {
  /// 由完整物化的笔记建（字段原文常驻，[fields] 可直接读）。
  SrsCardSearchSubject({
    required SrsNoteView note,
    required this.noteType,
    required this.card,
    required this.deckName,
    required this.day,
    required this.nowMs,
    required this.todayDayIndex,
    this.instantDue,
    int Function(String uuid)? numericId,
  }) : note = _ViewNote(note),
       _numericId = numericId ?? SrsIds.ankiNumericId;

  /// 由笔记缓存行建（浏览快照）：[fields] 不可读，字段值经 [SrsSearchFieldLoader] 按需取；
  /// [editedDayIndex] 要先按需装好最后改动时刻。
  SrsCardSearchSubject.browse({
    required SrsBrowseNoteHeader header,
    required this.noteType,
    required this.card,
    required this.deckName,
    required this.day,
    required this.nowMs,
    required this.todayDayIndex,
    this.instantDue,
    int Function(String uuid)? numericId,
  }) : note = _HeaderNote(header),
       _numericId = numericId ?? SrsIds.ankiNumericId;

  final SrsSubjectNote note;
  final SrsNoteTypeView noteType;
  final SrsCardCacheRow card;
  final SrsDayContext day;
  final int nowMs;
  final int Function(String uuid) _numericId;

  /// 这张卡所在牌组按 RWKV-Instant 排队时：此刻会出的卡（[SrsDbStore.instantDueCardIds]）。
  /// null = 不按 R 排（非 RWKV 牌组，或 RWKV 不可用、照旧按存下的到期日）。
  final Set<String>? instantDue;

  /// 复习卡按此刻回忆率排队：没有有意义的到期日。
  bool get _byRecall => instantDue != null && queue == SrsQueue.review;

  @override
  final String deckName;

  @override
  final int todayDayIndex;

  SrsQueue get queue => SrsQueue.parse(card.queue);

  /// 这张卡的模板（模板被删了返回 null）。
  late final SrsTemplateDef? template = noteType.templates
      .where((SrsTemplateDef t) => t.id == card.templateId)
      .firstOrNull;

  /// 笔记最后一次改动的时刻。
  int get modifiedAt => note.modifiedAt;

  /// 排序字段（笔记类型的第一个字段，与 Anki 默认 sortf = 0 一致）去 HTML 后的文本。
  late final String sortText = note.sortText(noteType);

  @override
  Object get noteKey => note.id;

  @override
  String get noteTypeName => noteType.name;

  @override
  late final Map<String, String> fields = <String, String>{
    for (final SrsFieldDef f in noteType.fields) f.name: note.field(f.id),
  };

  @override
  List<String> get tags => note.tags;

  @override
  bool get isNew => queue == SrsQueue.newCard;

  @override
  bool get isLearn =>
      queue == SrsQueue.learning || queue == SrsQueue.relearning;

  @override
  bool get isReview => queue == SrsQueue.review || queue == SrsQueue.relearning;

  @override
  bool get isDue => switch (queue) {
    SrsQueue.newCard => false,
    SrsQueue.review when _byRecall => instantDue!.contains(card.id),
    SrsQueue.review => (card.dueDay ?? 0) <= todayDayIndex,
    SrsQueue.learning ||
    SrsQueue.relearning => (card.dueAt ?? 0) <= nowMs + 20 * 60000,
  };

  @override
  bool get isSuspended => card.suspended;

  @override
  bool get isBuried =>
      card.buriedUntilDay != null && card.buriedUntilDay! > todayDayIndex;

  @override
  int get noteId => _numericId(note.id);

  @override
  int get cardId => _numericId(card.id);

  @override
  int get addedDayIndex => day.dayIndexOf(note.createdAt);

  @override
  int get flag => card.flag;

  @override
  int get cardOrdinal =>
      noteType.isCloze ? card.clozeOrd : (template?.ord ?? 0) + 1;

  @override
  String get templateName => template?.name ?? '';

  @override
  int get intervalDays => switch (queue) {
    SrsQueue.newCard || SrsQueue.learning => 0,
    SrsQueue.review || SrsQueue.relearning => card.scheduledDays,
  };

  @override
  int? get dueInDays {
    switch (queue) {
      case SrsQueue.newCard:
        return null;
      case SrsQueue.review when _byRecall:
        return null;
      case SrsQueue.review:
        final int? d = card.dueDay;
        return d == null ? null : d - todayDayIndex;
      case SrsQueue.learning || SrsQueue.relearning:
        final int? at = card.dueAt;
        if (at == null) return null;
        // rslib：(due - 明天日界) / 86400，整数除法向零截断。
        return (at - day.dayStartMs(todayDayIndex + 1)) ~/ 86400000;
    }
  }

  @override
  int get reps => card.reps;

  @override
  int get lapses => card.lapses;

  @override
  double? get stability => card.stability;

  @override
  double? get difficulty => card.difficulty;

  @override
  int get editedDayIndex => day.dayIndexOf(modifiedAt);

  /// 到期排序键：复习卡按到期日、学习中按到期时刻折成日序号（同一天里排在复习卡前面），
  /// 新卡没有到期日，排在最后（按加入顺序）；按回忆率排队的复习卡此刻会出的排今天，其余排在新卡前。
  double get dueSortKey => switch (queue) {
    SrsQueue.newCard => double.infinity,
    SrsQueue.review when _byRecall =>
      instantDue!.contains(card.id)
          ? todayDayIndex.toDouble()
          : double.maxFinite,
    SrsQueue.review => (card.dueDay ?? todayDayIndex).toDouble(),
    SrsQueue.learning ||
    SrsQueue.relearning => day.dayIndexOf(card.dueAt ?? nowMs) - 0.5,
  };
}

/// 列表模式：一行一张卡 / 一行一条笔记。
enum SrsBrowseMode { cards, notes }

/// 排序列。
enum SrsBrowseSortColumn {
  /// 排序字段（笔记类型的第一个字段）。
  sortField,

  /// 指定字段（[SrsBrowseSort.fieldName]）。
  field,

  /// 到期。
  due,

  /// 新建时间（笔记创建时刻）。
  created,

  /// 修改时间（笔记最后改动 / 卡片最后复习，取较晚者）。
  modified,

  /// 间隔。
  interval,

  /// FSRS 难度。
  difficulty,

  /// 复习次数。
  reps,

  /// 遗忘次数。
  lapses,

  /// 牌组名。
  deck,

  /// 笔记类型名。
  noteType,
}

/// 排序设置。
class SrsBrowseSort {
  const SrsBrowseSort({
    this.column = SrsBrowseSortColumn.created,
    this.ascending = false,
    this.fieldName,
  });

  final SrsBrowseSortColumn column;
  final bool ascending;

  /// [SrsBrowseSortColumn.field] 时按哪个字段（名字不区分大小写；笔记类型没有这个字段的排在最后）。
  final String? fieldName;

  SrsBrowseSort copyWith({
    SrsBrowseSortColumn? column,
    bool? ascending,
    String? fieldName,
  }) => SrsBrowseSort(
    column: column ?? this.column,
    ascending: ascending ?? this.ascending,
    fieldName: fieldName ?? this.fieldName,
  );

  @override
  bool operator ==(Object other) =>
      other is SrsBrowseSort &&
      other.column == column &&
      other.ascending == ascending &&
      other.fieldName == fieldName;

  @override
  int get hashCode => Object.hash(column, ascending, fieldName);
}

/// 列表的一行。卡片模式 [cards] 只有这一张；笔记模式是该笔记的全部可见卡片（批量操作对整条笔记生效），
/// [primary] 是命中搜索的第一张（预览它）。
class SrsBrowseItem {
  const SrsBrowseItem({required this.primary, required this.cards});

  final SrsCardSearchSubject primary;
  final List<SrsCardSearchSubject> cards;

  String get noteId => primary.note.id;
  String get cardId => primary.card.id;
}

/// 笔记类型的字段名 → fieldId（按字段顺序；同名取最后一个，与 [SrsCardSearchSubject.fields] 同口径）。
Map<String, String> _fieldIdsByName(SrsNoteTypeView type) => <String, String>{
  for (final SrsFieldDef f in type.fields) f.name: f.id,
};

/// 浏览快照的字段值来源：搜索要哪些列，就按页读那几列的修改记录（[browseNoteFieldValues]）。
class _BrowseFieldLoader implements SrsSearchFieldLoader {
  _BrowseFieldLoader(this.store);

  final SrsDbStore store;
  final Map<String, Map<String, String>> _byType =
      <String, Map<String, String>>{};

  Map<String, String> _idsOf(SrsNoteTypeView t) =>
      _byType[t.id] ??= _fieldIdsByName(t);

  @override
  List<String> fieldNames(SrsSearchSubject subject) =>
      _idsOf((subject as SrsCardSearchSubject).noteType).keys.toList();

  @override
  Future<List<List<String>>> load(
    List<SrsSearchSubject> notes,
    List<List<String>> names,
  ) async {
    final List<String> noteIds = <String>[];
    final Set<String> fieldIds = <String>{};
    final List<List<String>> wanted = <List<String>>[];
    for (int i = 0; i < notes.length; i++) {
      final SrsCardSearchSubject s = notes[i] as SrsCardSearchSubject;
      final Map<String, String> ids = _idsOf(s.noteType);
      noteIds.add(s.note.id);
      final List<String> row = <String>[
        for (final String n in names[i]) ids[n]!,
      ];
      fieldIds.addAll(row);
      wanted.add(row);
    }
    final Map<String, Map<String, String>> values = await store
        .browseNoteFieldValues(noteIds, fieldIds);
    return <List<String>>[
      for (int i = 0; i < noteIds.length; i++)
        <String>[
          for (final String f in wanted[i]) values[noteIds[i]]?[f] ?? '',
        ],
    ];
  }
}

/// 查询里有没有 `edited:`（要按需装笔记的最后改动时刻）。
bool _usesEdited(SrsSearchNode node) => switch (node) {
  SrsSearchAnd(:final List<SrsSearchNode> children) ||
  SrsSearchOr(:final List<SrsSearchNode> children) => children.any(_usesEdited),
  SrsSearchNot(:final SrsSearchNode child) => _usesEdited(child),
  SrsSearchEditedInDays() => true,
  _ => false,
};

/// 浏览页的一次性数据快照（每次写操作后重新加载）。
///
/// 只常驻列表要用的列：笔记缓存行（排序字段文本、标签、创建时刻、待裁决标记）+ 卡片缓存行
/// （排程列）+ 笔记类型。字段原文只在搜索 / 按字段排序用到时按列分页读：搜索的那份传进原生
/// 搜索内核（Dart 堆上同时只有一页），排序的那份只留去 HTML 后的小写文本；笔记最后改动时刻只在
/// `edited:` / 按修改时间排序时分块算一次。预览 / 编辑按卡片 ID 另读完整笔记。
class SrsBrowseSnapshot {
  SrsBrowseSnapshot._(this.cards, this.noteTypes, this._store);

  /// 由现成的求值对象建快照（基准 / 测试用；生产走 [load]）。求值对象须由完整笔记建
  /// （[SrsCardSearchSubject] 默认构造）：没有按需读取的来源。
  factory SrsBrowseSnapshot.fromCards(
    List<SrsCardSearchSubject> cards,
    List<SrsNoteTypeView> noteTypes,
  ) => SrsBrowseSnapshot._(cards, noteTypes, null);

  /// 未删除笔记的全部可见卡片（按笔记创建时刻、卡片序号）。
  final List<SrsCardSearchSubject> cards;
  final List<SrsNoteTypeView> noteTypes;

  /// 按需读字段值 / 最后改动时刻的来源；null = 求值对象自带完整笔记（[fromCards]）。
  final SrsDbStore? _store;

  /// 搜索语料（第一次非空搜索时装进原生内核，快照内的后续搜索复用）。
  SrsSearchCorpus? _corpusOrNull;
  SrsSearchCorpus get _corpus => _corpusOrNull ??= SrsSearchCorpus(
    cards,
    fieldLoader: _store == null ? null : _BrowseFieldLoader(_store),
    fieldAliases: srsCardSearchFieldAliases,
  );

  /// 已备好（字段值已传进内核、要的改动时刻已装）的查询。
  final Set<String> _prepared = <String>{};

  /// 笔记最后改动时刻的按需装载（只装一次）。
  Future<void>? _modifiedLoad;

  /// 按字段排序的值（字段名小写 → noteId → 去 HTML 的小写文本），按需分块读、读过的复用。
  final Map<String, Map<String, String?>> _sortFieldValues =
      <String, Map<String, String?>>{};

  bool _disposed = false;

  /// 释放搜索语料的原生内存（字段文本可达几百 MB）；之后 [query] 只返回空列表。换快照时调。
  void dispose() {
    _disposed = true;
    _corpusOrNull?.dispose();
  }

  static Future<SrsBrowseSnapshot> load(SrsDbStore store) async {
    final List<SrsNoteTypeView> types = await store.noteTypes();
    final Map<String, SrsNoteTypeView> typeById = <String, SrsNoteTypeView>{
      for (final SrsNoteTypeView t in types) t.id: t,
    };
    final Map<String, SrsBrowseNoteHeader> notes =
        <String, SrsBrowseNoteHeader>{
          for (final SrsBrowseNoteHeader n in await store.browseNoteHeaders())
            n.id: n,
        };
    final SrsDeckTree tree = await store.deckTree();
    final SrsDayContext day = await store.dayContext();
    final (int nowMs, _) = store.now();
    final int today = day.dayIndexOf(nowMs);
    final Map<String, String> deckNames = <String, String>{};
    final Set<String>? instantDue = await store.instantDueCardIds();
    final Map<String, bool> byRecall = <String, bool>{};
    final List<SrsCardSearchSubject> out = <SrsCardSearchSubject>[];
    for (final SrsCardCacheRow c in await store.browseCardRows()) {
      final SrsBrowseNoteHeader? n = notes[c.noteId];
      final SrsNoteTypeView? t = n == null ? null : typeById[n.noteTypeId];
      if (n == null || t == null || t.deletedAt != null) continue;
      out.add(
        SrsCardSearchSubject.browse(
          header: n,
          noteType: t,
          card: c,
          // 牌组已不存在的卡归默认牌组（与排程配置同一判据）：显示为默认牌组、
          // `deck:Default` 能筛到（BUG-3617）。
          deckName: deckNames[c.deckId] ??= tree.effectiveDeckNameOf(
            c.deckId,
            fallback: store.defaultDeckId,
          ),
          day: day,
          nowMs: nowMs,
          todayDayIndex: today,
          instantDue:
              instantDue != null &&
                  (byRecall[c.deckId] ??= store.instantActiveFor(
                    tree,
                    c.deckId,
                  ))
              ? instantDue
              : null,
        ),
      );
    }
    out.sort(_naturalOrder);
    return SrsBrowseSnapshot._(out, types, store);
  }

  /// 全部笔记类型的字段名（去重，按笔记类型、字段顺序）——「按字段搜索 / 排序」的下拉选项。
  List<String> get fieldNames {
    final Set<String> seen = <String>{};
    final List<String> out = <String>[];
    for (final SrsNoteTypeView t in noteTypes) {
      for (final SrsFieldDef f in t.fields) {
        if (seen.add(f.name.toLowerCase())) out.add(f.name);
      }
    }
    return out;
  }

  /// 预先备好 [query] 求值要的数据（字段文本分页读进原生内核、`edited:` 要的改动时刻）：之后同一条
  /// [query] 只剩求值。语法错误 / 内核不可用不在这里报（留给 [query] 抛，调用方只有一处要处理）。
  Future<void> prepare(String query) async {
    try {
      await _prepare(parseAnkiSearch(query), query);
    } on SrsSearchUnsupported {
      return;
    }
  }

  Future<void> _prepare(SrsSearchNode node, String query) async {
    if (_prepared.contains(query)) return;
    if (_usesEdited(node)) await _ensureModifiedAt();
    await _corpus.prepare(node, query: query);
    _prepared.add(query);
  }

  /// 按 Anki 搜索语法筛选、排序。查询不合法 / 不支持 / 内核不可用时抛 [SrsSearchUnsupported]。
  /// 快照已 [dispose]（换快照的期间还在算的旧查询）返回空列表。
  Future<List<SrsBrowseItem>> query({
    String query = '',
    SrsBrowseSort sort = const SrsBrowseSort(),
    SrsBrowseMode mode = SrsBrowseMode.cards,
  }) async {
    final SrsSearchNode node = parseAnkiSearch(query);
    if (_disposed) return const <SrsBrowseItem>[];
    await _prepare(node, query);
    if (_disposed) return const <SrsBrowseItem>[];
    final List<SrsCardSearchSubject> hits = <SrsCardSearchSubject>[
      for (final int i in _corpus.match(node, query: query)) cards[i],
    ];
    final List<SrsBrowseItem> items;
    if (mode == SrsBrowseMode.cards) {
      items = <SrsBrowseItem>[
        for (final SrsCardSearchSubject c in hits)
          SrsBrowseItem(primary: c, cards: <SrsCardSearchSubject>[c]),
      ];
    } else {
      final Map<String, List<SrsCardSearchSubject>> byNote =
          <String, List<SrsCardSearchSubject>>{};
      for (final SrsCardSearchSubject c in cards) {
        (byNote[c.note.id] ??= <SrsCardSearchSubject>[]).add(c);
      }
      final Set<String> seen = <String>{};
      items = <SrsBrowseItem>[
        for (final SrsCardSearchSubject c in hits)
          if (seen.add(c.note.id))
            SrsBrowseItem(primary: c, cards: byNote[c.note.id]!),
      ];
    }
    Map<String, String?>? fieldValues;
    switch (sort.column) {
      case SrsBrowseSortColumn.modified:
        await _ensureModifiedAt();
      case SrsBrowseSortColumn.field:
        fieldValues = await _fieldSortValues(items, sort.fieldName);
      case _:
        break;
    }
    if (_disposed) return const <SrsBrowseItem>[];
    items.sort(srsBrowseComparator(sort, fieldValues: fieldValues));
    return items;
  }

  /// 装好全部笔记的最后改动时刻（[_HeaderNote.modifiedAt]）。完整笔记建的快照不用装。
  Future<void> _ensureModifiedAt() => _modifiedLoad ??= () async {
    final SrsDbStore? store = _store;
    if (store == null) return;
    final Map<String, SrsBrowseNoteHeader> headers =
        <String, SrsBrowseNoteHeader>{
          for (final SrsCardSearchSubject c in cards)
            if (c.note case final _HeaderNote h)
              if (h.header.loadedModifiedAt == null) h.id: h.header,
        };
    try {
      final Map<String, int> at = await store.browseNoteModifiedAt(
        <(String, int)>[
          for (final SrsBrowseNoteHeader h in headers.values)
            (h.id, h.createdAt),
        ],
      );
      for (final SrsBrowseNoteHeader h in headers.values) {
        h.loadedModifiedAt = at[h.id] ?? h.createdAt;
      }
    } catch (_) {
      _modifiedLoad = null;
      rethrow;
    }
  }();

  /// 按字段 [fieldName]（不区分大小写）排序用的值：noteId → 去 HTML、trim、小写后的文本；
  /// 笔记类型没有这个字段的为 null（排在最后）。只读 [items] 里还没读过的笔记的那一个字段。
  Future<Map<String, String?>> _fieldSortValues(
    List<SrsBrowseItem> items,
    String? fieldName,
  ) async {
    final String? name = fieldName?.toLowerCase();
    if (name == null) return const <String, String?>{};
    final Map<String, String?> cache = _sortFieldValues[name] ??=
        <String, String?>{};
    final Map<String, String> fieldOf = <String, String>{};
    final Map<String, SrsCardSearchSubject> pending =
        <String, SrsCardSearchSubject>{};
    for (final SrsBrowseItem item in items) {
      final SrsCardSearchSubject p = item.primary;
      if (cache.containsKey(p.note.id) || pending.containsKey(p.note.id)) {
        continue;
      }
      SrsFieldDef? def;
      for (final SrsFieldDef f in p.noteType.fields) {
        if (f.name.toLowerCase() == name) {
          def = f;
          break;
        }
      }
      if (def == null) {
        cache[p.note.id] = null;
        continue;
      }
      fieldOf[p.note.id] = def.id;
      pending[p.note.id] = p;
    }
    if (pending.isEmpty) return cache;
    String norm(String raw) => ankiStripHtml(raw).trim().toLowerCase();
    final SrsDbStore? store = _store;
    if (store == null) {
      for (final MapEntry<String, SrsCardSearchSubject> e in pending.entries) {
        cache[e.key] = norm(e.value.note.field(fieldOf[e.key]!));
      }
      return cache;
    }
    final Map<String, Map<String, String>> raw = await store
        .browseNoteFieldValues(pending.keys.toList(), fieldOf.values.toSet());
    for (final String id in pending.keys) {
      cache[id] = norm(raw[id]?[fieldOf[id]!] ?? '');
    }
    return cache;
  }
}

int _naturalOrder(SrsCardSearchSubject a, SrsCardSearchSubject b) {
  int c = a.note.createdAt.compareTo(b.note.createdAt);
  if (c != 0) return c;
  c = a.note.id.compareTo(b.note.id);
  if (c != 0) return c;
  c = a.cardOrdinal.compareTo(b.cardOrdinal);
  return c != 0 ? c : a.card.id.compareTo(b.card.id);
}

/// 一行在某一列上的排序值：`String` / `num`；null = 没有这个值（不论升降序都排最后）。
///
/// [SrsBrowseSortColumn.field] 的值取自 [fieldValues]（noteId → 去 HTML 的小写文本，快照按需读好）；
/// 不给时直接读笔记字段（只有完整笔记建的求值对象读得到）。
Comparable<Object>? srsBrowseSortValue(
  SrsBrowseItem item,
  SrsBrowseSort sort, {
  Map<String, String?>? fieldValues,
}) {
  final SrsCardSearchSubject p = item.primary;
  final List<SrsCardSearchSubject> cs = item.cards;
  final bool notes = cs.length > 1;
  double? avg(double? Function(SrsCardSearchSubject) f) {
    final List<double> v = <double>[
      for (final SrsCardSearchSubject c in cs)
        if (f(c) != null) f(c)!,
    ];
    return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
  }

  int sum(int Function(SrsCardSearchSubject) f) =>
      cs.fold<int>(0, (int s, SrsCardSearchSubject c) => s + f(c));

  switch (sort.column) {
    case SrsBrowseSortColumn.sortField:
      return p.sortText.toLowerCase();
    case SrsBrowseSortColumn.field:
      if (fieldValues != null) return fieldValues[p.note.id];
      final String? name = sort.fieldName?.toLowerCase();
      if (name == null) return null;
      for (final SrsFieldDef f in p.noteType.fields) {
        if (f.name.toLowerCase() == name) {
          return ankiStripHtml(p.note.field(f.id)).trim().toLowerCase();
        }
      }
      return null;
    case SrsBrowseSortColumn.due:
      // 笔记模式取最早到期的一张；新卡（infinity）排在有到期日的卡后面。
      final double due = cs
          .map((SrsCardSearchSubject c) => c.dueSortKey)
          .reduce((double a, double b) => a < b ? a : b);
      return due;
    case SrsBrowseSortColumn.created:
      return p.note.createdAt;
    case SrsBrowseSortColumn.modified:
      int m = p.modifiedAt;
      for (final SrsCardSearchSubject c in cs) {
        final int? r = c.card.lastReviewedAt;
        if (r != null && r > m) m = r;
      }
      return m;
    case SrsBrowseSortColumn.interval:
      return notes
          ? avg((SrsCardSearchSubject c) => c.intervalDays.toDouble())
          : p.intervalDays;
    case SrsBrowseSortColumn.difficulty:
      return notes
          ? avg((SrsCardSearchSubject c) => c.difficulty)
          : p.difficulty;
    case SrsBrowseSortColumn.reps:
      return sum((SrsCardSearchSubject c) => c.reps);
    case SrsBrowseSortColumn.lapses:
      return sum((SrsCardSearchSubject c) => c.lapses);
    case SrsBrowseSortColumn.deck:
      return p.deckName.toLowerCase();
    case SrsBrowseSortColumn.noteType:
      return p.noteType.name.toLowerCase();
  }
}

/// [sort] 对应的比较器：值相同按自然顺序（笔记创建时刻、卡片序号）稳定排列；没有值的行恒在最后。
/// [fieldValues] 见 [srsBrowseSortValue]。
int Function(SrsBrowseItem, SrsBrowseItem) srsBrowseComparator(
  SrsBrowseSort sort, {
  Map<String, String?>? fieldValues,
}) {
  final Map<SrsBrowseItem, Comparable<Object>?> memo =
      <SrsBrowseItem, Comparable<Object>?>{};
  Comparable<Object>? v(SrsBrowseItem i) => memo.putIfAbsent(
    i,
    () => srsBrowseSortValue(i, sort, fieldValues: fieldValues),
  );
  return (SrsBrowseItem a, SrsBrowseItem b) {
    final Comparable<Object>? va = v(a);
    final Comparable<Object>? vb = v(b);
    int c;
    if (va == null || vb == null) {
      c = va == null && vb == null ? 0 : (va == null ? 1 : -1);
    } else {
      c = va.compareTo(vb);
      if (!sort.ascending) c = -c;
    }
    return c != 0 ? c : _naturalOrder(a.primary, b.primary);
  };
}

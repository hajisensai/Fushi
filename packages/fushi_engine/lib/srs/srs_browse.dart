/// 卡片浏览（对齐 Anki 浏览器）：一次性快照 + Anki 搜索语法筛选 + 排序 + 卡片 / 笔记两种模式。
///
/// 求值对象 [SrsCardSearchSubject] 同时给 AnkiConnect 兼容层用（findNotes / findCards），
/// 两边的搜索语义只有这一份。
library;

import 'package:fushi_anki/fushi_anki_core.dart' show ankiStripHtml;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_db_store.dart';

/// 笔记最后一次改动的时刻（全部字段键当前生效记录里 HLC 物理时刻最大的一条；没有记录 = 创建时刻）。
int srsNoteModifiedAt(SrsNoteView note) {
  int out = note.createdAt;
  for (final SrsRegister r in note.edits.registers) {
    final SrsFieldEdit? w = r.winner;
    if (w != null && w.hlc.physical > out) out = w.hlc.physical;
  }
  return out;
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

/// 一张卡（连同笔记、笔记类型）作为 Anki 搜索的求值对象。
class SrsCardSearchSubject implements SrsSearchSubject {
  SrsCardSearchSubject({
    required this.note,
    required this.noteType,
    required this.card,
    required this.deckName,
    required this.day,
    required this.nowMs,
    required this.todayDayIndex,
    int Function(String uuid)? numericId,
  }) : _numericId = numericId ?? SrsIds.ankiNumericId;

  final SrsNoteView note;
  final SrsNoteTypeView noteType;
  final SrsCardCacheRow card;
  final SrsDayContext day;
  final int nowMs;
  final int Function(String uuid) _numericId;

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
  late final int modifiedAt = srsNoteModifiedAt(note);

  /// 排序字段（笔记类型的第一个字段，与 Anki 默认 sortf = 0 一致）去 HTML 后的文本。
  late final String sortText = noteType.fields.isEmpty
      ? ''
      : ankiStripHtml(note.field(noteType.fields.first.id)).trim();

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
  /// 新卡没有到期日，排在最后（按加入顺序）。
  double get dueSortKey => switch (queue) {
    SrsQueue.newCard => double.infinity,
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

/// 浏览页的一次性数据快照（每次写操作后重新加载）。
class SrsBrowseSnapshot {
  SrsBrowseSnapshot._(this.cards, this.noteTypes);

  /// 未删除笔记的全部可见卡片（按笔记创建时刻、卡片序号）。
  final List<SrsCardSearchSubject> cards;
  final List<SrsNoteTypeView> noteTypes;

  static Future<SrsBrowseSnapshot> load(SrsDbStore store) async {
    final List<SrsNoteTypeView> types = await store.noteTypes();
    final Map<String, SrsNoteTypeView> typeById = <String, SrsNoteTypeView>{
      for (final SrsNoteTypeView t in types) t.id: t,
    };
    final Map<String, SrsNoteView> notes = <String, SrsNoteView>{
      for (final SrsNoteView n in await store.allNoteViews())
        if (n.deletedAt == null) n.id: n,
    };
    final SrsDeckTree tree = await store.deckTree();
    final SrsDayContext day = await store.dayContext();
    final (int nowMs, _) = store.now();
    final int today = day.dayIndexOf(nowMs);
    final Map<String, String> deckNames = <String, String>{};
    final List<SrsCardSearchSubject> out = <SrsCardSearchSubject>[];
    for (final SrsCardCacheRow c in await store.allCardRows()) {
      if (c.hidden) continue;
      final SrsNoteView? n = notes[c.noteId];
      final SrsNoteTypeView? t = n == null ? null : typeById[n.noteTypeId];
      if (n == null || t == null || t.deletedAt != null) continue;
      out.add(
        SrsCardSearchSubject(
          note: n,
          noteType: t,
          card: c,
          deckName: deckNames[c.deckId] ??= tree[c.deckId] == null
              ? ''
              : tree.fullName(c.deckId),
          day: day,
          nowMs: nowMs,
          todayDayIndex: today,
        ),
      );
    }
    out.sort(_naturalOrder);
    return SrsBrowseSnapshot._(out, types);
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

  /// 按 Anki 搜索语法筛选、排序。查询不合法 / 不支持时抛 [SrsSearchUnsupported]。
  List<SrsBrowseItem> query({
    String query = '',
    SrsBrowseSort sort = const SrsBrowseSort(),
    SrsBrowseMode mode = SrsBrowseMode.cards,
  }) {
    final SrsSearchNode node = parseAnkiSearch(query);
    final List<SrsCardSearchSubject> hits = <SrsCardSearchSubject>[
      for (final SrsCardSearchSubject c in cards)
        if (matchesAnkiSearch(node, c)) c,
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
    final int Function(SrsBrowseItem, SrsBrowseItem) cmp = srsBrowseComparator(
      sort,
    );
    items.sort(cmp);
    return items;
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
Comparable<Object>? srsBrowseSortValue(SrsBrowseItem item, SrsBrowseSort sort) {
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
int Function(SrsBrowseItem, SrsBrowseItem) srsBrowseComparator(
  SrsBrowseSort sort,
) {
  final Map<SrsBrowseItem, Comparable<Object>?> memo =
      <SrsBrowseItem, Comparable<Object>?>{};
  Comparable<Object>? v(SrsBrowseItem i) =>
      memo.putIfAbsent(i, () => srsBrowseSortValue(i, sort));
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

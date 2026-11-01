/// 卡片浏览（对齐 Anki 浏览器）：Anki 搜索语法筛选 + 排序 + 卡片 / 笔记两种模式。
///
/// 浏览页的数据常驻原生会话（[SrsBrowseSession] → native/fushi_fsrs/src/store/browse.rs）：搜索语料与
/// 列数据在 Rust 里、随写入增量更新，筛选与排序在 Rust 里做，Dart 只取命中行的分页。AnkiConnect 兼容层的
/// findNotes / findCards / 查重用同一个会话（[srsBrowseContext]）。
library;

import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki_core.dart' show FushiCardFields;
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

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

/// 列表模式：一行一张卡 / 一行一条笔记。
enum SrsBrowseMode { cards, notes }

/// 排序列（`name` 是浏览会话命令里的列名，native/fushi_fsrs/src/store/browse.rs `Column`）。
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

/// 全部笔记类型的字段名（去重不区分大小写，按笔记类型、字段顺序）——「按字段搜索 / 排序」的下拉选项。
List<String> srsBrowseFieldNames(List<SrsNoteTypeView> noteTypes) {
  final Set<String> seen = <String>{};
  final List<String> out = <String>[];
  for (final SrsNoteTypeView t in noteTypes) {
    for (final SrsFieldDef f in t.fields) {
      if (seen.add(f.name.toLowerCase())) out.add(f.name);
    }
  }
  return out;
}

/// 浏览列表的一行（列表 / 预览要显示的列）。卡片模式是一张卡；笔记模式是一条笔记，主卡 [cardId] 是命中
/// 搜索的第一张，[cardCount] 是该笔记的全部可见卡数。
class SrsBrowseRow {
  const SrsBrowseRow({
    required this.cardId,
    required this.noteId,
    required this.sortText,
    required this.deckName,
    required this.deckId,
    required this.noteTypeName,
    required this.templateName,
    required this.queue,
    required this.dueInDays,
    required this.flag,
    required this.isSuspended,
    required this.isBuried,
    required this.hasPendingDecision,
    required this.cardCount,
    required this.tags,
    required this.reps,
    required this.lapses,
  });

  final String cardId;
  final String noteId;

  /// 排序字段去 HTML、trim 后的文本。
  final String sortText;
  final String deckName;
  final String deckId;
  final String noteTypeName;

  /// 主卡的模板名（模板被删了为空串）。
  final String templateName;

  /// 主卡的队列；null = 这一行的卡在取行之前已被删掉（列表下次刷新时消失）。
  final SrsQueue? queue;

  /// 到期天数（Anki 浏览器的「到期」列口径）；null = 没有到期日（新卡 / 按此刻回忆率排队的复习卡）。
  final int? dueInDays;
  final int flag;
  final bool isSuspended;
  final bool isBuried;

  /// 笔记有内容类待裁决。
  final bool hasPendingDecision;
  final int cardCount;
  final List<String> tags;

  /// 主卡的复习 / 遗忘次数。
  final int reps;
  final int lapses;

  bool get isNew => queue == SrsQueue.newCard;
  bool get gone => queue == null;
}

/// 批量操作的目标（[SrsBrowseResult.targets]）。
class SrsBrowseTargets {
  const SrsBrowseTargets({
    required this.cardIds,
    required this.noteIds,
    required this.allSuspended,
    required this.allBuried,
    required this.flags,
    required this.deckIds,
  });

  /// 目标行的全部卡（笔记模式展开成该笔记的全部可见卡），按列表顺序。
  final List<String> cardIds;
  final List<String> noteIds;
  final bool allSuspended;
  final bool allBuried;
  final Set<int> flags;
  final Set<String> deckIds;

  bool get isEmpty => cardIds.isEmpty && noteIds.isEmpty;
}

/// 浏览结果一次取的行数。
const int kSrsBrowsePage = 200;

/// 一次查询的结果：行留在原生会话里（native/fushi_fsrs/src/store/browse.rs），这里按页取、取过的缓存。
/// 会话在这次查询之后又被别的查询换掉时取行会失败（[SrsBrowseResultGone]），调用方重新查询。
class SrsBrowseResult {
  SrsBrowseResult._(this._session, this.gen, this.length, this.mode);

  final SrsBrowseSession _session;

  /// 原生侧的结果代号。
  final int gen;
  final int length;
  final SrsBrowseMode mode;
  final Map<int, SrsBrowseRow> _rows = <int, SrsBrowseRow>{};
  final Map<int, Future<void>> _loading = <int, Future<void>>{};

  /// 已取到的第 [index] 行；还没取时 null（用 [ensure] 取）。
  SrsBrowseRow? rowAt(int index) => _rows[index];

  /// 行 id：卡片模式是主卡 id，笔记模式是笔记 id。
  String idOf(SrsBrowseRow row) =>
      mode == SrsBrowseMode.cards ? row.cardId : row.noteId;

  /// 取好 [from]..[to] 覆盖的那几页。
  Future<void> ensure(int from, int to) async {
    final int a = (from < 0 ? 0 : from) ~/ kSrsBrowsePage;
    final int last = to > length ? length : to;
    if (last <= 0) return;
    final int b = (last - 1) ~/ kSrsBrowsePage;
    await Future.wait(<Future<void>>[for (int p = a; p <= b; p++) _page(p)]);
  }

  Future<void> _page(int p) {
    if (_rows.containsKey(p * kSrsBrowsePage)) return Future<void>.value();
    return _loading[p] ??= () async {
      try {
        final int from = p * kSrsBrowsePage;
        final int to = from + kSrsBrowsePage > length
            ? length
            : from + kSrsBrowsePage;
        final List<SrsBrowseRow> rows = await _session._rows(gen, from, to);
        for (int i = 0; i < rows.length; i++) {
          _rows[from + i] = rows[i];
        }
      } finally {
        _loading.remove(p);
      }
    }();
  }

  /// 第 [from]..[to] 行（取不到的先取）。
  Future<List<SrsBrowseRow>> rows(int from, int to) async {
    final int end = to > length ? length : to;
    await ensure(from, end);
    return <SrsBrowseRow>[for (int i = from; i < end; i++) _rows[i]!];
  }

  /// 全部行（测试 / 控制通道这类要整份结果的地方用；浏览页按页取）。
  Future<List<SrsBrowseRow>> all() => rows(0, length);

  /// 丢掉取过的行（写入之后重新取可见的那几行）。
  void invalidateRows() => _rows.clear();

  /// 第 [from]..[to] 行的行 id（[to] 省略 = 到末尾）。
  Future<List<String>> ids([int from = 0, int? to]) =>
      _session._ids(gen, from, to ?? length);

  /// [ids] 各在第几行（不在结果里 = -1）。
  Future<List<int>> indicesOf(List<String> ids) => ids.isEmpty
      ? Future<List<int>>.value(const <int>[])
      : _session._find(gen, ids);

  /// [rowIds] 那几行的批量操作目标（按列表顺序展开）。
  Future<SrsBrowseTargets> targets(Iterable<String> rowIds) =>
      _session._targets(gen, rowIds.toList());
}

/// 结果已被原生会话换掉（又查询过一次、或会话重建了）：重新查询。
class SrsBrowseResultGone implements Exception {
  const SrsBrowseResultGone(this.reason);

  final String reason;

  @override
  String toString() => 'SrsBrowseResultGone: $reason';
}

/// 浏览会话查询的上下文：笔记类型（字段、别名、模板）、牌组有效全名与是否按 RWKV 回忆率排队、此刻与日界、
/// RWKV 此刻会出的卡（[rwkvInstant] 为假时不带：`is:due` 照存下的到期日，AnkiConnect 的口径）。只与笔记类型 /
/// 牌组数有关（RWKV 那份与它的到期卡数有关）。影响原生语料结构的部分（笔记类型、牌组名与排队方式）两种口径
/// 相同，浏览页与 AnkiConnect 交替查询不会让语料重建。
Future<Map<String, Object?>> srsBrowseContext(
  SrsDbStore store, {
  bool rwkvInstant = true,
}) async {
  final List<SrsNoteTypeView> types = await store.noteTypes();
  final SrsDeckTree tree = await store.deckTree();
  final SrsDayContext day = await store.dayContext();
  final (int nowMs, _) = store.now();
  final Set<String>? instant = rwkvInstant
      ? await store.instantDueCardIds()
      : null;
  bool recall(String deckId) =>
      (!rwkvInstant || instant != null) && store.instantActiveFor(tree, deckId);
  // 牌组已不存在的卡归默认牌组（与排程配置同一判据）：显示为默认牌组、`deck:Default` 能筛到（BUG-3617）。
  const String missing = '\u0000';
  return <String, Object?>{
    'now': nowMs,
    'utcOff': day.utcOffsetMin,
    'rollover': day.rolloverHour,
    'types': <Object?>[
      for (final SrsNoteTypeView t in types)
        <String, Object?>{
          'id': t.id,
          'name': t.name,
          'cloze': t.isCloze,
          'deleted': t.deletedAt != null,
          'fields': <Object?>[
            for (final SrsFieldDef f in t.fields)
              <Object?>[
                f.id,
                f.name,
                if (t.builtinKey == kSrsBuiltinFushiCardKey)
                  FushiCardFields.aliasOf(f.name),
              ],
          ],
          'tpls': <Object?>[
            for (final SrsTemplateDef p in t.templates)
              <Object?>[p.id, p.name, p.ord],
          ],
        },
    ],
    'decks': <String, Object?>{
      for (final SrsDeckView d in tree.decks)
        d.id: <Object?>[
          tree.effectiveDeckNameOf(d.id, fallback: store.defaultDeckId),
          recall(d.id),
        ],
    },
    'fallback': <Object?>[
      tree.effectiveDeckNameOf(missing, fallback: store.defaultDeckId),
      recall(missing),
    ],
    if (instant != null) 'instant': instant.toList(),
  };
}

/// 浏览会话查询（`browse_query` / `anki_find`）的回答：求值出错（查询不合法 / 内核不可用）时抛
/// [SrsSearchUnsupported]，否则原样交回。
Map<String, Object?> srsBrowseCheckResult(
  Map<String, Object?> r,
  String query,
) {
  if (r['error'] case final Object error) {
    final String at = (r['at'] as String?) ?? '';
    throw SrsSearchUnsupported(
      at.isEmpty ? query : at,
      '$error',
      r['kind'] == 'syntax'
          ? SrsSearchErrorKind.syntax
          : SrsSearchErrorKind.unavailable,
    );
  }
  return r;
}

/// 一个浏览页的会话：搜索语料与列数据常驻原生侧（按 profile，随写入增量更新），这里只发查询、取行。
///
/// 一次查询 = 一条命令（筛选 + 排序在 Rust 里做完，只回行数）；取一页行 = 一条命令（列式）。字段原文、
/// 笔记最后改动时刻只在查询 / 按字段排序真用到时由原生侧从修改记录读一次，之后常驻。页面关掉时 [close]
/// 释放原生侧内存。
class SrsBrowseSession {
  SrsBrowseSession(this.store) : _owner = 'page:${_owners++}';

  final SrsDbStore store;

  static int _owners = 0;

  /// 本页面实例在原生会话上的持有者名：会话与 AnkiConnect 共用，[close] 只注销自己，最后一个持有者注销才释放。
  final String _owner;

  /// 最近一次查询的结果（[query] 的 `since`：没有写入、条件没变时原生侧直接回同一份）。
  SrsBrowseResult? _last;

  /// 按 Anki 搜索语法筛选、排序。查询不合法 / 不支持 / 内核不可用时抛 [SrsSearchUnsupported]。
  /// [reuse]：条件与上次相同且之后没有写入时直接给回上次的结果（[SrsBrowseResult] 同一个对象，行缓存保留）。
  Future<SrsBrowseResult> query({
    String query = '',
    SrsBrowseSort sort = const SrsBrowseSort(),
    SrsBrowseMode mode = SrsBrowseMode.cards,
    bool reuse = false,
  }) async {
    final SrsSearchNode node = parseAnkiSearch(query);
    final SrsBrowseResult? last = _last;
    final Map<String, Object?> r = srsBrowseCheckResult(
      (await store.browseCommand(<String, Object?>{
        'op': 'browse_query',
        'owner': _owner,
        ...await srsBrowseContext(store),
        if (node is! SrsSearchAll) 'node': srsSearchNodeJson(node),
        'sort': <String, Object?>{
          'col': sort.column.name,
          'asc': sort.ascending,
          'field': ?sort.fieldName,
        },
        'mode': mode.name,
        if (reuse && last != null && last.mode == mode) 'since': last.gen,
      })).map,
      query,
    );
    if (r['same'] == true && last != null && last.gen == r['gen']) {
      return last;
    }
    return _last = SrsBrowseResult._(
      this,
      r['gen']! as int,
      r['count']! as int,
      mode,
    );
  }

  /// 注销本页面对原生会话的持有；没有别的持有者（AnkiConnect、别的页面）时会话随之释放（字段文本可达几百 MB），
  /// 之后再 [query] 会重新建。库已经关了（页面 dispose 时发出的
  /// 关闭排在关库之后）就什么都不用做：会话住在内核里，随内核一起释放了。
  Future<void> close() async {
    _last = null;
    if (store.isClosed) return;
    try {
      await store.browseCommand(<String, Object?>{
        'op': 'browse_close',
        'owner': _owner,
      });
    } on SrsCoreException catch (e) {
      if (!e.message.contains('store is closed')) rethrow;
    }
  }

  Future<SrsSync2Result> _command(Map<String, Object?> request) async {
    try {
      return await store.browseCommand(<String, Object?>{
        ...request,
        'owner': _owner,
      });
    } on Object catch (e) {
      if ('$e'.contains('browse: result') ||
          '$e'.contains('browse: no session')) {
        throw SrsBrowseResultGone('$e');
      }
      rethrow;
    }
  }

  Future<List<SrsBrowseRow>> _rows(int gen, int from, int to) async {
    final SrsSync2Result r = await _command(<String, Object?>{
      'op': 'browse_rows',
      'gen': gen,
      'from': from,
      'to': to,
    });
    final List<Object?> s = r.map['s']! as List<Object?>;
    final Uint8List bytes = r.files
        .firstWhere(((String, Uint8List) f) => f.$1 == 'rows.i64')
        .$2;
    final ByteData ints = ByteData.sublistView(bytes);
    const int width = 7;
    const int none = -0x8000000000000000;
    return <SrsBrowseRow>[
      for (int i = 0; i < s.length; i++)
        () {
          final List<Object?> t = s[i]! as List<Object?>;
          int at(int k) => ints.getInt64((i * width + k) * 8, Endian.little);
          final int q = at(0);
          final int due = at(1);
          final int bits = at(3);
          return SrsBrowseRow(
            cardId: t[0]! as String,
            noteId: t[1]! as String,
            sortText: t[2]! as String,
            deckName: t[3]! as String,
            noteTypeName: t[4]! as String,
            deckId: t[5]! as String,
            templateName: t[6]! as String,
            queue: q < 0 ? null : SrsQueue.values[q],
            dueInDays: due == none ? null : due,
            flag: at(2),
            isSuspended: bits & 1 != 0,
            isBuried: bits & 2 != 0,
            hasPendingDecision: bits & 4 != 0,
            cardCount: at(4),
            tags: <String>[
              for (final Object? tag in t[7]! as List<Object?>) tag! as String,
            ],
            reps: at(5),
            lapses: at(6),
          );
        }(),
    ];
  }

  Future<List<String>> _ids(int gen, int from, int to) async {
    final SrsSync2Result r = await _command(<String, Object?>{
      'op': 'browse_ids',
      'gen': gen,
      'from': from,
      'to': to,
    });
    return <String>[
      for (final Object? id in r.map['ids']! as List<Object?>) id! as String,
    ];
  }

  Future<List<int>> _find(int gen, List<String> ids) async {
    final SrsSync2Result r = await _command(<String, Object?>{
      'op': 'browse_ids',
      'gen': gen,
      'find': ids,
    });
    return <int>[
      for (final Object? i in r.map['at']! as List<Object?>) i! as int,
    ];
  }

  Future<SrsBrowseTargets> _targets(int gen, List<String> ids) async {
    if (ids.isEmpty) {
      return const SrsBrowseTargets(
        cardIds: <String>[],
        noteIds: <String>[],
        allSuspended: true,
        allBuried: true,
        flags: <int>{},
        deckIds: <String>{},
      );
    }
    final Map<String, Object?> r = (await _command(<String, Object?>{
      'op': 'browse_targets',
      'gen': gen,
      'ids': ids,
    })).map;
    List<String> strings(String k) => <String>[
      for (final Object? v in r[k]! as List<Object?>) v! as String,
    ];
    return SrsBrowseTargets(
      cardIds: strings('cards'),
      noteIds: strings('notes'),
      allSuspended: r['allSuspended']! as bool,
      allBuried: r['allBuried']! as bool,
      flags: <int>{
        for (final Object? f in r['flags']! as List<Object?>) f! as int,
      },
      deckIds: strings('decks').toSet(),
    );
  }
}

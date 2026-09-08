/// Anki 卡组新卡按词频重排——**纯函数层**（无 I/O、无引擎依赖，可直接单测）。
///
/// 数据流：卡组新卡 → 每张卡所属 note 的表达式 / 读音 / 词频字段 → rank →
/// 稳定排序 → 连续位置。I/O（取卡、查引擎、快照、写回）在
/// `anki_deck_reposition_runner.dart`。
library;

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart' show katakanaToHiragana;
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 查引擎：一个表达式 → 引擎返回的全部词条（各自带全部已装载词典的词频）。
/// 生产实现是 `FushiDicts.instance.query`；测试注入假表。
typedef AnkiFrequencyLookup = List<FushiTermResult> Function(String expression);

/// 重排的词频取值选项。
class AnkiRepositionRankOptions {
  const AnkiRepositionRankOptions({
    this.source = AnkiRepositionSource.dictionaries,
    this.dictionaries = const <String>{},
    this.aggregate = FrequencyAggregate.harmonic,
    this.rareFirst = false,
  });

  factory AnkiRepositionRankOptions.fromSettings(AnkiSettings settings) =>
      AnkiRepositionRankOptions(
        source: settings.repositionSource,
        dictionaries: settings.repositionDictionaries.toSet(),
        aggregate: FrequencyAggregate.fromName(settings.repositionAggregate),
      );

  final AnkiRepositionSource source;

  /// 勾选的词频词典名；**空 = 引擎里全部**。
  final Set<String> dictionaries;
  final FrequencyAggregate aggregate;

  /// 罕见词优先（默认常见词优先）。
  final bool rareFirst;

  AnkiRepositionRankOptions copyWith({
    AnkiRepositionSource? source,
    Set<String>? dictionaries,
    FrequencyAggregate? aggregate,
    bool? rareFirst,
  }) =>
      AnkiRepositionRankOptions(
        source: source ?? this.source,
        dictionaries: dictionaries ?? this.dictionaries,
        aggregate: aggregate ?? this.aggregate,
        rareFirst: rareFirst ?? this.rareFirst,
      );

  bool acceptsDictionary(String dictName) =>
      dictionaries.isEmpty || dictionaries.contains(dictName);
}

/// 一个笔记类型里三种角色各落在哪个字段（找不到为 null）。
class AnkiNoteFieldRoles {
  const AnkiNoteFieldRoles({this.expression, this.reading, this.rank});

  final String? expression;
  final String? reading;

  /// 映射为 `{frequency-harmonic-rank}` 的字段（Lapis 的 FreqSort）。
  final String? rank;
}

const String _kExpressionToken = '{expression}';
const String _kReadingToken = '{reading}';
const String _kRankToken = '{frequency-harmonic-rank}';

/// 解析 [modelName] 这个笔记类型里各角色对应的字段名。
///
/// 优先级：当前制卡笔记类型的用户映射（[AnkiSettings.fieldMappings]）→ Lapis
/// 出厂映射（字段名对得上就用）→ 常见字段名 → 第一个字段当表达式。
/// 卡组里往往混着别的笔记类型（Yomitan 制的、手写的），逐级兜底是为了尽量
/// 多给出表达式而不是整批判「无词频」。
AnkiNoteFieldRoles resolveNoteFieldRoles({
  required String modelName,
  required Iterable<String> fieldNames,
  required AnkiSettings settings,
}) {
  final List<String> names = fieldNames.toList();
  if (names.isEmpty) return const AnkiNoteFieldRoles();
  final Set<String> nameSet = names.toSet();

  String? byToken(Map<String, String> mappings, String token) {
    for (final MapEntry<String, String> e in mappings.entries) {
      if (nameSet.contains(e.key) && e.value.contains(token)) return e.key;
    }
    return null;
  }

  String? expression;
  String? reading;
  String? rank;
  if (modelName.isNotEmpty && modelName == settings.selectedNoteTypeName) {
    expression = byToken(settings.fieldMappings, _kExpressionToken);
    reading = byToken(settings.fieldMappings, _kReadingToken);
    rank = byToken(settings.fieldMappings, _kRankToken);
  }
  expression ??= byToken(LapisNoteType.defaultFieldMappings, _kExpressionToken);
  reading ??= byToken(LapisNoteType.defaultFieldMappings, _kReadingToken);
  rank ??= byToken(LapisNoteType.defaultFieldMappings, _kRankToken);

  String? firstNamed(List<String> candidates) {
    for (final String c in candidates) {
      for (final String n in names) {
        if (n.toLowerCase() == c) return n;
      }
    }
    return null;
  }

  expression ??= firstNamed(const <String>[
        'expression',
        'word',
        'term',
        'vocab',
        'vocabulary',
        'front',
        'target word',
      ]) ??
      names.first;
  reading ??=
      firstNamed(const <String>['reading', 'expressionreading', 'kana']);
  rank ??= firstNamed(const <String>['freqsort', 'frequencysort', 'freq']);
  return AnkiNoteFieldRoles(
      expression: expression, reading: reading, rank: rank);
}

/// 把 Anki 字段 HTML 折成纯文本：去 ruby 注音（`<rt>` 内容整段丢）、去标签、
/// 解实体、折叠空白。
String ankiFieldPlainText(String html) {
  String s = html.replaceAll(RegExp(r'<rt>.*?</rt>', dotAll: true), '');
  s = s.replaceAll(RegExp(r'<rp>.*?</rp>', dotAll: true), '');
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  s = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 片假名折成平假名，供读音比对。
String _foldKana(String s) => String.fromCharCodes(
      s.runes.map<int>((int cp) => katakanaToHiragana(cp)),
    );

/// 从 `{frequency-harmonic-rank}` 字段值里取正整数 rank（前导数字）。
int? parseFieldRank(String raw) {
  final String text = ankiFieldPlainText(raw);
  return frequencyRankOf(0, text);
}

/// 按词典查一张卡的复合 rank。
///
/// [reading] 非空且有读音相同的词条时只看那些词条（同形异读各有各的词频），
/// 否则看全部命中。每本勾选词典在这些词条里取最小值，再按 [options.aggregate]
/// 复合；一本都没值返回 null。
int? dictionaryRankFor({
  required String expression,
  required String reading,
  required AnkiRepositionRankOptions options,
  required AnkiFrequencyLookup lookup,
}) {
  if (expression.isEmpty) return null;
  List<FushiTermResult> results = lookup(expression);
  if (results.isEmpty) return null;
  if (reading.isNotEmpty) {
    final String want = _foldKana(reading);
    final List<FushiTermResult> sameReading = <FushiTermResult>[
      for (final FushiTermResult r in results)
        if (_foldKana(r.reading) == want) r,
    ];
    if (sameReading.isNotEmpty) results = sameReading;
  }
  final Map<String, int> perDict = <String, int>{};
  for (final FushiTermResult r in results) {
    for (final FushiFrequencyEntry f in r.frequencies) {
      if (!options.acceptsDictionary(f.dictName)) continue;
      final int? rank = dictionaryFrequencyRank(f.frequencies);
      if (rank == null) continue;
      final int? prev = perDict[f.dictName];
      if (prev == null || rank < prev) perDict[f.dictName] = rank;
    }
  }
  return aggregateFrequencyRanks(perDict.values.toList(), options.aggregate);
}

/// 一张待排的卡：原始信息 + 算出来的 rank + 给预览看的表达式。
class AnkiRepositionCard {
  const AnkiRepositionCard({
    required this.card,
    required this.expression,
    required this.rank,
  });

  final AnkiCardInfo card;
  final String expression;

  /// null = 无词频（排到末尾，保持原相对顺序）。
  final int? rank;
}

/// 一次重排的计划：排好序的卡 + 要写回的位置。
class AnkiRepositionPlan {
  const AnkiRepositionPlan({
    required this.deckName,
    required this.ordered,
    required this.updates,
    required this.previous,
  });

  final String deckName;
  final List<AnkiRepositionCard> ordered;

  /// 新位置（与 [ordered] 同序）。
  final List<AnkiCardDueUpdate> updates;

  /// 写回前的旧位置（撤销用）。
  final List<AnkiCardDueUpdate> previous;

  int get total => ordered.length;
  int get ranked =>
      ordered.where((AnkiRepositionCard c) => c.rank != null).length;
  int get unranked => total - ranked;

  /// 位置真的变了的卡数（全都没变就没必要写）。
  int get changed {
    int n = 0;
    for (int i = 0; i < updates.length; i++) {
      if (updates[i].due != previous[i].due) n++;
    }
    return n;
  }
}

/// 给 [cards] 排位置（纯函数）。
///
/// 排序键：有 rank 的在前（rank 升序；[rareFirst] 时降序）→ 同 note 的多张卡
/// 相邻（按 note 首次出现顺序）→ 同 note 内按模板序号。无 rank 的整体排末尾，
/// 保持传入的相对顺序。位置从 [startPosition] 起连续编号。
///
/// 稳定：同 rank 的 note 按传入顺序（调用方按旧 `due` 升序传入，于是同频词
/// 保持用户原有次序，重排不会无谓打乱）。
AnkiRepositionPlan planCardPositions(
  String deckName,
  List<AnkiRepositionCard> cards, {
  bool rareFirst = false,
  int startPosition = 1,
}) {
  final Map<int, int> noteOrder = <int, int>{};
  for (final AnkiRepositionCard c in cards) {
    noteOrder.putIfAbsent(c.card.noteId, () => noteOrder.length);
  }
  final List<AnkiRepositionCard> ordered = List<AnkiRepositionCard>.of(cards);
  // Dart 的 List.sort 不保证稳定；(rank, note 首现序, ord) 是完整键，没有
  // 两张卡比出 0，于是结果与稳定排序等价。
  ordered.sort((AnkiRepositionCard a, AnkiRepositionCard b) {
    final int primary = _compareRank(a.rank, b.rank, rareFirst);
    if (primary != 0) return primary;
    final int byNote =
        noteOrder[a.card.noteId]!.compareTo(noteOrder[b.card.noteId]!);
    if (byNote != 0) return byNote;
    return a.card.ord.compareTo(b.card.ord);
  });
  final List<AnkiCardDueUpdate> updates = <AnkiCardDueUpdate>[];
  final List<AnkiCardDueUpdate> previous = <AnkiCardDueUpdate>[];
  for (int i = 0; i < ordered.length; i++) {
    final AnkiCardInfo card = ordered[i].card;
    updates.add(AnkiCardDueUpdate(cardId: card.cardId, due: startPosition + i));
    previous.add(AnkiCardDueUpdate(cardId: card.cardId, due: card.due));
  }
  return AnkiRepositionPlan(
    deckName: deckName,
    ordered: ordered,
    updates: updates,
    previous: previous,
  );
}

int _compareRank(int? a, int? b, bool rareFirst) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return rareFirst ? b.compareTo(a) : a.compareTo(b);
}

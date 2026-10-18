/// Anki 搜索语法子集的语法树、错误类型与求值对象接口。
///
/// 解析见 `search_parser.dart`（照 rslib `search/parser.rs`），求值见
/// `search_matcher.dart`（语义照 rslib `search/sqlwriter.rs`）。
library;

import 'search_text.dart';

/// 解析失败的类别。
enum SrsSearchErrorKind {
  /// 查询本身不合法（Anki 同样会报错，如括号不配对、`is:foo`、非法转义）。
  syntax,

  /// 合法的 Anki 语法，但本子集不支持（如 `rated:`、`prop:ease`、`nc:`）。
  unsupported,
}

/// 搜索无法按 Anki 语义求值时抛出——**绝不静默退化成空集或全集**：查重靠
/// `findNotes` 的结果判「是否已存在」，退化会把重复判成不重复。
class SrsSearchUnsupported implements Exception {
  const SrsSearchUnsupported(this.query, this.reason, this.kind);

  /// 出错的那段查询文本（或整条查询）。
  final String query;
  final String reason;
  final SrsSearchErrorKind kind;

  @override
  String toString() => 'SrsSearchUnsupported(${kind.name}): $reason [$query]';
}

/// 被求值的一张卡（连同它所属的笔记）。求值不碰数据库，全部取自这里。
///
/// findNotes 语义 = 「笔记的任一张卡命中」，由调用方对每张卡求值后归并。
abstract interface class SrsSearchSubject {
  /// 牌组全路径，层级用 `::` 分隔（`日本語::語彙`）。
  String get deckName;

  /// 笔记类型名。
  String get noteTypeName;

  /// 字段名 → 字段值（原始 HTML），按笔记类型的字段顺序。
  Map<String, String> get fields;

  /// 标签（层级标签用 `::`，如 `verb::ichidan`）。
  List<String> get tags;

  /// `is:new`：从未学过。
  bool get isNew;

  /// `is:learn`：学习中或重学中（Anki：type ∈ {learn, relearn}）。
  bool get isLearn;

  /// `is:review`：复习卡或重学中（Anki：type ∈ {review, relearn}）。
  bool get isReview;

  /// `is:due`：今天到期（复习 / 跨日学习 due ≤ 今天，或学习中 due ≤ 现在 + 提前量）。
  bool get isDue;

  /// `is:suspended`：已暂停。
  bool get isSuspended;

  /// 笔记 id（53 位以内整数）。
  int get noteId;

  /// 卡片 id（53 位以内整数）。
  int get cardId;

  /// 卡片加入那天的排程日序号（与 [todayDayIndex] 同一套日界）。
  int get addedDayIndex;

  /// 今天的排程日序号。
  int get todayDayIndex;

  /// `flag:N`：旗标（0 = 无，1–7 与 Anki 同序）。
  int get flag;

  /// `is:buried`：被手动搁置、还没到解除那天。
  bool get isBuried;

  /// `card:N`：卡片序号，从 1 起（普通笔记 = 模板序号 + 1；填空 = 填空编号）。
  int get cardOrdinal;

  /// `card:名`：模板名。
  String get templateName;

  /// `prop:ivl`：当前间隔（天；新卡 / 学习中为 0，与 Anki 的 `c.ivl` 同口径）。
  int get intervalDays;

  /// `prop:due`：距今天的到期天数（复习卡 = 到期日 - 今天；学习中 = 到期时刻减明天日界
  /// 按天截断）；新卡没有到期日，返回 null（不命中任何 `prop:due`）。
  int? get dueInDays;

  /// `prop:reps`：复习次数。
  int get reps;

  /// `prop:lapses`：遗忘次数。
  int get lapses;

  /// `prop:s`：FSRS 稳定性（天）；没有记忆状态返回 null。
  double? get stability;

  /// `prop:d`：FSRS 难度（内核原值 1–10）；没有记忆状态返回 null。
  double? get difficulty;

  /// `edited:N`：笔记最后一次改动那天的排程日序号。
  int get editedDayIndex;
}

/// 搜索语法树。叶子节点里的文本保留 Anki 的通配转义（`\*` `\_` `\\`），
/// 已解掉解析器层面的转义（`\"` `\:` `\(` `\)` `\-`）。
sealed class SrsSearchNode {
  const SrsSearchNode();
}

/// 空查询：整个集合（与 Anki 一致，`findNotes("")` 返回全部）。
final class SrsSearchAll extends SrsSearchNode {
  const SrsSearchAll();
}

final class SrsSearchAnd extends SrsSearchNode {
  const SrsSearchAnd(this.children);
  final List<SrsSearchNode> children;
}

final class SrsSearchOr extends SrsSearchNode {
  const SrsSearchOr(this.children);
  final List<SrsSearchNode> children;
}

final class SrsSearchNot extends SrsSearchNode {
  const SrsSearchNot(this.child);
  final SrsSearchNode child;
}

/// `re:正则`：在全部字段原文（0x1f 连接）里做正则搜索，默认不区分大小写。
final class SrsSearchRegex extends SrsSearchNode {
  SrsSearchRegex(this.source, this.pattern);
  final String source;
  final RegExp pattern;
}

/// `字段名:re:正则`：字段名通配；值按正则在字段原文里搜索（不锚定，默认不区分大小写）。
final class SrsSearchFieldRegex extends SrsSearchNode {
  SrsSearchFieldRegex(this.field, this.source, this.pattern)
    : fieldPattern = ankiGlobRegExp(field);
  final String field;
  final String source;
  final RegExp pattern;
  final RegExp fieldPattern;
}

/// 裸词：在全部字段（原文）里做包含匹配，支持 `*` / `_`。
final class SrsSearchText extends SrsSearchNode {
  SrsSearchText(this.text) : pattern = ankiGlobRegExp(text, anchored: false);
  final String text;
  final RegExp pattern;
}

/// `字段名:值`：字段名不区分大小写、可通配；值整值匹配、可通配。
final class SrsSearchField extends SrsSearchNode {
  SrsSearchField(this.field, this.text)
    : fieldPattern = ankiGlobRegExp(field),
      valuePattern = ankiGlobRegExp(text);
  final String field;
  final String text;
  final RegExp fieldPattern;
  final RegExp valuePattern;
}

/// `deck:名`：匹配该牌组及其全部子牌组；`deck:*` 匹配全部。
final class SrsSearchDeck extends SrsSearchNode {
  SrsSearchDeck(this.deck)
    : pattern = deck == '*'
          ? null
          : RegExp(
              '^${ankiGlobToRegExpSource(deck)}(?:\$|::)',
              caseSensitive: false,
              unicode: true,
              dotAll: true,
            );
  final String deck;
  final RegExp? pattern;
}

/// `note:笔记类型名`。
final class SrsSearchNoteType extends SrsSearchNode {
  SrsSearchNoteType(this.name) : pattern = ankiGlobRegExp(name);
  final String name;
  final RegExp pattern;
}

/// `tag:标签`：匹配该标签及其子标签（`tag:a` 命中 `a`、`a::b`，不命中 `ab`）；
/// `tag:none` 无标签；`tag:*` 全部。
final class SrsSearchTag extends SrsSearchNode {
  SrsSearchTag(this.tag)
    : pattern = RegExp(
        ' ${ankiGlobToRegExpSource(tag, wildcard: r'\S')}(?:::| )',
        caseSensitive: false,
        unicode: true,
      );
  final String tag;
  final RegExp pattern;
}

enum SrsSearchCardState { isNew, learn, review, due, suspended, buried }

/// `is:new` / `is:learn` / `is:review` / `is:due` / `is:suspended` /
/// `is:buried`（= `is:buried-manually`；本实现没有兄弟卡自动搁置）。
final class SrsSearchState extends SrsSearchNode {
  const SrsSearchState(this.state);
  final SrsSearchCardState state;
}

/// `nid:1,2,3`。
final class SrsSearchNoteIds extends SrsSearchNode {
  SrsSearchNoteIds(Iterable<int> ids) : ids = Set<int>.unmodifiable(ids);
  final Set<int> ids;
}

/// `cid:1,2,3`。
final class SrsSearchCardIds extends SrsSearchNode {
  SrsSearchCardIds(Iterable<int> ids) : ids = Set<int>.unmodifiable(ids);
  final Set<int> ids;
}

/// `added:N`：最近 N 天（含今天）加入的卡；N 至少为 1。
final class SrsSearchAddedInDays extends SrsSearchNode {
  const SrsSearchAddedInDays(this.days);
  final int days;
}

/// `flag:N`（0–7）。
final class SrsSearchFlag extends SrsSearchNode {
  const SrsSearchFlag(this.flag);
  final int flag;
}

/// `card:N`（从 1 起的卡片序号）或 `card:模板名`（通配）。
final class SrsSearchCardTemplate extends SrsSearchNode {
  SrsSearchCardTemplate.ordinal(int this.ordinal) : name = null, pattern = null;
  SrsSearchCardTemplate.named(String this.name)
    : ordinal = null,
      pattern = ankiGlobRegExp(name);
  final int? ordinal;
  final String? name;
  final RegExp? pattern;
}

/// `edited:N`：最近 N 天（含今天）改过内容的笔记；N 至少为 1。
final class SrsSearchEditedInDays extends SrsSearchNode {
  const SrsSearchEditedInDays(this.days);
  final int days;
}

/// `prop:` 支持的属性。
enum SrsSearchProperty {
  /// `ivl`：间隔（天，整数）。
  interval,

  /// `due`：距今天的到期天数（整数，可为负）。
  due,

  /// `reps`：复习次数（整数）。
  reps,

  /// `lapses`：遗忘次数（整数）。
  lapses,

  /// `s`：FSRS 稳定性（天，小数）。
  stability,

  /// `d`：FSRS 难度，0–1（Anki 口径：(内核难度 - 1) / 9）。
  difficulty,
}

/// `prop:` 的比较符。
enum SrsSearchCompare { eq, ne, lt, le, gt, ge }

/// `prop:属性 比较符 数值`，如 `prop:ivl>=10`、`prop:due=1`、`prop:d>0.8`。
final class SrsSearchProp extends SrsSearchNode {
  const SrsSearchProp(this.property, this.compare, this.value);
  final SrsSearchProperty property;
  final SrsSearchCompare compare;
  final num value;
}

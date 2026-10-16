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

  /// 合法的 Anki 语法，但本子集不支持（如 `prop:`、`flag:`、`re:`）。
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

enum SrsSearchCardState { isNew, learn, review, due, suspended }

/// `is:new` / `is:learn` / `is:review` / `is:due` / `is:suspended`。
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

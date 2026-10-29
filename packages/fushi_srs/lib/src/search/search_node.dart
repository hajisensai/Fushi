/// Anki 搜索语法子集的语法树、错误类型与求值对象接口。
///
/// 解析见 `search_parser.dart`（照 rslib `search/parser.rs`）；求值在原生内核
/// native/fushi_fsrs/src/search.rs（语义照 rslib `search/sqlwriter.rs`，正则用与 Anki 相同的
/// Rust `regex` crate），Dart 入口 `search_corpus.dart`。
library;

/// 解析失败的类别。
enum SrsSearchErrorKind {
  /// 查询本身不合法（Anki 同样会报错，如括号不配对、`is:foo`、非法转义）。
  syntax,

  /// 合法的 Anki 语法，但本子集不支持（如 `rated:`、`prop:ease`、`nc:`）。
  unsupported,

  /// 求值用的原生内核（native/fushi_fsrs）不可用或拒收了数据：与查询本身无关。
  unavailable,
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

/// `re:正则`：在全部字段原文（0x1f 连接，同 rslib 的 `n.flds`）里做正则搜索，默认不区分大小写
/// （rslib：在正则前加 `(?i)`）。[source] 是查询里的原文，[pattern] 是解掉 `\"` 后交给正则引擎的。
final class SrsSearchRegex extends SrsSearchNode {
  const SrsSearchRegex(this.source, this.pattern);
  final String source;
  final String pattern;
}

/// `字段名:re:正则`：字段名通配；值按正则在字段原文里搜索（不锚定，默认不区分大小写）。
final class SrsSearchFieldRegex extends SrsSearchNode {
  const SrsSearchFieldRegex(this.field, this.source, this.pattern);
  final String field;
  final String source;
  final String pattern;
}

/// 裸词：在全部字段（原文）里做包含匹配，支持 `*` / `_`。
final class SrsSearchText extends SrsSearchNode {
  const SrsSearchText(this.text);
  final String text;
}

/// `字段名:值`：字段名不区分大小写、可通配；值整值匹配、可通配（去 HTML 后或原文命中都算）。
final class SrsSearchField extends SrsSearchNode {
  const SrsSearchField(this.field, this.text);
  final String field;
  final String text;
}

/// `deck:名`：匹配该牌组及其全部子牌组；`deck:*` 匹配全部。
final class SrsSearchDeck extends SrsSearchNode {
  const SrsSearchDeck(this.deck);
  final String deck;
}

/// `note:笔记类型名`。
final class SrsSearchNoteType extends SrsSearchNode {
  const SrsSearchNoteType(this.name);
  final String name;
}

/// `tag:标签`：匹配该标签及其子标签（`tag:a` 命中 `a`、`a::b`，不命中 `ab`）；
/// `tag:none` 无标签；`tag:*` 全部。通配 `_` / `*` 只匹配非空白。
final class SrsSearchTag extends SrsSearchNode {
  const SrsSearchTag(this.tag);
  final String tag;
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
  const SrsSearchCardTemplate.ordinal(int this.ordinal) : name = null;
  const SrsSearchCardTemplate.named(String this.name) : ordinal = null;
  final int? ordinal;
  final String? name;
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

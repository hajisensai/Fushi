/// Anki 搜索求值器，语义照 rslib `search/sqlwriter.rs`，但不依赖数据库：
/// 一切取自 [SrsSearchSubject]。
library;

import 'search_node.dart';
import 'search_text.dart';

/// [node] 是否命中 [subject]（一张卡）。
bool matchesAnkiSearch(SrsSearchNode node, SrsSearchSubject subject) {
  switch (node) {
    case SrsSearchAll():
      return true;
    case SrsSearchAnd(:final List<SrsSearchNode> children):
      return children.every((SrsSearchNode c) => matchesAnkiSearch(c, subject));
    case SrsSearchOr(:final List<SrsSearchNode> children):
      return children.any((SrsSearchNode c) => matchesAnkiSearch(c, subject));
    case SrsSearchNot(:final SrsSearchNode child):
      return !matchesAnkiSearch(child, subject);
    case SrsSearchText(:final RegExp pattern):
      // rslib：`n.flds like '%text%'`——字段原文用 0x1f 连起来做包含匹配。
      return pattern.hasMatch(subject.fields.values.join('\x1f'));
    case SrsSearchField(:final RegExp fieldPattern, :final RegExp valuePattern):
      for (final MapEntry<String, String> e in subject.fields.entries) {
        if (!fieldPattern.hasMatch(e.key)) continue;
        if (valuePattern.hasMatch(ankiSearchStripHtml(e.value)) ||
            valuePattern.hasMatch(e.value)) {
          return true;
        }
      }
      return false;
    case SrsSearchDeck(:final RegExp? pattern):
      return pattern == null || pattern.hasMatch(subject.deckName);
    case SrsSearchNoteType(:final RegExp pattern):
      return pattern.hasMatch(subject.noteTypeName);
    case SrsSearchTag(:final String tag, :final RegExp pattern):
      if (tag == 'none') return subject.tags.isEmpty;
      if (tag == '*') return true;
      if (tag.contains(' ')) return false;
      return pattern.hasMatch(' ${subject.tags.join(' ')} ');
    case SrsSearchState(:final SrsSearchCardState state):
      return switch (state) {
        SrsSearchCardState.isNew => subject.isNew,
        SrsSearchCardState.learn => subject.isLearn,
        SrsSearchCardState.review => subject.isReview,
        SrsSearchCardState.due => subject.isDue,
        SrsSearchCardState.suspended => subject.isSuspended,
        SrsSearchCardState.buried => subject.isBuried,
      };
    case SrsSearchRegex(:final RegExp pattern):
      return pattern.hasMatch(subject.fields.values.join(''));
    case SrsSearchFieldRegex(:final RegExp fieldPattern, :final RegExp pattern):
      for (final MapEntry<String, String> e in subject.fields.entries) {
        if (fieldPattern.hasMatch(e.key) && pattern.hasMatch(e.value)) {
          return true;
        }
      }
      return false;
    case SrsSearchFlag(:final int flag):
      return subject.flag == flag;
    case SrsSearchCardTemplate(:final int? ordinal, :final RegExp? pattern):
      return ordinal != null
          ? subject.cardOrdinal == ordinal
          : pattern!.hasMatch(subject.templateName);
    case SrsSearchEditedInDays(:final int days):
      return subject.editedDayIndex > subject.todayDayIndex - days;
    case SrsSearchProp(
      :final SrsSearchProperty property,
      :final compare,
      :final value,
    ):
      final num? actual = switch (property) {
        SrsSearchProperty.interval => subject.intervalDays,
        SrsSearchProperty.due => subject.dueInDays,
        SrsSearchProperty.reps => subject.reps,
        SrsSearchProperty.lapses => subject.lapses,
        SrsSearchProperty.stability => subject.stability,
        // Anki 把难度显示成 0–100%：prop:d 比的是 (d - 1) / 9。
        SrsSearchProperty.difficulty =>
          subject.difficulty == null ? null : (subject.difficulty! - 1) / 9,
      };
      if (actual == null) return false;
      return srsSearchCompare(actual, compare, value);
    case SrsSearchNoteIds(:final Set<int> ids):
      return ids.contains(subject.noteId);
    case SrsSearchCardIds(:final Set<int> ids):
      return ids.contains(subject.cardId);
    case SrsSearchAddedInDays(:final int days):
      // rslib：c.id > 「今天日界 - days 天」⇔ 加入日 > 今天 - days。
      return subject.addedDayIndex > subject.todayDayIndex - days;
  }
}

/// `prop:` 的比较（小数属性用 1e-9 容差判等，避免 0.1 + 0.2 之类的浮点误差）。
bool srsSearchCompare(num actual, SrsSearchCompare compare, num value) {
  final bool eq = actual is int && value is int
      ? actual == value
      : (actual - value).abs() < 1e-9;
  return switch (compare) {
    SrsSearchCompare.eq => eq,
    SrsSearchCompare.ne => !eq,
    SrsSearchCompare.lt => !eq && actual < value,
    SrsSearchCompare.le => eq || actual < value,
    SrsSearchCompare.gt => !eq && actual > value,
    SrsSearchCompare.ge => eq || actual > value,
  };
}

/// 导入 / 导出共用：媒体引用扫描与改写、fushi-ext 格式常量、导入牌组的确定性 ID。
library;

import 'package:fushi_srs/fushi_srs.dart';

/// fushi-ext 的 format 字段值与版本号（导入只认 [srsFushiExtVersion] 及以下）。
const String srsFushiExtFormat = 'fushi-ext';
const int srsFushiExtVersion = 1;

/// fushi-ext 里每个牌组随附的设置键（按 Fushi 原值写出 / 恢复）。
const List<String> srsFushiExtDeckKeys = <String>[
  SrsFieldKeys.deckParamsMode,
  SrsFieldKeys.deckAlgorithm,
  SrsFieldKeys.deckFsrs6Params,
  SrsFieldKeys.deckFsrs7Params,
  SrsFieldKeys.deckRetention,
  SrsFieldKeys.deckSteps,
  SrsFieldKeys.deckLimits,
  SrsFieldKeys.deckMaxInterval,
  SrsFieldKeys.deckAutoplay,
  SrsFieldKeys.deckReplayQuestion,
  SrsFieldKeys.deckRwkvQueue,
  SrsFieldKeys.deckNewPlan,
  SrsFieldKeys.deckReviewOrder,
  SrsFieldKeys.deckNewMix,
];

// Anki 预设的出卡顺序（ankitects/anki proto/anki/deck_config.proto：`new_mix` = 30 是 ReviewMix
// MIX_WITH_REVIEWS 0 / AFTER_REVIEWS 1 / BEFORE_REVIEWS 2；`review_order` = 33 是 ReviewCardOrder
// DAY 0 / DAY_THEN_DECK 1 / DECK_THEN_DAY 2 / INTERVALS_ASCENDING 3 / INTERVALS_DESCENDING 4 /
// EASE_ASCENDING 5 / EASE_DESCENDING 6 / RETRIEVABILITY_ASCENDING 7 / RANDOM 8 / ADDED 9 /
// REVERSE_ADDED 10 / RETRIEVABILITY_DESCENDING 11 / RELATIVE_OVERDUENESS 12）。开着 FSRS 时 Anki 把
// EASE_ASCENDING 当「难度从高到低」（rslib storage/card/mod.rs），所以 Fushi 的难度顺序对 5。

/// 导出：Fushi 新卡与复习 → Anki `newMix`。
int srsAnkiNewMixOf(SrsNewCardMix mix) => switch (mix) {
  SrsNewCardMix.mixed => 0,
  SrsNewCardMix.afterReviews => 1,
  SrsNewCardMix.beforeReviews => 2,
};

/// 导入：Anki `newMix` → Fushi；不认识的值 = null（不写，走缺省）。
SrsNewCardMix? srsNewCardMixOfAnki(int? v) => switch (v) {
  0 => SrsNewCardMix.mixed,
  1 => SrsNewCardMix.afterReviews,
  2 => SrsNewCardMix.beforeReviews,
  _ => null,
};

/// 导出：Fushi 复习顺序 → Anki `reviewOrder`。
int srsAnkiReviewOrderOf(SrsReviewCardOrder order) => switch (order) {
  SrsReviewCardOrder.retrievability => 7,
  SrsReviewCardOrder.dueDate => 0,
  SrsReviewCardOrder.difficulty => 5,
  SrsReviewCardOrder.intervalAscending => 3,
  SrsReviewCardOrder.random => 8,
};

/// 导入：Anki `reviewOrder` → Fushi。按牌组 / 添加先后 / 间隔倒序 / 难度从低到高 / R 倒序 / 相对逾期这些 Fushi
/// 没有的顺序（4、6、9、10、11、12）与 7 一样落缺省（可提取度从低到高）= null（不写）。
SrsReviewCardOrder? srsReviewCardOrderOfAnki(int? v) => switch (v) {
  0 || 1 || 2 => SrsReviewCardOrder.dueDate,
  3 => SrsReviewCardOrder.intervalAscending,
  5 => SrsReviewCardOrder.difficulty,
  8 => SrsReviewCardOrder.random,
  _ => null,
};

/// 从 Anki 导入时按全名新建的牌组 ID：与 Fushi 里新建牌组同一条规则（[SrsIds.deck]），
/// 多台设备各自导入同一个包、或一端导入一端手建同名牌组，合并后都是同一个牌组。
String srsImportedDeckId(String profileUid, String fullName) =>
    SrsIds.deck(profileUid, fullName);

// Anki rslib text.rs 的 HTML 媒体引用：img/audio/video/object/source/iframe 的 src / data。
final RegExp _htmlMediaRef = RegExp(
  r'''<\b(?:img|audio|video|object|source|iframe)\b[^>]+\b(?:src|data)\b=(?:"([^"]+?)"|'([^']+?)'|([^ >]+?))(?=\s|>)''',
  caseSensitive: false,
  dotAll: true,
);

final RegExp _soundRef = RegExp(r'\[sound:([^\]]+)\]');

/// 模板 / CSS 里引用下划线开头静态文件的写法（url("_x.woff")、src="_x.js" 等）。
final RegExp _staticRef = RegExp(r'''["'(]\s*(_[^"')\s]+)''');

bool _isRemote(String name) => name.contains('://') || name.startsWith('data:');

String _unescape(String s) {
  String out = s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
  try {
    out = Uri.decodeFull(out);
  } on ArgumentError {
    // 不是合法百分号编码：按原样。
  }
  return out;
}

/// 一段 HTML（字段值 / 模板）引用的本地媒体文件名（已反转义）。
Set<String> srsMediaRefsIn(String html, {bool includeStatic = false}) {
  // 快速判断：标签引用必含「<」、音频引用必含「[sound:」（纯文本字段占多数，迁移时要
  // 扫几十万个字段）。
  if (!includeStatic && !html.contains('<') && !html.contains('[sound:')) {
    return <String>{};
  }
  final Set<String> out = <String>{};
  for (final RegExpMatch m in _htmlMediaRef.allMatches(html)) {
    final String raw = m.group(1) ?? m.group(2) ?? m.group(3) ?? '';
    if (raw.isEmpty || _isRemote(raw)) continue;
    out.add(_unescape(raw));
  }
  for (final RegExpMatch m in _soundRef.allMatches(html)) {
    final String raw = m.group(1)!;
    if (!_isRemote(raw)) out.add(_unescape(raw));
  }
  if (includeStatic) {
    for (final RegExpMatch m in _staticRef.allMatches(html)) {
      out.add(_unescape(m.group(1)!));
    }
  }
  return out;
}

/// 把 [html] 里的媒体引用按 [renames]（原名 → 新名）改写；没改名的原样保留。
String srsRewriteMediaRefs(String html, Map<String, String> renames) {
  if (renames.isEmpty) return html;
  String rewriteGroup(RegExpMatch m, int group) {
    final String whole = m.group(0)!;
    final String? raw = m.group(group);
    if (raw == null) return whole;
    final String? to = renames[_unescape(raw)];
    if (to == null || to == raw) return whole;
    final int at = whole.lastIndexOf(raw);
    return whole.substring(0, at) + to + whole.substring(at + raw.length);
  }

  String out = html.replaceAllMapped(_htmlMediaRef, (Match mm) {
    final RegExpMatch m = mm as RegExpMatch;
    final int g = m.group(1) != null ? 1 : (m.group(2) != null ? 2 : 3);
    return rewriteGroup(m, g);
  });
  out = out.replaceAllMapped(
    _soundRef,
    (Match m) => rewriteGroup(m as RegExpMatch, 1),
  );
  out = out.replaceAllMapped(
    _staticRef,
    (Match m) => rewriteGroup(m as RegExpMatch, 1),
  );
  return out;
}

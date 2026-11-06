/// 发音词典：把合成文本里的写法换成读法（「今日」→「きょう」、人名、专有名词）。
///
/// 只改送去合成的文本，显示 / 高亮 / 制卡用的原文不动。改了词典的句子合成文本变了，
/// 缓存键随之变化，下次朗读或制作时自然重新合成。
library;

import 'dart:convert';

import 'package:fushi_engine/foundation/pref_store.dart';

class TtsPronunciationRule {
  const TtsPronunciationRule({required this.written, required this.spoken});

  final String written;
  final String spoken;

  Map<String, Object?> toJson() => <String, Object?>{'w': written, 's': spoken};

  static TtsPronunciationRule? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? w = raw['w'], s = raw['s'];
    if (w is! String || s is! String || w.trim().isEmpty) return null;
    return TtsPronunciationRule(written: w, spoken: s);
  }
}

/// 按写法长度从长到短逐条替换（长词优先，避免「東京都」被「東京」先吃掉）。
/// 每条规则只作用在尚未被替换过的文本上。
String applyTtsPronunciation(String text, List<TtsPronunciationRule> rules) {
  if (rules.isEmpty || text.isEmpty) return text;
  final List<TtsPronunciationRule> ordered =
      List<TtsPronunciationRule>.of(rules)..sort(
        (TtsPronunciationRule a, TtsPronunciationRule b) =>
            b.written.length.compareTo(a.written.length),
      );
  // 分段：已替换的片段不再参与后续规则匹配。
  List<({String text, bool fixed})> parts = <({String text, bool fixed})>[
    (text: text, fixed: false),
  ];
  for (final TtsPronunciationRule rule in ordered) {
    final List<({String text, bool fixed})> next =
        <({String text, bool fixed})>[];
    for (final ({String text, bool fixed}) part in parts) {
      if (part.fixed || !part.text.contains(rule.written)) {
        next.add(part);
        continue;
      }
      final List<String> pieces = part.text.split(rule.written);
      for (int i = 0; i < pieces.length; i++) {
        if (pieces[i].isNotEmpty) next.add((text: pieces[i], fixed: false));
        if (i < pieces.length - 1) next.add((text: rule.spoken, fixed: true));
      }
    }
    parts = next;
  }
  return parts.map((({String text, bool fixed}) p) => p.text).join();
}

class TtsPronunciationStore {
  TtsPronunciationStore(this._prefs);

  final PrefStore _prefs;

  static const String key = 'tts_pronunciation_rules';

  List<TtsPronunciationRule> load() {
    final Object? raw = _prefs.getPref(key, defaultValue: '');
    if (raw is! String || raw.isEmpty) return const <TtsPronunciationRule>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return const <TtsPronunciationRule>[];
      return <TtsPronunciationRule>[
        for (final Object? item in decoded)
          if (TtsPronunciationRule.fromJson(item)
              case final TtsPronunciationRule rule)
            rule,
      ];
    } on FormatException {
      return const <TtsPronunciationRule>[];
    }
  }

  Future<void> save(List<TtsPronunciationRule> rules) => _prefs.setPref(
    key,
    jsonEncode(<Object?>[
      for (final TtsPronunciationRule r in rules)
        if (r.written.trim().isNotEmpty) r.toJson(),
    ]),
  );
}

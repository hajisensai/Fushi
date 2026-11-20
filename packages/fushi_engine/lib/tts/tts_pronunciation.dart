/// TTS 文本处理规则（全局一份，朗读 / 制作有声书 / 漫画朗读与设置页共用）：
///
/// - **发音词典**：把合成文本里的写法换成读法（「今日」→「きょう」、人名、专有名词）。
/// - **合成前替换**：发音词典之后再对合成文本做通用改写（「〜」→「ー」、符号读法）。
/// - **识别后替换**：制作有声书的语音识别校对里，把识别结果改回原文写法（「きょう」→
///   「今日」）再与原文比对，读法改过的句子不再被误标。
///
/// 前两类只改送去合成的文本，显示 / 高亮 / 制卡用的原文不动。改了规则的句子合成文本
/// 变了，缓存键随之变化，下次朗读或制作时自然重新合成。
library;

import 'dart:async';
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

/// 送去合成的文本：先套发音词典（长词优先、替换过的片段不再参与匹配），再套合成前
/// 替换（作用在发音词典的结果上）。
String applyTtsSpokenRules(
  String text, {
  required List<TtsPronunciationRule> pronunciation,
  List<TtsPronunciationRule> preSynthesis = const <TtsPronunciationRule>[],
}) => applyTtsPronunciation(
  applyTtsPronunciation(text, pronunciation),
  preSynthesis,
);

/// 三类文本规则。
enum TtsTextRuleKind {
  pronunciation('tts_pronunciation_rules'),
  preSynthesis('tts_pre_synthesis_rules'),
  postRecognition('tts_post_recognition_rules');

  const TtsTextRuleKind(this.prefKey);

  /// 偏好键（`tts_pronunciation_rules` 是存量冻结名）。
  final String prefKey;
}

/// 三类文本规则的唯一存储（偏好表里每类一个 JSON 键）。设置页与「制作有声书」页
/// 都读写这里，不各存一份；任一处保存后经 [changes] 通知另一处重读。
class TtsTextRulesStore {
  TtsTextRulesStore(this._prefs);

  final PrefStore _prefs;
  final StreamController<TtsTextRuleKind> _changes =
      StreamController<TtsTextRuleKind>.broadcast(sync: true);

  /// 某一类规则被保存（参数是哪一类）。
  Stream<TtsTextRuleKind> get changes => _changes.stream;

  List<TtsPronunciationRule> load(TtsTextRuleKind kind) {
    final Object? raw = _prefs.getPref(kind.prefKey, defaultValue: '');
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

  Future<void> save(
    TtsTextRuleKind kind,
    List<TtsPronunciationRule> rules,
  ) async {
    await _prefs.setPref(
      kind.prefKey,
      jsonEncode(<Object?>[
        for (final TtsPronunciationRule r in rules)
          if (r.written.trim().isNotEmpty) r.toJson(),
      ]),
    );
    _changes.add(kind);
  }
}

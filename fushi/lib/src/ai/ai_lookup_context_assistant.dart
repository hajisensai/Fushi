/// 查词「按句意挑词条」：把句子、被查的词和词典**已查到**的候选词头交给 AI，
/// 由它指出哪个词头符合这句话里的用法，弹窗把那一组挪到最前。
///
/// 典型场景（2026-10-03 群里的截图）：漫画里写的是片假名「キゲンの悪いうみな」，
/// 扫词扫到「キゲン」，词典把「期限」排第一，按句意该是「機嫌」。片假名、同音词、
/// 多读音词都有这个问题——词典查询本身拿不到句子，只能按词典顺序与频率排。
///
/// 纪律与 `ai_feature.dart` 的硬边界一致：AI **只在已取回的候选里选择**，不产出
/// 任何释义文字；回复必须是候选编号之一，否则丢弃（弹窗保持原顺序）。没指派
/// 提供商时不发请求。
library;

import 'dart:convert';

import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_reply_json.dart';

/// 最多给 AI 看几个候选词头：再往后的词头几乎不会是答案，只增加 token。
const int kAiLookupContextMaxCandidates = 8;

/// 每个候选附带的释义摘要长度（字符）。够区分「期限 / 機嫌」，不至于把整本
/// 词典条目塞进提示词。
const int kAiLookupContextGlossChars = 80;

/// 一个候选词头（与弹窗 `popupJson` 的一组一一对应）。
class AiLookupCandidate {
  const AiLookupCandidate({
    required this.expression,
    required this.reading,
    required this.gloss,
  });

  final String expression;
  final String reading;

  /// 第一条释义的纯文本摘要（可能为空）。
  final String gloss;
}

/// 从查词结果抽候选词头，顺序与弹窗显示顺序一致。
///
/// 优先读 `popupJson`（弹窗实际渲染的分组）；没有时按 `entries` 的「表记 + 读音」
/// 首次出现顺序分组。
List<AiLookupCandidate> aiLookupCandidates(
  DictionarySearchResult result, {
  int max = kAiLookupContextMaxCandidates,
}) {
  final List<AiLookupCandidate> candidates = <AiLookupCandidate>[];
  final List<Map<String, Object?>>? groups = _decodeGroups(result.popupJson);
  if (groups != null) {
    for (final Map<String, Object?> group in groups) {
      if (candidates.length >= max) break;
      final Object? glossaries = group['glossaries'];
      String gloss = '';
      if (glossaries is List && glossaries.isNotEmpty) {
        final Object? first = glossaries.first;
        if (first is Map) gloss = _plain(first['content']);
      }
      candidates.add(
        AiLookupCandidate(
          expression: '${group['expression'] ?? ''}',
          reading: '${group['reading'] ?? ''}',
          gloss: _clip(gloss),
        ),
      );
    }
    return candidates;
  }
  final Set<String> seen = <String>{};
  for (final DictionaryEntry entry in result.entries) {
    if (candidates.length >= max) break;
    if (!seen.add('${entry.word}\n${entry.reading}')) continue;
    candidates.add(
      AiLookupCandidate(
        expression: entry.word,
        reading: entry.reading,
        gloss: _clip(entry.plainMeaning),
      ),
    );
  }
  return candidates;
}

/// 结果里被查到的那段原文（扫词命中的长度）；给 AI 看「句子里写的是什么」。
String aiLookupMatchedText(DictionarySearchResult result) {
  final String term = result.searchTerm;
  final int length = result.bestLength;
  if (length > 0 && length <= term.length) return term.substring(0, length);
  return term;
}

/// 查到这批词头的词典所声明的词头语言（BCP 47，如 `ja` / `zh` / `en`）：按
/// [DictionarySearchResult.entries] 逐条问 [languageOf]（词典名 → 词头语言，即
/// `Dictionary.effectiveSourceLanguage`），取出现最多的那个；票数相同取先出现的。
/// 一条都问不出来返回 null——调用方不猜（Fushi 没有全局学习语言）。
String? aiLookupHeadwordLanguage(
  DictionarySearchResult result,
  String? Function(String dictionaryName) languageOf,
) {
  final Map<String, int> votes = <String, int>{};
  for (final DictionaryEntry entry in result.entries) {
    final String language = languageOf(entry.dictionaryName)?.trim() ?? '';
    if (language.isEmpty) continue;
    votes[language] = (votes[language] ?? 0) + 1;
  }
  String? best;
  int bestVotes = 0;
  votes.forEach((String language, int count) {
    if (count > bestVotes) {
      best = language;
      bestVotes = count;
    }
  });
  return best;
}

/// 系统提示词。[language] 是词头语言的 BCP 47 标签；null 时用中立措辞，
/// 绝不默认成某一种语言（查词可能是任何一门在学的语言）。
String aiLookupSystemPrompt(String? language) {
  final String tag = language?.trim() ?? '';
  final String reading = tag.isEmpty
      ? 'read text in a language they are learning'
      : 'read text in the language with BCP 47 tag "$tag"';
  return 'You help a language learner $reading. Given a sentence, the word '
      'the learner looked up (as written in the sentence) and numbered '
      'dictionary headwords, choose the headword that matches how the word is '
      'used in this sentence.\n\n'
      'Reply with JSON only: {"choice": n} where n is the candidate number. '
      'Use {"choice": 0} if none of the candidates fits or the sentence does '
      'not decide it.';
}

/// 问 AI 选哪个候选；返回 0 起的候选下标，null = AI 认为都不合适 / 回复不合格。
/// [language] 是词头语言（见 [aiLookupHeadwordLanguage]），null = 不知道。
///
/// [AiChatFailure] 原样抛给调用方（UI 用 `aiFailureText` 提示）。
Future<int?> requestAiLookupChoice({
  required AiChatClient client,
  required AiProviderConfig provider,
  required String sentence,
  required String matched,
  required List<AiLookupCandidate> candidates,
  String? language,
}) async {
  if (candidates.length < 2 || sentence.trim().isEmpty) return null;
  final StringBuffer prompt = StringBuffer()
    ..writeln('Sentence: ${sentence.trim()}')
    ..writeln('Looked-up word: $matched')
    ..writeln('Candidates:');
  for (int i = 0; i < candidates.length; i++) {
    final AiLookupCandidate c = candidates[i];
    final String reading = c.reading.isEmpty || c.reading == c.expression
        ? ''
        : '【${c.reading}】';
    final String gloss = c.gloss.isEmpty ? '' : ' — ${c.gloss}';
    prompt.writeln('${i + 1}. ${c.expression}$reading$gloss');
  }
  final String reply = await client.complete(
    provider: provider,
    maxTokens: 64,
    messages: <AiChatMessage>[
      AiChatMessage.system(aiLookupSystemPrompt(language)),
      AiChatMessage.user(prompt.toString()),
    ],
  );
  return parseAiLookupChoice(reply, count: candidates.length);
}

/// 解析 `{"choice": n}`：只收 1..[count]，返回 0 起下标；0 / 越界 / 形状不对为 null。
int? parseAiLookupChoice(String reply, {required int count}) {
  final Object? raw = decodeAiJsonObject(reply)?['choice'];
  final int? choice = raw is num ? raw.toInt() : int.tryParse('$raw');
  if (choice == null || choice < 1 || choice > count) return null;
  return choice - 1;
}

/// 把第 [index] 个候选词头挪到最前，返回**新**结果对象（查词缓存里的那份是共享
/// 的，绝不原地改）。`popupJson` 与 `entries` 同步挪动；`entries` 按表记 + 读音
/// 认组（空读音视作同表记）。[index] 为 0 或越界时原样返回。
DictionarySearchResult promoteAiLookupCandidate(
  DictionarySearchResult result,
  int index,
) {
  if (index <= 0) return result;
  final List<Map<String, Object?>>? groups = _decodeGroups(result.popupJson);
  String expression;
  String reading;
  String? popupJson = result.popupJson;
  if (groups != null) {
    if (index >= groups.length) return result;
    final Map<String, Object?> chosen = groups.removeAt(index);
    groups.insert(0, chosen);
    popupJson = jsonEncode(groups);
    expression = '${chosen['expression'] ?? ''}';
    reading = '${chosen['reading'] ?? ''}';
  } else {
    final List<AiLookupCandidate> candidates = aiLookupCandidates(
      result,
      max: index + 1,
    );
    if (index >= candidates.length) return result;
    expression = candidates[index].expression;
    reading = candidates[index].reading;
  }
  bool inGroup(DictionaryEntry e) =>
      e.word == expression &&
      (e.reading == reading ||
          e.reading.isEmpty ||
          (reading.isEmpty && e.reading == expression));
  final DictionarySearchResult promoted = DictionarySearchResult(
    searchTerm: result.searchTerm,
    entries: <DictionaryEntry>[
      ...result.entries.where(inGroup),
      ...result.entries.where((DictionaryEntry e) => !inGroup(e)),
    ],
    bestLength: result.bestLength,
    kanjiResults: result.kanjiResults,
    truncated: result.truncated,
    headwordCount: result.headwordCount,
  );
  promoted.popupJson = popupJson;
  return promoted;
}

List<Map<String, Object?>>? _decodeGroups(String? popupJson) {
  if (popupJson == null || popupJson.isEmpty) return null;
  try {
    final Object? decoded = jsonDecode(popupJson);
    if (decoded is! List) return null;
    return <Map<String, Object?>>[
      for (final Object? group in decoded)
        if (group is Map) group.cast<String, Object?>(),
    ];
  } on FormatException {
    return null;
  }
}

/// 释义内容可能是结构化内容（对象 / 数组）或其 JSON 串，统一转纯文本。
String _plain(Object? content) {
  if (content == null) return '';
  if (content is String) return DictionaryEntry.meaningToPlainText(content);
  return DictionaryEntry.meaningToPlainText(jsonEncode(content));
}

String _clip(String text) {
  // MDX / StarDict 的释义是 HTML：去标签再压空白。
  final String flat = text
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (flat.length <= kAiLookupContextGlossChars) return flat;
  return '${flat.substring(0, kAiLookupContextGlossChars)}…';
}

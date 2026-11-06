/// S4：整作写法统一（spec `2026-10-19-video-asr-llm-subtitle-pipeline` 第 3 节，移植自
/// 基准 `C:\asr_bench\scripts\consistency.py`，规则文本与阈值原样搬）。
///
/// 1. [subtitleConsistencySuspects]：先从行里抹掉全部正式写法，再找残留的可疑写法
///    （读音同形、片假名名字编辑距离 1、已知误写），防止子串误报
///    （「ルシファ」⊂「ルシファー」）。
/// 2. [subtitleLyricLike]：疑似唱段（7 行窗口内 ≥6 条 ≤14 字、说话人 ≤1 种、最大
///    间隔 <0.8 s）。
/// 3. 只把被标出的行连同前后 2 行交给 AI，每批 40 行；回复走行协议
///    （[runAiLineExchange]），只写要改的行 + 结束标记。结果缓存 `consistency.json`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_language.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_prompts_zh.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';

/// S4 提示词（`consistency.py` 的 `RULES`；除输出格式一句外逐字照搬——基准要求 JSON
/// 写全部 id，这里只写改动的行）。占位符：`{title}` / `{glossary}` / `{lines}`。
const String kSubtitleConsistencyRules =
    '''あなたは日本語アニメ「{title}」字幕の最終校正者です。下の各行は、固有名詞表の表記と食い違う可能性がある語、
または歌唱(歌詞)の可能性がある行として機械的に抽出されたものです。前後の行を参考に、各対象行について判断してください。
- 表の人物・用語を指しているなら、表の正式表記に揃える(読みが同じ別表記、1文字違いのカタカナ等)。
- 表の語を指していない(一般語、別の人物、偶然の一致)なら、そのままにする。
- 歌唱中の歌詞と判断できる行は、本文はそのまま、先頭に「♪」を付ける(既に付いていれば何もしない)。台詞なら付けない。
- それ以外の箇所は変えない。
出力は変更する行だけを 1 行 1 件で書く: <id><TAB><修正後の行>。変更しない行は書かない。id の昇順に書き、最後の行に END とだけ書く(変更が無ければ END だけ)。説明文は書かない。

固有名詞表:
{glossary}

{lines}''';

/// [kSubtitleConsistencyRules] 里 `{lines}` 之前的部分（规则 + 作品名 + 专名表）：同一
/// 作品各批逐字相同，是提示缓存的命中段。与 `{lines}` 之间原本隔一个空行，拆在
/// 第一个换行上：`joinAiTextPrompt(前缀, 行)` 与整段模板替换的结果逐字相同。
String buildConsistencyStablePrefix({
  required String title,
  required String glossaryText,
  VideoSubtitleLanguage language = VideoSubtitleLanguage.japanese,
}) {
  const String marker = '\n{lines}';
  final String rules = language == VideoSubtitleLanguage.mandarin
      ? kSubtitleConsistencyRulesZh
      : kSubtitleConsistencyRules;
  final int at = rules.indexOf(marker);
  return rules
      .substring(0, at)
      .replaceAll('{title}', title)
      .replaceAll('{glossary}', glossaryText);
}

/// 片假名词（≥2 字，含长音）：同 `consistency.py` 的 `KATA`。
final RegExp kSubtitleKatakanaRun = RegExp('[ァ-ヺー]{2,}');
final RegExp _kKatakanaWord = RegExp(r'^[ァ-ヺー]{2,}$');
final RegExp _kReadingNoise = RegExp(r'[\s・]');

/// 全是汉字的写法（普通话的人名 / 用语）。
final RegExp _kHanWord = RegExp(r'^\p{Script=Han}+$', unicode: true);

/// 码点长度（Python `len` 的口径；Dart `String.length` 数的是 UTF-16 单元）。
int _len(String s) => s.runes.length;

/// 平假名 → 片假名（ぁ..ゖ 平移 0x60）。
String hiraganaToKatakana(String s) => String.fromCharCodes(<int>[
  for (final int ch in s.runes)
    if (ch >= 0x3041 && ch <= 0x3096) ch + 0x60 else ch,
]);

/// 按码点的 Levenshtein 编辑距离（两行滚动，O(n·m) 时间、O(m) 空间）。
int levenshteinDistance(String a, String b) {
  final List<int> s = a.runes.toList();
  final List<int> t = b.runes.toList();
  if (s.isEmpty) return t.length;
  if (t.isEmpty) return s.length;
  List<int> prev = List<int>.generate(t.length + 1, (int j) => j);
  List<int> cur = List<int>.filled(t.length + 1, 0);
  for (int i = 1; i <= s.length; i++) {
    cur[0] = i;
    for (int j = 1; j <= t.length; j++) {
      final int cost = s[i - 1] == t[j - 1] ? 0 : 1;
      final int del = prev[j] + 1;
      final int ins = cur[j - 1] + 1;
      final int sub = prev[j - 1] + cost;
      cur[j] = del < ins ? (del < sub ? del : sub) : (ins < sub ? ins : sub);
    }
    final List<int> swap = prev;
    prev = cur;
    cur = swap;
  }
  return prev[t.length];
}

/// 一行里可能该统一成专名表写法的残留写法，形如 `誤→正?`（排序去重）。
///
/// 同 `consistency.py` 的 `suspects`（per-episode `asr_fixes` 本管线不生成，略去）。
///
/// 普通话（[language]）没有片假名：「片假名名字编辑距离 1」换成「≥3 个汉字的正式写法、
/// 同长度窗口里恰好错 1 个字」（`林晓明` ↔ `林小明`）。2 个字的写法不比：同音同长的
/// 普通词太多。
List<String> subtitleConsistencySuspects(
  String text,
  List<SubtitleGlossaryEntry> entries, {
  VideoSubtitleLanguage language = VideoSubtitleLanguage.japanese,
}) {
  final List<String> canon = <String>{
    for (final SubtitleGlossaryEntry e in entries) e.ja,
  }.toList()..sort((String a, String b) => _len(b).compareTo(_len(a)));
  final Set<String> canonSet = canon.toSet();
  String rest = text;
  // 正式写法本身永远不算别的词的变体。
  for (final String ja in canon) {
    if (ja.isEmpty) continue;
    rest = rest.replaceAll(ja, '\u0000');
  }
  final Set<String> why = <String>{};
  for (final SubtitleGlossaryEntry e in entries) {
    final String ja = e.ja;
    final String rd = e.reading.replaceAll(_kReadingNoise, '');
    final Set<String> forms = <String>{...e.misrecognitions};
    if (_len(rd) >= 2) {
      forms
        ..add(rd)
        ..add(hiraganaToKatakana(rd));
    }
    for (final String m in forms) {
      if (_len(m) >= 2 &&
          m != ja &&
          !canonSet.contains(m) &&
          rest.contains(m)) {
        why.add('$m→$ja?');
      }
    }
    if (language == VideoSubtitleLanguage.mandarin) {
      if (_kHanWord.hasMatch(ja) && _len(ja) >= 3) {
        why.addAll(_hanNearMisses(rest, ja, canonSet));
      }
      continue;
    }
    if (_kKatakanaWord.hasMatch(ja) && _len(ja) >= 3) {
      for (final RegExpMatch match in kSubtitleKatakanaRun.allMatches(rest)) {
        final String tok = match.group(0)!;
        if (!canonSet.contains(tok) &&
            (_len(tok) - _len(ja)).abs() <= 1 &&
            levenshteinDistance(tok, ja) == 1) {
          why.add('$tok→$ja?');
        }
      }
    }
  }
  return why.toList()..sort();
}

/// [rest] 里与 [ja] 等长、恰好差 1 个字、且两端都是汉字的片段（`误→正?`）。
Iterable<String> _hanNearMisses(
  String rest,
  String ja,
  Set<String> canonSet,
) sync* {
  final List<int> target = ja.runes.toList();
  final List<int> hay = rest.runes.toList();
  for (int i = 0; i + target.length <= hay.length; i++) {
    int diff = 0;
    bool han = true;
    for (int k = 0; k < target.length && diff <= 1; k++) {
      final int ch = hay[i + k];
      if (!_kHanWord.hasMatch(String.fromCharCode(ch))) {
        han = false;
        break;
      }
      if (ch != target[k]) diff++;
    }
    if (!han || diff != 1) continue;
    final String tok = String.fromCharCodes(hay.sublist(i, i + target.length));
    if (!canonSet.contains(tok)) yield '$tok→$ja?';
  }
}

/// 第 [i] 行是否处在疑似唱段里（同 `consistency.py` 的 `lyric_like`；弱信号）。
bool subtitleLyricLike(List<SubtitleDraftCue> cues, int i) {
  final int lo = i - 3 < 0 ? 0 : i - 3;
  final int hi = i + 4 > cues.length ? cues.length : i + 4;
  final List<SubtitleDraftCue> run = cues.sublist(lo, hi);
  if (run.length < 6) return false;
  final int short = run
      .where((SubtitleDraftCue c) => _len(c.text) <= 14)
      .length;
  final Set<String?> speakers = <String?>{
    for (final SubtitleDraftCue c in run) c.speaker,
  };
  int maxGap = -1 << 31;
  for (int k = 1; k < run.length; k++) {
    final int gap = run[k].startMs - run[k - 1].endMs;
    if (gap > maxGap) maxGap = gap;
  }
  return short >= 6 && speakers.length <= 1 && maxGap < 800;
}

/// 每行被标出的原因；只含被标出的行。
Map<int, List<String>> flagSubtitleConsistencyLines(
  List<SubtitleDraftCue> cues,
  SubtitleGlossary glossary, {
  VideoSubtitleLanguage language = VideoSubtitleLanguage.japanese,
}) {
  final Map<int, List<String>> flagged = <int, List<String>>{};
  for (int i = 0; i < cues.length; i++) {
    final List<String> why = subtitleConsistencySuspects(
      cues[i].text,
      glossary.entries,
      language: language,
    );
    if (subtitleLyricLike(cues, i) && !cues[i].text.startsWith('♪')) {
      why.add(
        language == VideoSubtitleLanguage.mandarin
            ? SubtitleConsistencyLabelsZh.lyric
            : '歌詞?',
      );
    }
    if (why.isNotEmpty) flagged[i] = why;
  }
  return flagged;
}

/// S4 结果。
class SubtitleConsistencyResult {
  const SubtitleConsistencyResult({
    required this.cues,
    required this.flaggedCount,
    required this.changedCount,
    required this.usage,
  });

  final List<SubtitleDraftCue> cues;
  final int flaggedCount;
  final int changedCount;

  /// 含缓存里记着的当时用量。
  final SubtitleAiUsageTally usage;
}

/// S4 写法统一。
class SubtitleConsistencyPass {
  SubtitleConsistencyPass({
    required this.completer,
    this.batchSize = 40,
    this.contextLines = 2,
    this.maxAttempts = 3,
    this.language = VideoSubtitleLanguage.japanese,
  });

  final AiTextCompleter completer;
  final int batchSize;
  final int contextLines;
  final int maxAttempts;

  /// 选提示词与可疑写法规则（[subtitleConsistencySuspects]）。
  final VideoSubtitleLanguage language;

  /// [cacheFile] 存在即复用（`{"fix": {...}, "usage": {...}}`）；否则只问被标出的行，
  /// 全部批次的回复都写完才写缓存（没有被标出的行也写一份空缓存，标记完成）。
  Future<SubtitleConsistencyResult> run({
    required List<SubtitleDraftCue> cues,
    required String title,
    required SubtitleGlossary glossary,
    required File cacheFile,
    SubtitleCancelToken cancel = const SubtitleNeverCancel(),
  }) async {
    final Map<int, List<String>> flagged = flagSubtitleConsistencyLines(
      cues,
      glossary,
      language: language,
    );
    final SubtitleAiUsageTally usage = SubtitleAiUsageTally();
    Map<String, Object?>? fix = _readCache(cacheFile, usage);
    if (fix == null) {
      fix = <String, Object?>{};
      final String gl = <String>[
        for (final SubtitleGlossaryEntry e in glossary.entries)
          language == VideoSubtitleLanguage.mandarin && e.reading.trim().isEmpty
              ? '${e.ja} ${e.kind}'
              : '${e.ja}(${e.reading}) ${e.kind}',
      ].join('\n');
      final List<int> ids = flagged.keys.toList()..sort();
      for (int b = 0; b < ids.length; b += batchSize) {
        throwIfSubtitleCancelled(cancel);
        final List<int> chunk = ids.sublist(
          b,
          b + batchSize > ids.length ? ids.length : b + batchSize,
        );
        fix.addAll(
          await _askChunk(cues, chunk, flagged, title, gl, usage, cancel),
        );
      }
      await writeSubtitleJobFileAtomic(
        cacheFile,
        const JsonEncoder.withIndent(
          ' ',
        ).convert(<String, Object?>{'fix': fix, 'usage': usage.toJson()}),
      );
    }
    final List<SubtitleDraftCue> out = List<SubtitleDraftCue>.of(cues);
    int changed = 0;
    for (final MapEntry<String, Object?> e in fix.entries) {
      final int? i = int.tryParse(e.key);
      final Object? v = e.value;
      if (i == null || i < 0 || i >= out.length) continue;
      if (v is String && v.trim().isNotEmpty && v != out[i].text) {
        out[i] = out[i].copyWith(text: fullWidthSubtitlePunctuation(v));
        changed++;
      }
    }
    return SubtitleConsistencyResult(
      cues: out,
      flaggedCount: flagged.length,
      changedCount: changed,
      usage: usage,
    );
  }

  Future<Map<String, Object?>> _askChunk(
    List<SubtitleDraftCue> cues,
    List<int> chunk,
    Map<int, List<String>> flagged,
    String title,
    String glossaryText,
    SubtitleAiUsageTally usage,
    SubtitleCancelToken cancel,
  ) async {
    String lineFor(int i) {
      final int from = i - contextLines < 0 ? 0 : i - contextLines;
      final int to = i + 1 + contextLines > cues.length
          ? cues.length
          : i + 1 + contextLines;
      final String ctx = <String>[
        for (int j = from; j < i; j++) cues[j].text,
      ].join(' / ');
      final String nxt = <String>[
        for (int j = i + 1; j < to; j++) cues[j].text,
      ].join(' / ');
      if (language == VideoSubtitleLanguage.mandarin) {
        return 'id=$i ${SubtitleConsistencyLabelsZh.before}: $ctx\n'
            '  ${SubtitleConsistencyLabelsZh.target}: ${cues[i].text}\n'
            '  ${SubtitleConsistencyLabelsZh.after}: $nxt\n'
            '  ${SubtitleConsistencyLabelsZh.suspect}: ${flagged[i]!.join('、')}';
      }
      return 'id=$i 前: $ctx\n  対象: ${cues[i].text}\n  後: $nxt\n'
          '  疑い: ${flagged[i]!.join('、')}';
    }

    // 同 S3：改动跨轮累积；回复按 id 升序只写改动的行，没写完时下一轮只问最后一条
    // 之后的 id。
    final Map<String, Object?> answered = <String, Object?>{};
    int next = chunk.first;
    await runAiLineExchange(
      completer: completer,
      stablePrefix: buildConsistencyStablePrefix(
        title: title,
        glossaryText: glossaryText,
        language: language,
      ),
      body: () => <String>[
        for (final int i in chunk)
          if (i >= next) lineFor(i),
      ].join('\n'),
      absorb: (List<String> lines) {
        final int from = next;
        int added = 0;
        for (final String line in lines) {
          final (String, String)? record = splitAiLineRecord(line);
          final int? id = record == null ? null : int.tryParse(record.$1);
          if (id == null || id < from || !flagged.containsKey(id)) continue;
          if (!chunk.contains(id) || answered.containsKey('$id')) continue;
          answered['$id'] = record!.$2;
          added++;
          if (id >= next) next = id + 1;
        }
        return added;
      },
      done: (AiLineReply reply) => reply.complete || next > chunk.last,
      failureDetail: () =>
          'consistency batch ${chunk.first}-${chunk.last}: '
          'no complete reply from id $next',
      usage: usage,
      cancel: cancel,
      maxAttempts: maxAttempts,
    );
    return answered;
  }

  static Map<String, Object?>? _readCache(
    File cache,
    SubtitleAiUsageTally usage,
  ) {
    if (!cache.existsSync()) return null;
    try {
      final Object? decoded = jsonDecode(cache.readAsStringSync());
      if (decoded is! Map || decoded['fix'] is! Map) return null;
      final Object? u = decoded['usage'];
      if (u is Map) {
        usage.addTally(
          SubtitleAiUsageTally.fromJson(u.cast<String, Object?>()),
        );
      }
      return (decoded['fix'] as Map).map(
        (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
      );
    } on FormatException {
      return null;
    }
  }
}

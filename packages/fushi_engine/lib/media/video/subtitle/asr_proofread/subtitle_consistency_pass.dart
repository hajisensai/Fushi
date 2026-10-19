/// S4：整作写法统一（spec `2026-10-19-video-asr-llm-subtitle-pipeline` 第 3 节，移植自
/// 基准 `C:\asr_bench\scripts\consistency.py`，规则文本与阈值原样搬）。
///
/// 1. [subtitleConsistencySuspects]：先从行里抹掉全部正式写法，再找残留的可疑写法
///    （读音同形、片假名名字编辑距离 1、已知误写），防止子串误报
///    （「ルシファ」⊂「ルシファー」）。
/// 2. [subtitleLyricLike]：疑似唱段（7 行窗口内 ≥6 条 ≤14 字、说话人 ≤1 种、最大
///    间隔 <0.8 s）。
/// 3. 只把被标出的行连同前后 2 行交给 AI，每批 40 行，回复必须覆盖全部 id。
///    结果缓存 `consistency.json`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';

/// S4 提示词（`consistency.py` 的 `RULES`，逐字照搬）。占位符：`{title}` /
/// `{glossary}` / `{lines}`。
const String kSubtitleConsistencyRules =
    '''あなたは日本語アニメ「{title}」字幕の最終校正者です。下の各行は、固有名詞表の表記と食い違う可能性がある語、
または歌唱(歌詞)の可能性がある行として機械的に抽出されたものです。前後の行を参考に、各対象行について判断してください。
- 表の人物・用語を指しているなら、表の正式表記に揃える(読みが同じ別表記、1文字違いのカタカナ等)。
- 表の語を指していない(一般語、別の人物、偶然の一致)なら、そのままにする。
- 歌唱中の歌詞と判断できる行は、本文はそのまま、先頭に「♪」を付ける(既に付いていれば何もしない)。台詞なら付けない。
- それ以外の箇所は変えない。
出力は JSON オブジェクトのみ: {"<id>": "<修正後の行>", ...}。全ての対象 id を含める。

固有名詞表:
{glossary}

{lines}''';

/// 片假名词（≥2 字，含长音）：同 `consistency.py` 的 `KATA`。
final RegExp kSubtitleKatakanaRun = RegExp('[ァ-ヺー]{2,}');
final RegExp _kKatakanaWord = RegExp(r'^[ァ-ヺー]{2,}$');
final RegExp _kReadingNoise = RegExp(r'[\s・]');

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
List<String> subtitleConsistencySuspects(
  String text,
  List<SubtitleGlossaryEntry> entries,
) {
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
  SubtitleGlossary glossary,
) {
  final Map<int, List<String>> flagged = <int, List<String>>{};
  for (int i = 0; i < cues.length; i++) {
    final List<String> why = subtitleConsistencySuspects(
      cues[i].text,
      glossary.entries,
    );
    if (subtitleLyricLike(cues, i) && !cues[i].text.startsWith('♪')) {
      why.add('歌詞?');
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
  });

  final AiTextCompleter completer;
  final int batchSize;
  final int contextLines;
  final int maxAttempts;

  /// [cacheFile] 存在即复用（`{"fix": {...}, "usage": {...}}`）；否则只问被标出的行，
  /// 全部批次都覆盖了全部 id 才写缓存（没有被标出的行也写一份空缓存，标记完成）。
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
    );
    final SubtitleAiUsageTally usage = SubtitleAiUsageTally();
    Map<String, Object?>? fix = _readCache(cacheFile, usage);
    if (fix == null) {
      fix = <String, Object?>{};
      final String gl = <String>[
        for (final SubtitleGlossaryEntry e in glossary.entries)
          '${e.ja}(${e.reading}) ${e.kind}',
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
    final List<String> lines = <String>[];
    for (final int i in chunk) {
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
      lines.add(
        'id=$i 前: $ctx\n  対象: ${cues[i].text}\n  後: $nxt\n'
        '  疑い: ${flagged[i]!.join('、')}',
      );
    }
    final String prompt = kSubtitleConsistencyRules
        .replaceAll('{title}', title)
        .replaceAll('{glossary}', glossaryText)
        .replaceAll('{lines}', lines.join('\n'));
    final Set<String> want = <String>{for (final int i in chunk) '$i'};
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      throwIfSubtitleCancelled(cancel);
      final AiChatCompletion reply = await completer.complete(prompt);
      usage.addCall(reply.usage);
      final Object? got = decodeLooseAiJson(reply.text);
      if (got is Map) {
        final Map<String, Object?> map = got.map(
          (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
        );
        if (want.difference(map.keys.toSet()).isEmpty) return map;
      }
    }
    throw SubtitleAiRequestFailure(
      kSubtitleAiReplyIncomplete,
      detail:
          'consistency batch ${chunk.first}-${chunk.last}: '
          'reply missing ids',
    );
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

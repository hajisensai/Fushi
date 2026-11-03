/// S3：LLM 逐批校对识别稿（spec `2026-10-19-video-asr-llm-subtitle-pipeline` 第 3 节，
/// 移植自基准 `C:\asr_bench\scripts\llm_fix.py`，规则文本原样搬）。
///
/// - 每批 [SubtitleProofreader.batchSize] 句，附前后各 [SubtitleProofreader.contextLines]
///   句只读上下文；每句给主稿、候选稿（[SubtitleDraftCue.alternatives]）与专名表。
/// - 回复走行协议（[runAiLineExchange]）：**只写要改的行**（`<id><TAB><正文>`，id 升序）
///   + 结束标记。回复写完才写批缓存，没写的行就是不用改；被截断时收下写完的行，
///   下一轮只问最后一条之后的 id，连续 [SubtitleProofreader.maxAttempts] 轮没有新行
///   才抛 [SubtitleAiRequestFailure]（[kSubtitleAiReplyIncomplete]）。请求本身失败
///   （额度 / 鉴权 / 网络）不重试、原样抛出——绝不当成「没有修改」。
/// - 批缓存 `<cacheDir>/<批起点 5 位>.json`（`{"fix": {...}, "usage": {...}}`）：
///   重跑时已缓存的批直接复用。
/// - 时间轴不变只改文字；结果为空的行删除；`!?` 统一成全角。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:path/path.dart' as p;

/// 校对规则（`llm_fix.py` 的 `RULES`，第 1–8 条逐字照搬；第 1、5 条提到的他言語字幕
/// 本管线目前不提供，规则保持原样以免改变实测过的行为）。只有输出格式一句改了：
/// 基准要求 JSON 写全部 id，这里只写改动的行（输出量少一个数量级，截断也不再整段作废）。
const String kSubtitleProofreadRules =
    '''あなたは日本語アニメ字幕の校正者です。音声認識(ASR)で作った日本語字幕の誤認識だけを直します。
入力:
- 作品名、固有名詞表(あれば)
- 各行: id、時刻、ASR本文(主)、別のASR候補(あれば)、同じ時間帯の他言語字幕(英語/中国語、あれば)
規則:
1. 出力は話された日本語そのもの。翻訳字幕を日本語に訳し戻して置き換えない。翻訳は意味・人名・用語を判断する手掛かりにだけ使う。
2. 明らかな誤認識(同音異義語の誤り、人名・作品用語の表記、意味が通らない語、切れた語)を直す。人名は固有名詞表の表記に統一する。
3. 口癖、言い淀み、感動詞、方言、繰り返し、言いさしは残す。文体を整えたり要約したりしない。
4. 確信がない部分は主ASRのままにする。候補同士で迷ったら、文脈と翻訳に最も合う候補を選ぶ。
5. 主ASRに無い台詞を翻訳から足さない。ただし別のASR候補にある語は採用してよい。
6. 音楽・雑音を文字化しただけの明らかな幻聴は空文字にしてよい。
7. 句読点は控えめに。漢字・かなの表記は一般的な字幕の慣習に従う。
8. 同じ人物・用語は回を通して同じ表記にする(固有名詞表の表記を優先。表に無い語を推測で固有名詞に置き換えない)。
出力は修正が必要な行だけを 1 行 1 件で書く: <id><TAB><修正後本文>(例: 12\t唯が来た)。修正の無い行は書かない。行を空文字にする場合は <id><TAB> だけを書く。
id の昇順に書き、最後の行に END とだけ書く(修正が 1 件も無ければ END だけ)。説明文・JSON・コードブロックは書かない。''';

/// 专名表在 S3 提示词里的写法（同 `llm_fix.py --series-glossary`）。
String formatGlossaryForProofread(SubtitleGlossary glossary) => <String>[
  for (final SubtitleGlossaryEntry e in glossary.entries)
    '${e.ja}(${e.reading}) ${e.kind} 誤: ${e.misrecognitions.join('、')}',
].join('\n');

/// `mm:ss.ss`（同 `llm_fix.py` 的 `fmt_t`）。
String formatProofreadTime(int ms) {
  final int minutes = ms ~/ 60000;
  final double seconds = (ms % 60000) / 1000;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toStringAsFixed(2).padLeft(5, '0')}';
}

/// 校对结果。
class SubtitleProofreadResult {
  const SubtitleProofreadResult({
    required this.cues,
    required this.changedCount,
    required this.removedCount,
    required this.usage,
  });

  /// 校对后的字幕（时间轴同输入；文字为空的行已删）。
  final List<SubtitleDraftCue> cues;

  /// 文字有变化的行数（含被删的行）。
  final int changedCount;

  /// 结果为空被删掉的行数。
  final int removedCount;

  /// 全部批次的用量：含从缓存复用的批（缓存里存着当时的用量），即这一集校对累计
  /// 花了多少；重试失败那几次也计入。
  final SubtitleAiUsageTally usage;
}

/// S3 校对器。无状态，可跨集复用。
class SubtitleProofreader {
  SubtitleProofreader({
    required this.completer,
    this.batchSize = 30,
    this.contextLines = 3,
    this.concurrency = 4,
    this.maxAttempts = 3,
  }) : assert(batchSize > 0 && concurrency > 0 && maxAttempts > 0);

  final AiTextCompleter completer;
  final int batchSize;
  final int contextLines;

  /// 同时在途的批数。提供商的每分钟请求数由 `AiChatClient` 的限频器把关，这里
  /// 只决定最多排几个进队。
  final int concurrency;
  final int maxAttempts;

  /// 校对 [cues]。[cacheDir] 是这一集的批缓存目录（`<任务目录>/proofread/`）。
  ///
  /// 任何一批失败：等在途的批各自结束（成功的照常落缓存），再抛第一个错误——
  /// 重跑时只剩失败的那些批要发。
  Future<SubtitleProofreadResult> proofread({
    required List<SubtitleDraftCue> cues,
    required String title,
    required SubtitleGlossary glossary,
    required Directory cacheDir,
    SubtitleCancelToken cancel = const SubtitleNeverCancel(),
    void Function(int doneBatches, int totalBatches)? onProgress,
  }) async {
    final String glossaryText = formatGlossaryForProofread(glossary);
    final List<(int, int)> ranges = <(int, int)>[
      for (int lo = 0; lo < cues.length; lo += batchSize)
        (lo, lo + batchSize > cues.length ? cues.length : lo + batchSize),
    ];
    final List<Map<String, Object?>?> fixes =
        List<Map<String, Object?>?>.filled(ranges.length, null);
    final SubtitleAiUsageTally usage = SubtitleAiUsageTally();
    if (ranges.isNotEmpty) await cacheDir.create(recursive: true);
    int next = 0;
    int done = 0;
    Object? firstError;
    StackTrace? firstStack;

    Future<void> worker() async {
      while (firstError == null && next < ranges.length) {
        final int index = next++;
        try {
          throwIfSubtitleCancelled(cancel);
          final (Map<String, Object?>, SubtitleAiUsageTally) r = await _batch(
            cues,
            ranges[index],
            title,
            glossaryText,
            cacheDir,
            cancel,
          );
          fixes[index] = r.$1;
          usage.addTally(r.$2);
          onProgress?.call(++done, ranges.length);
        } catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        }
      }
    }

    await Future.wait(<Future<void>>[
      for (int w = 0; w < concurrency; w++) worker(),
    ]);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }

    final List<SubtitleDraftCue> out = <SubtitleDraftCue>[];
    int changed = 0;
    int removed = 0;
    for (int i = 0; i < cues.length; i++) {
      final SubtitleDraftCue c = cues[i];
      String text = c.text;
      for (final Map<String, Object?>? fix in fixes) {
        final Object? v = fix?['$i'];
        if (v is String) text = v;
      }
      text = fullWidthSubtitlePunctuation(text);
      if (text != c.text) changed++;
      if (text.trim().isEmpty) {
        removed++;
        continue;
      }
      out.add(text == c.text ? c : c.copyWith(text: text));
    }
    return SubtitleProofreadResult(
      cues: out,
      changedCount: changed,
      removedCount: removed,
      usage: usage,
    );
  }

  /// 一批：先看缓存，没有就问，回复写完才落盘。
  Future<(Map<String, Object?>, SubtitleAiUsageTally)> _batch(
    List<SubtitleDraftCue> cues,
    (int, int) range,
    String title,
    String glossaryText,
    Directory cacheDir,
    SubtitleCancelToken cancel,
  ) async {
    final File cache = File(
      p.join(cacheDir.path, '${range.$1.toString().padLeft(5, '0')}.json'),
    );
    final SubtitleAiUsageTally usage = SubtitleAiUsageTally();
    final Map<String, Object?>? cached = _readBatchCache(cache, usage);
    if (cached != null) return (cached, usage);

    final (int lo, int hi) = range;
    // 修正跨轮累积。回复按 id 升序只写改动的行：没写完时，最后一条之前没写的行就是
    // 不用改，下一轮只问它之后的 id（之前的行留在原位当只读参考）。只收本轮在问的
    // id（模型顺手改的上下文行不收，否则会盖掉相邻批对同一行的修正）。
    final Map<String, Object?> got = <String, Object?>{};
    int next = lo;
    await runAiLineExchange(
      completer: completer,
      stablePrefix: buildProofreadStablePrefix(
        title: title,
        glossaryText: glossaryText,
      ),
      body: () => buildProofreadBatchBody(
        cues: cues,
        lo: lo,
        hi: hi,
        contextLines: contextLines,
        only: next == lo ? null : <int>{for (int i = next; i < hi; i++) i},
      ),
      absorb: (List<String> lines) {
        final int from = next;
        int added = 0;
        for (final String line in lines) {
          final (String, String)? record = splitAiLineRecord(line);
          final int? id = record == null ? null : int.tryParse(record.$1);
          if (id == null || id < from || id >= hi) continue;
          if (got.containsKey('$id')) continue;
          got['$id'] = record!.$2;
          added++;
          if (id >= next) next = id + 1;
        }
        return added;
      },
      done: (AiLineReply reply) => reply.complete || next >= hi,
      failureDetail: () =>
          'proofread batch $lo-$hi: no complete reply from id $next',
      usage: usage,
      cancel: cancel,
      maxAttempts: maxAttempts,
    );
    await _writeBatchCache(cache, got, usage);
    return (got, usage);
  }

  static Map<String, Object?>? _readBatchCache(
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
      // 半截文件（写到一半进程被杀）：当作没有，重问这一批。
      return null;
    }
  }

  static Future<void> _writeBatchCache(
    File cache,
    Map<String, Object?> fix,
    SubtitleAiUsageTally usage,
  ) => writeSubtitleJobFileAtomic(
    cache,
    const JsonEncoder.withIndent(
      ' ',
    ).convert(<String, Object?>{'fix': fix, 'usage': usage.toJson()}),
  );
}

/// 一批的完整提示词（同 `llm_fix.py` 的 `batch_prompt`；候选稿按序号标注）=
/// [buildProofreadStablePrefix] + [buildProofreadBatchBody]（[joinAiTextPrompt]）。
String buildProofreadBatchPrompt({
  required List<SubtitleDraftCue> cues,
  required int lo,
  required int hi,
  required String title,
  required String glossaryText,
  int contextLines = 3,
}) => joinAiTextPrompt(
  buildProofreadStablePrefix(title: title, glossaryText: glossaryText),
  buildProofreadBatchBody(
    cues: cues,
    lo: lo,
    hi: hi,
    contextLines: contextLines,
  ),
);

/// 同一作品各批逐字相同的前缀：规则 + 作品名 + 专名表（提示缓存的命中段）。
String buildProofreadStablePrefix({
  required String title,
  required String glossaryText,
}) {
  final List<String> lines = <String>[
    kSubtitleProofreadRules,
    '',
    '作品名: $title',
  ];
  if (glossaryText.isNotEmpty) {
    lines
      ..add('固有名詞表:')
      ..add(glossaryText);
  }
  return lines.join('\n');
}

/// 一批自己的内容：前后只读上下文 + 待校对的行。[only] 非 null 时只把其中的 id 列为
/// 校对对象（补问上一次没答到的行），批内其余行原位写成只读参考。
String buildProofreadBatchBody({
  required List<SubtitleDraftCue> cues,
  required int lo,
  required int hi,
  int contextLines = 3,
  Set<int>? only,
}) {
  final List<String> lines = <String>['\n参考(直前の行、修正不要):'];
  for (int i = lo - contextLines < 0 ? 0 : lo - contextLines; i < lo; i++) {
    lines.add('  [${formatProofreadTime(cues[i].startMs)}] ${cues[i].text}');
  }
  lines.add('\n対象:');
  for (int i = lo; i < hi; i++) {
    final SubtitleDraftCue c = cues[i];
    if (only != null && !only.contains(i)) {
      // 补问剩下的 id 时，已答过的行留在原位当只读上下文。
      lines.add('  参考 [${formatProofreadTime(c.startMs)}] ${c.text}');
      continue;
    }
    lines.add(
      'id=$i [${formatProofreadTime(c.startMs)}-'
      '${formatProofreadTime(c.endMs)}] 主: ${c.text}',
    );
    for (int k = 0; k < c.alternatives.length; k++) {
      if (c.alternatives[k].trim().isEmpty) continue;
      lines.add('    候補(${k + 1}): ${c.alternatives[k]}');
    }
  }
  lines.add('\n参考(直後の行、修正不要):');
  final int end = hi + contextLines > cues.length
      ? cues.length
      : hi + contextLines;
  for (int i = hi; i < end; i++) {
    lines.add('  [${formatProofreadTime(cues[i].startMs)}] ${cues[i].text}');
  }
  return lines.join('\n');
}

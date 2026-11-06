/// 语音转录稿的可选 LLM 校对：按块把文本交给大模型修错字、补标点，
/// **绝不改变 cue 数量与时间轴**。
///
/// 与视频字幕管线的 S3（`subtitle_proofreader.dart`）的区别都是有意的：
/// - 通用语言（不限日语），只修明显误识别与缺失标点；
/// - **不许删行**：转录产物 `transcript.srt` 与逐 token sidecar
///   `transcript.tokens.jsonl` 按行号一一配对，行数一变下游
///   （`attachAsrCueTokenTiming`）一条都不挂；
/// - 回复不合格（不是 JSON / id 集合不符 / 值不是字符串或为空）**整批放弃、保持原文**，
///   不重试；只有请求本身失败才让整次运行失败。
///
/// 文件级入口 [proofreadAsrTranscriptFile] 在同目录留原稿备份
/// （[kAsrRawTranscriptFileName] / [kAsrRawCueTokensFileName]），重跑总从原稿出发，
/// [restoreAsrTranscriptOriginal] 可还原。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_asr_core/asr_core.dart'
    show
        AsrCue,
        AsrCueTokenTiming,
        AsrJobFiles,
        parseAsrCueTokenTimings,
        serializeAsrCueTokens,
        serializeAsrCuesToSrt;
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:path/path.dart' as p;

/// 原稿 SRT 备份（与 `transcript.srt` 同目录）。只在不存在时写，保住最初的原稿。
const String kAsrRawTranscriptFileName = 'transcript.raw.srt';

/// 原稿逐 token sidecar 备份（与 `transcript.tokens.jsonl` 同目录）。
const String kAsrRawCueTokensFileName = 'transcript.tokens.raw.jsonl';

/// [asrCueWithProofreadText] 做字符级 LCS 的单边长度上限；超过直接线性分配。
const int kAsrProofreadLcsMaxChars = 2000;

/// 提示词里本批目标行那一段的标题行（下一行是 `{"<id>": "<原文>", ...}`）。
const String kAsrProofreadTargetHeader =
    'Lines to proofread (return every id):';

/// 提示词里只读上下文段的标题行（前 / 后）。
const String kAsrProofreadContextBeforeHeader =
    'Read-only context before (do not return these ids):';
const String kAsrProofreadContextAfterHeader =
    'Read-only context after (do not return these ids):';

/// 校对规则（[AiTextCompleter.complete] 的 `stablePrefix`：同一次运行各批逐字相同）。
String buildAsrProofreadStablePrefix({String? languageTag}) {
  final StringBuffer sb = StringBuffer()
    ..writeln(
      'You are proofreading a speech-recognition (ASR) dictation transcript. '
      'Each line is one subtitle cue that is timed to the audio.',
    );
  if (languageTag != null && languageTag.trim().isNotEmpty) {
    sb.writeln('The transcript language is "${languageTag.trim()}".');
  }
  sb
    ..writeln('Rules:')
    ..writeln(
      '1. Only fix obvious misrecognitions (wrong homophones, garbled or '
      'truncated words, wrong word boundaries) and add missing punctuation, '
      'especially sentence-final punctuation.',
    )
    ..writeln(
      '2. Do not translate, paraphrase, summarize or polish the style. Keep '
      'fillers, hesitations, repetitions and dialect as spoken.',
    )
    ..writeln(
      '3. Never merge, split, add, remove or reorder lines. Each id maps to '
      'exactly its original line; when a sentence continues onto the next '
      'line, keep each part on its own line.',
    )
    ..writeln('4. If you are not sure, keep the original text unchanged.')
    ..writeln(
      '5. Read-only context lines are only for understanding; do not return '
      'them.',
    )
    ..write(
      'Output only a JSON object {"<id>": "<corrected text>", ...} that '
      'contains exactly every id listed under "$kAsrProofreadTargetHeader" '
      'and no other id. No explanations, no code fences.',
    );
  return sb.toString();
}

/// 本批内容（[AiTextCompleter.complete] 的 `prompt`）：前后只读上下文 + 目标行，
/// 每段一行 JSON 对象（id = cue 在整份稿里的下标）。
String buildAsrProofreadBatchBody({
  required List<AsrCue> cues,
  required List<int> targets,
  required List<int> contextBefore,
  required List<int> contextAfter,
}) {
  String section(List<int> ids) =>
      jsonEncode(<String, String>{for (final int i in ids) '$i': cues[i].text});
  final StringBuffer sb = StringBuffer();
  if (contextBefore.isNotEmpty) {
    sb
      ..writeln(kAsrProofreadContextBeforeHeader)
      ..writeln(section(contextBefore));
  }
  sb
    ..writeln(kAsrProofreadTargetHeader)
    ..write(section(targets));
  if (contextAfter.isNotEmpty) {
    sb
      ..writeln()
      ..writeln(kAsrProofreadContextAfterHeader)
      ..write(section(contextAfter));
  }
  return sb.toString();
}

/// 一次校对的结果与统计。
class AsrTranscriptProofreadOutcome {
  const AsrTranscriptProofreadOutcome({
    required this.cues,
    required this.totalBatches,
    required this.appliedBatches,
    required this.skippedBatches,
    required this.changedCues,
    required this.usage,
  });

  /// 校对后的 cue：长度恒等于输入，起止时间与 audioFileIndex 逐条不变。
  final List<AsrCue> cues;
  final int totalBatches;

  /// 回复合格、已应用的批数（含没有可校对行、无需请求的批）。
  final int appliedBatches;

  /// 回复不合格、整批保持原文的批数。
  final int skippedBatches;

  /// 文本有变化的 cue 数。
  final int changedCues;
  final SubtitleAiUsageTally usage;
}

/// 一批回复的判定。
sealed class _BatchVerdict {
  const _BatchVerdict();
}

final class _BatchApplied extends _BatchVerdict {
  const _BatchApplied(this.fix);
  final Map<int, String> fix;
}

final class _BatchSkipped extends _BatchVerdict {
  const _BatchSkipped(this.reason);

  /// 脱敏短码（不含回复原文与 id）。
  final String reason;
}

/// 转录稿校对器。无状态，可复用。
class AsrTranscriptProofreader {
  AsrTranscriptProofreader({
    required this.completer,
    this.batchSize = 40,
    this.contextLines = 2,
    this.concurrency = 4,
    this.languageTag,
    this.log,
  }) : assert(batchSize > 0 && contextLines >= 0 && concurrency > 0);

  final AiTextCompleter completer;
  final int batchSize;
  final int contextLines;

  /// 同时在途的批数（限频由 `AiChatClient` 把关）。app 按提供商传
  /// `AiProviderConfig.batchConcurrency`，与视频字幕校对同一个推算。
  final int concurrency;

  /// 稿子的语言（BCP 47 等）；非空时写进提示词。
  final String? languageTag;
  final void Function(String message)? log;

  /// 校对 [cues]。回复不合格的批保持原文；请求失败（[SubtitleAiRequestFailure]）
  /// 等在途批结束后原样抛出；取消抛 [SubtitlePipelineCancelled]。
  Future<AsrTranscriptProofreadOutcome> proofread(
    List<AsrCue> cues, {
    SubtitleCancelToken cancel = const SubtitleNeverCancel(),
    void Function(int doneBatches, int totalBatches)? onProgress,
  }) async {
    final List<(int, int)> ranges = <(int, int)>[
      for (int lo = 0; lo < cues.length; lo += batchSize)
        (lo, math.min(lo + batchSize, cues.length)),
    ];
    final String prefix = buildAsrProofreadStablePrefix(
      languageTag: languageTag,
    );
    final List<Map<int, String>?> fixes = List<Map<int, String>?>.filled(
      ranges.length,
      null,
    );
    final SubtitleAiUsageTally usage = SubtitleAiUsageTally();
    int next = 0;
    int done = 0;
    int applied = 0;
    int skipped = 0;
    Object? firstError;
    StackTrace? firstStack;

    Future<void> worker() async {
      while (firstError == null && next < ranges.length) {
        final int index = next++;
        try {
          throwIfSubtitleCancelled(cancel);
          final _BatchVerdict verdict = await _batch(
            cues,
            ranges[index],
            prefix,
            usage,
          );
          switch (verdict) {
            case _BatchApplied(:final Map<int, String> fix):
              fixes[index] = fix;
              applied++;
            case _BatchSkipped(:final String reason):
              skipped++;
              log?.call(
                'ASR proofread: batch ${index + 1}/${ranges.length} '
                'kept original text ($reason)',
              );
          }
          onProgress?.call(++done, ranges.length);
        } catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        }
      }
    }

    await Future.wait(<Future<void>>[
      for (int w = 0; w < math.min(concurrency, ranges.length); w++) worker(),
    ]);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
    throwIfSubtitleCancelled(cancel);

    final List<AsrCue> out = List<AsrCue>.of(cues);
    int changed = 0;
    for (final Map<int, String>? fix in fixes) {
      if (fix == null) continue;
      fix.forEach((int i, String text) {
        if (text == cues[i].text) return;
        out[i] = asrCueWithProofreadText(cues[i], text);
        changed++;
      });
    }
    return AsrTranscriptProofreadOutcome(
      cues: List<AsrCue>.unmodifiable(out),
      totalBatches: ranges.length,
      appliedBatches: applied,
      skippedBatches: skipped,
      changedCues: changed,
      usage: usage,
    );
  }

  Future<_BatchVerdict> _batch(
    List<AsrCue> cues,
    (int, int) range,
    String prefix,
    SubtitleAiUsageTally usage,
  ) async {
    final (int lo, int hi) = range;
    // 空文本行不送校对（也不会被改）；整批都空就不必请求。
    final List<int> targets = <int>[
      for (int i = lo; i < hi; i++)
        if (cues[i].text.trim().isNotEmpty) i,
    ];
    if (targets.isEmpty) return const _BatchApplied(<int, String>{});
    final String body = buildAsrProofreadBatchBody(
      cues: cues,
      targets: targets,
      contextBefore: <int>[
        for (int i = math.max(0, lo - contextLines); i < lo; i++) i,
      ],
      contextAfter: <int>[
        for (int i = hi; i < math.min(cues.length, hi + contextLines); i++) i,
      ],
    );
    final AiChatCompletion reply = await completer.complete(
      body,
      stablePrefix: prefix,
    );
    usage.addCall(reply.usage);
    return _validateReply(reply.text, targets);
  }
}

/// 校验一批回复：必须是 JSON 对象、键集合恰好等于 [targets]、值都是非空字符串。
/// 值里的换行换成空格并 trim。不合格返回 [_BatchSkipped]（整批放弃）。
_BatchVerdict _validateReply(String reply, List<int> targets) {
  final Object? decoded = decodeLooseAiJson(reply);
  if (decoded is! Map) return const _BatchSkipped('reply_not_json_object');
  final Set<String> want = <String>{for (final int i in targets) '$i'};
  final Set<String> got = <String>{for (final Object? k in decoded.keys) '$k'};
  if (got.length != decoded.length ||
      got.length != want.length ||
      !got.containsAll(want)) {
    return _BatchSkipped(
      'reply_id_mismatch: expected ${want.length}, got ${got.length}',
    );
  }
  final Map<int, String> fix = <int, String>{};
  for (final MapEntry<Object?, Object?> e in decoded.entries) {
    final Object? v = e.value;
    if (v is! String) return const _BatchSkipped('reply_value_not_string');
    final String text = v.replaceAll(RegExp(r'\r\n|\r|\n'), ' ').trim();
    if (text.isEmpty) return const _BatchSkipped('reply_value_empty');
    fix[int.parse('${e.key}')] = text;
  }
  return _BatchApplied(fix);
}

/// 把 [cue] 的文本换成 [text]，并重建逐 token 时间：新文本按字符（Unicode 码点）
/// 每字一个 token，`tokens.join() == text`，三个列表等长。
///
/// 时间来自旧 token：旧 tokens 拼接串按字符展开（每字继承所属旧 token 的起 / 终
/// 偏移），与新文本做字符级 LCS 对齐；匹配上的字取对应旧字的时间，未匹配的取前一个
/// 已定字的时间（开头未匹配的取其后第一个匹配字的时间）。无任何匹配、旧 cue 没有
/// token、或任一边超过 [kAsrProofreadLcsMaxChars] 字时按 cue 时长线性分配。偏移单调
/// 不降、夹到 `[0, durationMs]`；旧 cue 无终点（`tokenEndOffsetsMs == null`）时新
/// cue 也没有。起止时间与 audioFileIndex 不变。
AsrCue asrCueWithProofreadText(AsrCue cue, String text) {
  final int duration = math.max(0, cue.durationMs);
  final List<String> newChars = <String>[
    for (final int r in text.runes) String.fromCharCode(r),
  ];
  final bool hasEnds = cue.tokenEndOffsetsMs != null;

  // 旧字符串按码点展开，每字继承所属 token 的时间。
  final List<int> oldRunes = <int>[];
  final List<int> oldStarts = <int>[];
  final List<int> oldEnds = <int>[];
  final bool oldTimingUsable =
      cue.tokens.length == cue.tokenOffsetsMs.length &&
      (!hasEnds || cue.tokenEndOffsetsMs!.length == cue.tokens.length);
  if (oldTimingUsable) {
    for (int t = 0; t < cue.tokens.length; t++) {
      for (final int r in cue.tokens[t].runes) {
        oldRunes.add(r);
        oldStarts.add(cue.tokenOffsetsMs[t]);
        oldEnds.add(hasEnds ? cue.tokenEndOffsetsMs![t] : 0);
      }
    }
  }

  final int n = newChars.length;
  final List<int> starts = List<int>.filled(n, 0);
  final List<int> ends = List<int>.filled(n, 0);
  final List<int> newRunes = text.runes.toList(growable: false);
  final List<int>? match =
      oldRunes.isEmpty ||
          n == 0 ||
          oldRunes.length > kAsrProofreadLcsMaxChars ||
          n > kAsrProofreadLcsMaxChars
      ? null
      : _lcsMatch(oldRunes, newRunes);

  if (match == null || match.every((int m) => m < 0)) {
    for (int k = 0; k < n; k++) {
      starts[k] = duration * k ~/ n;
      ends[k] = duration * (k + 1) ~/ n;
    }
  } else {
    final int firstMatched = match.indexWhere((int m) => m >= 0);
    int prevStart = oldStarts[match[firstMatched]];
    int prevEnd = oldEnds[match[firstMatched]];
    for (int k = 0; k < n; k++) {
      final int m = match[k];
      if (m >= 0) {
        prevStart = oldStarts[m];
        prevEnd = oldEnds[m];
      }
      starts[k] = prevStart;
      ends[k] = prevEnd;
    }
  }

  // 夹到 [0, duration] 并单调不降；终点不早于同 token 起点。
  int lastStart = 0;
  int lastEnd = 0;
  for (int k = 0; k < n; k++) {
    final int s = math.max(lastStart, starts[k].clamp(0, duration));
    starts[k] = s;
    lastStart = s;
    if (hasEnds) {
      final int e = math.max(math.max(lastEnd, s), ends[k].clamp(0, duration));
      ends[k] = e;
      lastEnd = e;
    }
  }

  return AsrCue(
    startMs: cue.startMs,
    endMs: cue.endMs,
    text: text,
    audioFileIndex: cue.audioFileIndex,
    tokens: List<String>.unmodifiable(newChars),
    tokenOffsetsMs: List<int>.unmodifiable(starts),
    tokenEndOffsetsMs: hasEnds ? List<int>.unmodifiable(ends) : null,
  );
}

/// 字符级 LCS：返回长度 = [b].length 的数组，`result[j]` = 与 `b[j]` 匹配的 `a`
/// 下标，未匹配为 -1。
List<int> _lcsMatch(List<int> a, List<int> b) {
  final int n = a.length;
  final int m = b.length;
  final int w = m + 1;
  // dp[i][j] = a[i..] 与 b[j..] 的 LCS 长度（后缀表，便于正向回溯）。
  final Uint16List dp = Uint16List((n + 1) * w);
  for (int i = n - 1; i >= 0; i--) {
    for (int j = m - 1; j >= 0; j--) {
      dp[i * w + j] = a[i] == b[j]
          ? dp[(i + 1) * w + j + 1] + 1
          : math.max(dp[(i + 1) * w + j], dp[i * w + j + 1]);
    }
  }
  final List<int> result = List<int>.filled(m, -1);
  int i = 0;
  int j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      result[j] = i;
      i++;
      j++;
    } else if (dp[(i + 1) * w + j] >= dp[i * w + j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// 文件级
// ---------------------------------------------------------------------------

/// 文件级校对结果。
class AsrTranscriptProofreadFileOutcome {
  const AsrTranscriptProofreadFileOutcome({
    required this.result,
    required this.tokenSidecarWritten,
  });

  final AsrTranscriptProofreadOutcome result;

  /// 是否写回了逐 token sidecar（输入有合法 sidecar 时才写）。
  final bool tokenSidecarWritten;

  int get cueCount => result.cues.length;
  int get totalBatches => result.totalBatches;
  int get appliedBatches => result.appliedBatches;
  int get skippedBatches => result.skippedBatches;
  int get changedCues => result.changedCues;
  SubtitleAiUsageTally get usage => result.usage;
}

String _rawSrtPath(String srtPath) =>
    p.join(p.dirname(srtPath), kAsrRawTranscriptFileName);

String _cueTokensPath(String srtPath) =>
    p.join(p.dirname(srtPath), AsrJobFiles.cueTokens);

String _rawCueTokensPath(String srtPath) =>
    p.join(p.dirname(srtPath), kAsrRawCueTokensFileName);

/// [srtPath] 同目录是否有校对前的原稿备份。
bool asrTranscriptHasProofreadBackup(String srtPath) =>
    File(_rawSrtPath(srtPath)).existsSync();

/// 把原稿备份拷回 [srtPath]（与同目录 sidecar，备份存在时）。没有备份返回 false。
/// 还原后保留备份文件。
Future<bool> restoreAsrTranscriptOriginal(String srtPath) async {
  final File rawSrt = File(_rawSrtPath(srtPath));
  if (!rawSrt.existsSync()) return false;
  await _writeAtomic(srtPath, await rawSrt.readAsBytes());
  final File rawTokens = File(_rawCueTokensPath(srtPath));
  if (rawTokens.existsSync()) {
    await _writeAtomic(_cueTokensPath(srtPath), await rawTokens.readAsBytes());
  }
  return true;
}

/// 校对 [srtPath]（转录产物）并原子写回；同目录 sidecar 合法时一并重写。
///
/// - 原稿备份只在不存在时写；校对输入优先读备份（重跑总从原稿出发）。
/// - sidecar 解析失败或行数与 cue 数不等：当作没有 token 时间，且不写 sidecar
///   （也不删已有的）。
/// - 请求失败 / 取消原样抛出，[srtPath] 与 sidecar 不动。
Future<AsrTranscriptProofreadFileOutcome> proofreadAsrTranscriptFile({
  required String srtPath,
  required AsrTranscriptProofreader proofreader,
  SubtitleCancelToken cancel = const SubtitleNeverCancel(),
  void Function(int doneBatches, int totalBatches)? onProgress,
}) async {
  final File srtFile = File(srtPath);
  final File rawSrt = File(_rawSrtPath(srtPath));
  final File tokensFile = File(_cueTokensPath(srtPath));
  final File rawTokens = File(_rawCueTokensPath(srtPath));

  if (!rawSrt.existsSync()) {
    await _writeAtomic(rawSrt.path, await srtFile.readAsBytes());
  }
  if (!rawTokens.existsSync() && tokensFile.existsSync()) {
    await _writeAtomic(rawTokens.path, await tokensFile.readAsBytes());
  }

  final List<AsrCue> parsed = parseAsrTranscriptSrt(
    await rawSrt.readAsString(),
  );
  final File tokensSource = rawTokens.existsSync() ? rawTokens : tokensFile;
  List<AsrCueTokenTiming>? timings;
  if (tokensSource.existsSync()) {
    try {
      timings = parseAsrCueTokenTimings(await tokensSource.readAsString());
    } on FormatException {
      timings = null;
    }
    if (timings != null && timings.length != parsed.length) timings = null;
  }
  final List<AsrCue> input = timings == null
      ? parsed
      : <AsrCue>[
          for (int i = 0; i < parsed.length; i++)
            AsrCue(
              startMs: parsed[i].startMs,
              endMs: parsed[i].endMs,
              text: parsed[i].text,
              audioFileIndex: parsed[i].audioFileIndex,
              tokens: timings[i].tokens,
              tokenOffsetsMs: timings[i].offsetsMs,
              tokenEndOffsetsMs: timings[i].endOffsetsMs,
            ),
        ];

  final AsrTranscriptProofreadOutcome result = await proofreader.proofread(
    input,
    cancel: cancel,
    onProgress: onProgress,
  );
  throwIfSubtitleCancelled(cancel);

  final List<AsrCue> out = result.cues;
  if (out.length != input.length) {
    throw StateError(
      'ASR proofread changed cue count: ${input.length} -> ${out.length}',
    );
  }
  for (int i = 0; i < out.length; i++) {
    if (out[i].startMs != input[i].startMs || out[i].endMs != input[i].endMs) {
      throw StateError('ASR proofread changed timing of cue $i');
    }
    // serializeAsrCuesToSrt / serializeAsrCueTokens 跳过空文本 cue：出现就会错行。
    if (out[i].text.isEmpty) {
      throw StateError('ASR proofread produced an empty cue at $i');
    }
  }

  await _writeAtomic(srtPath, utf8.encode(serializeAsrCuesToSrt(out)));
  final bool writeTokens = timings != null;
  if (writeTokens) {
    await _writeAtomic(
      tokensFile.path,
      utf8.encode(serializeAsrCueTokens(out)),
    );
  }
  return AsrTranscriptProofreadFileOutcome(
    result: result,
    tokenSidecarWritten: writeTokens,
  );
}

final RegExp _srtTimingLine = RegExp(
  r'^(\d{2,}):(\d{2}):(\d{2}),(\d{3}) --> (\d{2,}):(\d{2}):(\d{2}),(\d{3})$',
);

/// 严格解析 `serializeAsrCuesToSrt` 的产物（容忍 `\r\n` 与 BOM）。序号必须从 1
/// 连续递增、时间行必须是 `HH:MM:SS,mmm --> HH:MM:SS,mmm`、正文非空；多行正文以
/// 空格拼接。不合格抛 [FormatException]。audioFileIndex 一律为 0（SRT 不带）。
List<AsrCue> parseAsrTranscriptSrt(String source) {
  String text = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (text.startsWith('﻿')) text = text.substring(1);
  final List<String> lines = text.split('\n');
  final List<AsrCue> out = <AsrCue>[];
  int i = 0;
  int ms(RegExpMatch m, int g) =>
      int.parse(m.group(g)!) * 3600000 +
      int.parse(m.group(g + 1)!) * 60000 +
      int.parse(m.group(g + 2)!) * 1000 +
      int.parse(m.group(g + 3)!);
  while (true) {
    while (i < lines.length && lines[i].trim().isEmpty) {
      i++;
    }
    if (i >= lines.length) break;
    final int expected = out.length + 1;
    if (int.tryParse(lines[i].trim()) != expected) {
      throw FormatException('SRT: expected cue index $expected', source, i);
    }
    i++;
    final RegExpMatch? timing = i < lines.length
        ? _srtTimingLine.firstMatch(lines[i].trim())
        : null;
    if (timing == null) {
      throw FormatException('SRT: bad timing line for cue $expected');
    }
    i++;
    final List<String> body = <String>[];
    while (i < lines.length && lines[i].trim().isNotEmpty) {
      body.add(lines[i].trim());
      i++;
    }
    final String cueText = body.join(' ');
    if (cueText.isEmpty) {
      throw FormatException('SRT: empty text for cue $expected');
    }
    out.add(
      AsrCue(
        startMs: ms(timing, 1),
        endMs: ms(timing, 5),
        text: cueText,
        audioFileIndex: 0,
      ),
    );
  }
  return out;
}

/// 先写 `<path>.tmp` 再 rename 覆盖。
Future<void> _writeAtomic(String path, List<int> bytes) async {
  final File tmp = File('$path.tmp');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(path);
}

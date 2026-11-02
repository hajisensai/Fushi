/// S5 纯歌曲判定：短视频（< [kSubtitleShortClipMs]）整段交给 AI 判 `song` /
/// `dialogue` / `mixed`；`song`（NC OP/ED、MV）不导出字幕。移植自基准
/// `subtitle_series.py` 的 `classify_clips`（提示词原样搬）。
///
/// 只靠按行规则抓不住片头曲：英日混唱，行长不规则。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';

/// 短于这个时长（5 分钟）的视频才做整段判定（同 `SHORT_S = 300`）。
const int kSubtitleShortClipMs = 300000;

/// 整段判定结果。
enum SubtitleClipKind {
  song,
  dialogue,
  mixed;

  static SubtitleClipKind? fromName(Object? name) {
    for (final SubtitleClipKind k in values) {
      if (k.name == name) return k;
    }
    return null;
  }
}

/// `CLIP_PROMPT`（除输出格式一句外逐字照搬：基准是 JSON，这里走行协议）。占位符
/// `{title}` / `{clips}`。
const String kSubtitleClipPrompt =
    '''日本のアニメ「{title}」の特典映像・短編の音声認識テキストです(誤認識を含む)。各映像が何かを判定してください。
- song: 歌だけの映像(ノンクレジットOP/ED、MV など)。台詞がほぼ無い。
- dialogue: 台詞が主体(ショートアニメ、ドラマ、コメンタリー等)。
- mixed: 台詞と歌が混在(予告・PV・CM など)。
出力は 1 行 1 件: <id><TAB>song / dialogue / mixed のどれか。全ての id を書き、最後の行に END とだけ書く。説明文は書かない。

{clips}''';

/// [kSubtitleClipPrompt] 里 `{clips}` 之前的部分（规则 + 作品名），拆在 `{clips}`
/// 前的空行的第一个换行上：`joinAiTextPrompt(前缀, 片段)` 与整段替换逐字相同。
String buildClipClassifyStablePrefix(String title) {
  const String marker = '\n{clips}';
  return kSubtitleClipPrompt
      .substring(0, kSubtitleClipPrompt.indexOf(marker))
      .replaceAll('{title}', title);
}

/// 判定结果与用量。
class SubtitleClipClassification {
  const SubtitleClipClassification({required this.kinds, required this.usage});

  /// clip id → 种类（含缓存里已有的）。
  final Map<String, SubtitleClipKind> kinds;
  final SubtitleAiUsageTally usage;
}

class SubtitleClipClassifier {
  SubtitleClipClassifier({required this.completer, this.maxAttempts = 3});

  final AiTextCompleter completer;
  final int maxAttempts;

  /// [clips]：clip id → 该段（校对后）的字幕文本行。缓存 [cacheFile]
  /// （`clip_kinds.json`，`{"kinds": {id: kind}, "usage": {...}}`）里已有的 id 不再问；
  /// 其余**一次请求**问完（行协议，[runAiLineExchange]）；漏判的下一轮只补问漏的，
  /// 全部待判 id 都拿到合法值才写缓存。
  Future<SubtitleClipClassification> classify({
    required Map<String, List<String>> clips,
    required String title,
    required File cacheFile,
    SubtitleCancelToken cancel = const SubtitleNeverCancel(),
  }) async {
    final SubtitleAiUsageTally usage = SubtitleAiUsageTally();
    final Map<String, SubtitleClipKind> kinds = _readCache(cacheFile, usage);
    final List<String> todo = <String>[
      for (final String id in clips.keys)
        if (!kinds.containsKey(id)) id,
    ];
    if (todo.isEmpty) {
      return SubtitleClipClassification(kinds: kinds, usage: usage);
    }
    final SubtitleAiUsageTally fresh = SubtitleAiUsageTally();
    final Map<String, SubtitleClipKind> parsed = <String, SubtitleClipKind>{};
    await runAiLineExchange(
      completer: completer,
      stablePrefix: buildClipClassifyStablePrefix(title),
      body: () => <String>[
        for (final String id in todo)
          if (!parsed.containsKey(id)) 'id=$id\n${clips[id]!.join('\n')}',
      ].join('\n\n'),
      absorb: (List<String> lines) {
        int added = 0;
        for (final String line in lines) {
          final (String, String)? record = splitAiLineRecord(line);
          if (record == null || !clips.containsKey(record.$1)) continue;
          final SubtitleClipKind? k = SubtitleClipKind.fromName(
            record.$2.trim(),
          );
          if (k == null || kinds.containsKey(record.$1)) continue;
          if (parsed.containsKey(record.$1)) continue;
          parsed[record.$1] = k;
          added++;
        }
        return added;
      },
      done: (AiLineReply reply) => parsed.length == todo.length,
      failureDetail: () =>
          'clip classification: reply missing '
          '${todo.length - parsed.length} ids',
      usage: fresh,
      cancel: cancel,
      maxAttempts: maxAttempts,
    );
    kinds.addAll(parsed);
    usage.addTally(fresh);
    await _writeCache(cacheFile, kinds, usage);
    return SubtitleClipClassification(kinds: kinds, usage: usage);
  }

  static Map<String, SubtitleClipKind> _readCache(
    File cache,
    SubtitleAiUsageTally usage,
  ) {
    final Map<String, SubtitleClipKind> out = <String, SubtitleClipKind>{};
    if (!cache.existsSync()) return out;
    try {
      final Object? decoded = jsonDecode(cache.readAsStringSync());
      if (decoded is! Map) return out;
      final Object? k = decoded['kinds'];
      if (k is Map) {
        k.forEach((Object? id, Object? v) {
          final SubtitleClipKind? kind = SubtitleClipKind.fromName(v);
          if (kind != null) out['$id'] = kind;
        });
      }
      final Object? u = decoded['usage'];
      if (u is Map) {
        usage.addTally(
          SubtitleAiUsageTally.fromJson(u.cast<String, Object?>()),
        );
      }
    } on FormatException {
      return <String, SubtitleClipKind>{};
    }
    return out;
  }

  static Future<void> _writeCache(
    File cache,
    Map<String, SubtitleClipKind> kinds,
    SubtitleAiUsageTally usage,
  ) => writeSubtitleJobFileAtomic(
    cache,
    const JsonEncoder.withIndent(' ').convert(<String, Object?>{
      'kinds': <String, String>{
        for (final MapEntry<String, SubtitleClipKind> e in kinds.entries)
          e.key: e.value.name,
      },
      'usage': usage.toJson(),
    }),
  );
}

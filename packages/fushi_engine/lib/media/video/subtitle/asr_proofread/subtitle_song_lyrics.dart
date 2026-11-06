/// S4s 歌词补齐（spec `2026-11-04-video-subtitle-multisource-evidence` §5）：识别稿里
/// 唱歌的段落（OP / ED / 插曲）认出是哪首歌、上网查到正确歌词、逐行对到识别稿的
/// 歌唱行上，替换掉误认识严重的歌词。
///
/// ```
/// 歌唱行（♪ / 证据里的歌词行）─分段─▶ 每段：认歌（AI）─▶ 查歌词（LRCLIB / 联网搜索）
///   ─▶ 逐行对齐（AI，行协议）─▶ 校验（歌词必须逐字来自查到的歌词 + 字面相似度）─▶ 替换
/// ```
///
/// - 时间轴仍来自识别稿；只换文字（保留 `♪` 前缀），[SubtitleDraftCue.origin] 记
///   `lyrics:<来源>`。
/// - 宁可不补也不贴错歌：对齐结果的覆盖率 / 相似度不达标整段放弃。
/// - 注音：只用来源自带的文字，**不**机器推断振假名（功能黑名单）。
/// - 每段结果（含「没认出 / 没查到」）落 `<任务目录>/lyrics.json`，重跑不再花钱。
/// - AI 请求失败（额度 / 鉴权 / 网络）照常抛出暂停整个任务；回复反复不合格只放弃这一段
///   （歌词是可选增强，不该让整集导出失败）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_core/fushi_core.dart' show fushiDebugPrint;
import 'package:fushi_engine/ai/ai_chat_client.dart' show AiChatCompletion;
import 'package:fushi_engine/ai/web_search.dart';
import 'package:fushi_engine/media/music/lrclib_client.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_language.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_prompts_zh.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_proofreader.dart'
    show formatProofreadTime;

/// 提示词 / 校验规则版本：改了它，`lyrics.json` 里的旧结果作废。
const int kSubtitleLyricsVersion = 1;

/// 歌唱行之间隔超过它就算另一段。
const int kSubtitleSongSpanMaxGapMs = 8000;

/// 一段至少这么多行歌唱行才补（零星一两句哼唱不值得查）。
const int kSubtitleSongSpanMinCues = 3;

/// 对上歌词的行至少占这一段歌唱行的比例。
const double kSubtitleLyricsMinCoverage = 0.5;

/// 对上的行「识别稿 ↔ 歌词」字符二元组 Dice 的均值下限（唱歌的识别稿错得厉害，
/// 但贴错歌时均值通常不到 0.1）。
const double kSubtitleLyricsMinSimilarity = 0.25;

/// 一段歌。
class SubtitleSongSpan {
  const SubtitleSongSpan({
    required this.cueIndexes,
    required this.startMs,
    required this.endMs,
    this.evidenceLines = const <String>[],
  });

  /// 这一段的歌唱行在字幕稿里的下标（升序）。
  final List<int> cueIndexes;
  final int startMs;
  final int endMs;

  /// 同时段证据里的歌词行（字幕组的卡拉 OK / 翻译歌词），认歌用。
  final List<String> evidenceLines;
}

final RegExp _songMark = RegExp(r'^[\s　]*[♪♫♬]');

/// 一行是不是歌唱行：`♪` 起头（S4 标的），或与证据里的歌词行重叠过半。
bool _isSungCue(SubtitleDraftCue cue, List<SubtitleEvidenceCue> songEvidence) {
  if (_songMark.hasMatch(cue.text)) return true;
  final int length = cue.endMs - cue.startMs;
  if (length <= 0) return false;
  int overlap = 0;
  for (final SubtitleEvidenceCue s in songEvidence) {
    if (s.startMs >= cue.endMs) break;
    overlap += subtitleOverlapMs(cue.startMs, cue.endMs, s.startMs, s.endMs);
  }
  return overlap * 2 >= length;
}

/// 这一行是不是换成了查到的正确歌词（S4s 的产物）。
bool isSubtitleLyricsCue(SubtitleDraftCue cue) =>
    cue.origin?.startsWith('lyrics:') ?? false;

/// 找出字幕稿里的歌曲段。[allSung]：整段都是歌（被判为纯歌曲的短片），全部行一段。
List<SubtitleSongSpan> detectSubtitleSongSpans(
  List<SubtitleDraftCue> cues, {
  List<SubtitleEvidenceTrack> evidence = const <SubtitleEvidenceTrack>[],
  bool allSung = false,
}) {
  final List<SubtitleEvidenceCue> songEvidence =
      <SubtitleEvidenceCue>[
        for (final SubtitleEvidenceTrack t in evidence)
          for (final SubtitleEvidenceCue c in t.cues)
            if (c.role == SubtitleEvidenceRole.song) c,
      ]..sort(
        (SubtitleEvidenceCue a, SubtitleEvidenceCue b) =>
            a.startMs.compareTo(b.startMs),
      );
  if (allSung) {
    return cues.length < kSubtitleSongSpanMinCues
        ? const <SubtitleSongSpan>[]
        : <SubtitleSongSpan>[
            _span(cues, <int>[
              for (int i = 0; i < cues.length; i++) i,
            ], songEvidence),
          ];
  }

  final List<List<int>> groups = <List<int>>[];
  for (int i = 0; i < cues.length; i++) {
    if (!_isSungCue(cues[i], songEvidence)) continue;
    final List<int>? last = groups.isEmpty ? null : groups.last;
    if (last != null &&
        cues[i].startMs - cues[last.last].endMs <= kSubtitleSongSpanMaxGapMs) {
      last.add(i);
    } else {
      groups.add(<int>[i]);
    }
  }
  return <SubtitleSongSpan>[
    for (final List<int> g in groups)
      if (g.length >= kSubtitleSongSpanMinCues) _span(cues, g, songEvidence),
  ];
}

SubtitleSongSpan _span(
  List<SubtitleDraftCue> cues,
  List<int> indexes,
  List<SubtitleEvidenceCue> songEvidence,
) {
  final int start = cues[indexes.first].startMs;
  final int end = cues[indexes.last].endMs;
  final List<String> lines = <String>[];
  for (final SubtitleEvidenceCue s in songEvidence) {
    if (s.endMs < start - 2000 || s.startMs > end + 2000) continue;
    final String text = s.text.replaceAll('\n', ' ').trim();
    if (text.isNotEmpty && !lines.contains(text)) lines.add(text);
    if (lines.length >= 40) break;
  }
  return SubtitleSongSpan(
    cueIndexes: indexes,
    startMs: start,
    endMs: end,
    evidenceLines: lines,
  );
}

// ---------------------------------------------------------------------------
// 查歌词
// ---------------------------------------------------------------------------

/// 一次查歌词的条件。
class SubtitleSongQuery {
  const SubtitleSongQuery({
    required this.workTitle,
    required this.sungLines,
    this.title,
    this.artist,
    this.evidenceLines = const <String>[],
    this.language = VideoSubtitleLanguage.japanese,
  });

  /// 作品名（[VideoSubtitleLanguage.workTitle]：日语取日文原名优先）。
  final String workTitle;

  /// 字幕语言：决定搜索词后缀（`歌詞` / `歌词`）与抽歌词的提示词。
  final VideoSubtitleLanguage language;

  bool get isMandarin => language == VideoSubtitleLanguage.mandarin;

  /// 认出的歌名 / 歌手；认不出为 null。
  final String? title;
  final String? artist;

  /// 识别稿的歌唱行（去 `♪`）。
  final List<String> sungLines;
  final List<String> evidenceLines;
}

/// 查到的一份歌词。
class SubtitleLyricsCandidate {
  const SubtitleLyricsCandidate({required this.source, required this.lines});

  /// 来源（`lrclib` / 网页地址），写进 `origin`。
  final String source;

  /// 歌词正文，一行一句（无时间、无空行）。
  final List<String> lines;
}

/// 查歌词的后端。查不到返回空；网络失败只记日志返回空（不抛）。AI 请求失败照常抛。
abstract interface class SubtitleLyricsFinder {
  Future<List<SubtitleLyricsCandidate>> find(
    SubtitleSongQuery query, {
    required AiTextCompleter completer,
    required SubtitleAiUsageTally usage,
    required SubtitleCancelToken cancel,
  });
}

/// 依次问多个后端，合并结果（先到先试）。
class CompositeSubtitleLyricsFinder implements SubtitleLyricsFinder {
  const CompositeSubtitleLyricsFinder(this.finders);

  final List<SubtitleLyricsFinder> finders;

  @override
  Future<List<SubtitleLyricsCandidate>> find(
    SubtitleSongQuery query, {
    required AiTextCompleter completer,
    required SubtitleAiUsageTally usage,
    required SubtitleCancelToken cancel,
  }) async => <SubtitleLyricsCandidate>[
    for (final SubtitleLyricsFinder f in finders)
      ...await f.find(
        query,
        completer: completer,
        usage: usage,
        cancel: cancel,
      ),
  ];
}

/// 宿主的标准装配：LRCLIB 永远在；配了可用的通用联网搜索就再加网页搜索。
/// [webSearch] 的生命周期归调用方（跑完 `close()`）。
SubtitleLyricsFinder buildSubtitleLyricsFinder({WebSearchClient? webSearch}) =>
    CompositeSubtitleLyricsFinder(<SubtitleLyricsFinder>[
      LrclibSubtitleLyricsFinder(),
      if (webSearch != null && webSearch.isEnabled)
        WebSearchSubtitleLyricsFinder(webSearch),
    ]);

/// LRCLIB：只在认出歌名时查（它按歌名 / 歌手搜，不按歌词全文搜）。
class LrclibSubtitleLyricsFinder implements SubtitleLyricsFinder {
  LrclibSubtitleLyricsFinder({LrclibClient? client, this.maxCandidates = 3})
    : _client = client ?? LrclibClient();

  final LrclibClient _client;
  final int maxCandidates;

  @override
  Future<List<SubtitleLyricsCandidate>> find(
    SubtitleSongQuery query, {
    required AiTextCompleter completer,
    required SubtitleAiUsageTally usage,
    required SubtitleCancelToken cancel,
  }) async {
    final String? title = query.title;
    if (title == null || title.trim().isEmpty) {
      return const <SubtitleLyricsCandidate>[];
    }
    try {
      final List<LrclibRecord> records = await _client.search(
        title: title,
        artist: query.artist,
      );
      return <SubtitleLyricsCandidate>[
        for (final LrclibRecord r in records.take(maxCandidates))
          if (r.syncedLyrics ?? r.plainLyrics case final String raw)
            if (lyricsTextLines(raw) case final List<String> lines
                when lines.isNotEmpty)
              SubtitleLyricsCandidate(source: 'lrclib:${r.id}', lines: lines),
      ];
    } catch (e) {
      fushiDebugPrint('[SubtitleLyrics] lrclib "$title" failed: $e');
      return const <SubtitleLyricsCandidate>[];
    }
  }
}

/// 联网搜索：搜「歌名 歌手 歌詞」（普通话 `歌词`；认不出歌名时搜识别稿里最长的一句），抓前几页正文，
/// 让 AI 只抽出页面里原有的歌词。
class WebSearchSubtitleLyricsFinder implements SubtitleLyricsFinder {
  WebSearchSubtitleLyricsFinder(this.search, {this.maxPages = 3});

  final WebSearchClient search;
  final int maxPages;

  @override
  Future<List<SubtitleLyricsCandidate>> find(
    SubtitleSongQuery query, {
    required AiTextCompleter completer,
    required SubtitleAiUsageTally usage,
    required SubtitleCancelToken cancel,
  }) async {
    if (!search.isEnabled) return const <SubtitleLyricsCandidate>[];
    final String? title = query.title;
    final String suffix = query.isMandarin
        ? SubtitleLyricsLabelsZh.searchSuffix
        : '歌詞';
    final String q = title != null && title.trim().isNotEmpty
        ? '${title.trim()} ${query.artist ?? ''} $suffix'.replaceAll(
            RegExp(r'\s+'),
            ' ',
          )
        : _longestLineQuery(query);
    if (q.isEmpty) return const <SubtitleLyricsCandidate>[];
    final List<WebSearchHit> hits = await search.search(q, limit: maxPages * 2);
    final List<SubtitleLyricsCandidate> out = <SubtitleLyricsCandidate>[];
    for (final WebSearchHit hit in hits) {
      if (out.length >= maxPages) break;
      throwIfSubtitleCancelled(cancel);
      final WebSearchPage? page = await search.fetchPage(
        hit.url,
        title: hit.title,
        maxChars: 16000,
      );
      if (page == null || page.text.trim().length < 80) continue;
      final List<String> lines = await extractLyricsFromPage(
        page: page,
        query: query,
        completer: completer,
        usage: usage,
      );
      if (lines.length >= kSubtitleSongSpanMinCues) {
        out.add(
          SubtitleLyricsCandidate(source: page.url.toString(), lines: lines),
        );
      }
    }
    return out;
  }

  static String _longestLineQuery(SubtitleSongQuery query) {
    String best = '';
    for (final String l in query.sungLines) {
      final String s = stripSongMark(l);
      if (s.length > best.length) best = s;
    }
    if (best.length < 6) return '';
    return '"$best" ${query.isMandarin ? SubtitleLyricsLabelsZh.searchSuffix : '歌詞'}';
  }
}

/// 页面正文 → 歌词行（AI 只抄页面里的原文）。回复不合格返回空。
Future<List<String>> extractLyricsFromPage({
  required WebSearchPage page,
  required SubtitleSongQuery query,
  required AiTextCompleter completer,
  required SubtitleAiUsageTally usage,
}) async {
  final bool zh = query.isMandarin;
  final String heard = query.sungLines.take(4).map(stripSongMark).join(' / ');
  final String song = query.title == null
      ? (zh
            ? SubtitleLyricsLabelsZh.songUnknown.replaceAll('{lines}', heard)
            : '(曲名不明。音声認識: $heard)')
      : '「${query.title}」${query.artist == null ? '' : '(${query.artist})'}';
  final AiChatCompletion reply = await completer.complete(
    zh
        ? '${SubtitleLyricsLabelsZh.song}: $song\n'
              '${SubtitleLyricsLabelsZh.url}: ${page.url}\n\n'
              '${SubtitleLyricsLabelsZh.pageText}\n${page.text}'
        : '曲: $song\nURL: ${page.url}\n\nページ本文:\n${page.text}',
    stablePrefix: zh
        ? kSubtitleLyricsExtractPromptZh
        : kSubtitleLyricsExtractPrompt,
  );
  usage.addCall(reply.usage);
  final AiLineReply parsed = parseAiLineReply(reply);
  if (!parsed.complete) return const <String>[];
  final List<String> lines = <String>[
    for (final String l in parsed.lines)
      if (l.trim().isNotEmpty) l.trim(),
  ];
  if (lines.length == 1 && lines.first == 'NONE') return const <String>[];
  // 只收页面里确实有的行：模型「凭记忆补写」的歌词不能进字幕。
  final String haystack = normalizeLyricsForMatch(page.text);
  return <String>[
    for (final String l in lines)
      if (normalizeLyricsForMatch(l).isNotEmpty &&
          haystack.contains(normalizeLyricsForMatch(l)))
        l,
  ];
}

/// 抽歌词的规则（稳定前缀）。
const String kSubtitleLyricsExtractPrompt =
    '''以下は検索で見つけたウェブページの本文です。指定された曲の歌詞がこのページに載っていれば、その歌詞本文だけを 1 行 1 句でそのまま書き写してください。
- ページに書かれている文字だけを使う。記憶で補ったり、直したり、訳したりしない。
- 作詞・作曲・歌手などのクレジット、広告、サイトの案内、ふりがなの括弧書きは書かない。
- 繰り返しの部分もページの通りに書く。
- このページに指定の曲の歌詞が無ければ NONE とだけ書く。
- 最後の行に END とだけ書く。''';

// ---------------------------------------------------------------------------
// 文本工具
// ---------------------------------------------------------------------------

final RegExp _lrcTag = RegExp(r'\[[^\]]*\]');
final RegExp _lrcMeta = RegExp(
  r'^\s*\[(ar|ti|al|by|offset|length|re|ve|au|la):',
  caseSensitive: false,
);

/// LRC / 纯文本歌词 → 正文行（去时间标签、元数据行、空行）。
List<String> lyricsTextLines(String raw) => <String>[
  for (final String line in const LineSplitter().convert(raw))
    if (!_lrcMeta.hasMatch(line))
      if (line.replaceAll(_lrcTag, '').trim() case final String t
          when t.isNotEmpty)
        t,
];

/// 去掉行首的 `♪`。
String stripSongMark(String text) => text.replaceFirst(_songMark, '').trim();

/// 匹配用的归一化：去空白 / 标点 / 记号，片假名转平假名，全角英数转半角、小写。
String normalizeLyricsForMatch(String text) {
  final StringBuffer out = StringBuffer();
  for (final int rune in text.runes) {
    int r = rune;
    if (r >= 0x30A1 && r <= 0x30F6) r -= 0x60; // カタカナ → ひらがな
    if (r >= 0xFF01 && r <= 0xFF5E) r -= 0xFEE0; // 全角 → 半角
    final String ch = String.fromCharCode(r);
    if (RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(ch)) {
      out.write(ch.toLowerCase());
    }
  }
  return out.toString();
}

/// 字符二元组 Dice 系数（0~1）。
double lyricsBigramDice(String a, String b) {
  final String x = normalizeLyricsForMatch(a);
  final String y = normalizeLyricsForMatch(b);
  if (x.isEmpty || y.isEmpty) return 0;
  if (x.length == 1 || y.length == 1) return x == y ? 1 : 0;
  final Map<String, int> grams = <String, int>{};
  for (int i = 0; i < x.length - 1; i++) {
    final String g = x.substring(i, i + 2);
    grams[g] = (grams[g] ?? 0) + 1;
  }
  int hit = 0;
  for (int i = 0; i < y.length - 1; i++) {
    final String g = y.substring(i, i + 2);
    final int? n = grams[g];
    if (n != null && n > 0) {
      hit++;
      grams[g] = n - 1;
    }
  }
  return 2 * hit / ((x.length - 1) + (y.length - 1));
}

// ---------------------------------------------------------------------------
// 认歌 / 对齐 / 校验
// ---------------------------------------------------------------------------

/// 认歌（稳定前缀）。
const String kSubtitleSongIdentifyPrompt =
    '''日本のアニメの映像の一部で歌われている曲について、音声認識テキスト(誤認識を含む)と、映像に付いていた既存字幕の歌詞行(翻訳やローマ字のことがある)を渡します。どの曲か判断してください。
- 分かれば 1 行で TITLE<TAB>曲名<TAB>歌手 と書く(曲名・歌手は原語の正式表記。歌手が分からなければ空)。
- 確信が持てなければ UNKNOWN とだけ書く。推測で曲名を作らない。
- 最後の行に END とだけ書く。説明文は書かない。''';

/// 对齐（稳定前缀）。
const String kSubtitleLyricsAlignPrompt =
    '''日本のアニメで流れる曲の歌唱部分の音声認識(誤認識が多い)と、その曲の正しい歌詞を渡します。各歌唱行で実際に歌われている歌詞を対応付けてください。
- 出力は 1 行 1 件: <id><TAB><その行で歌われている歌詞>。歌詞は渡した歌詞の行をそのまま書く(1 つの歌唱行が 2 行にまたがるときは全角スペースで繋ぐ)。
- 歌詞のどの部分とも対応しない行(台詞・別の曲・判断できない)は書かない。
- 歌詞に無い言葉を作らない。テレビサイズ等で省かれた部分は飛ばしてよい。
- id の昇順に書き、最後の行に END とだけ書く。説明文は書かない。''';

/// 一段的补齐结果。
class SubtitleSongLyricsFill {
  const SubtitleSongLyricsFill({
    required this.replacements,
    required this.source,
    this.title,
  });

  /// 字幕稿下标 → 新正文（含 `♪`）。
  final Map<int, String> replacements;
  final String source;
  final String? title;
}

/// 一集的歌词补齐结果。
class SubtitleLyricsPassResult {
  const SubtitleLyricsPassResult({
    required this.cues,
    required this.filledSpans,
    required this.usage,
  });

  final List<SubtitleDraftCue> cues;
  final int filledSpans;
  final SubtitleAiUsageTally usage;
}

/// S4s 歌词补齐。
class SubtitleLyricsPass {
  SubtitleLyricsPass({
    required this.completer,
    required this.finder,
    this.language = VideoSubtitleLanguage.japanese,
  });

  final AiTextCompleter completer;
  final SubtitleLyricsFinder finder;

  /// 选认歌 / 对齐 / 抽歌词的提示词与搜索词。
  final VideoSubtitleLanguage language;

  bool get _zh => language == VideoSubtitleLanguage.mandarin;

  Future<SubtitleLyricsPassResult> run({
    required List<SubtitleDraftCue> cues,
    required String workTitle,
    required File cacheFile,
    List<SubtitleEvidenceTrack> evidence = const <SubtitleEvidenceTrack>[],
    bool allSung = false,
    SubtitleCancelToken cancel = const SubtitleNeverCancel(),
  }) async {
    final SubtitleAiUsageTally usage = SubtitleAiUsageTally();
    final List<SubtitleSongSpan> spans = detectSubtitleSongSpans(
      cues,
      evidence: evidence,
      allSung: allSung,
    );
    if (spans.isEmpty) {
      return SubtitleLyricsPassResult(cues: cues, filledSpans: 0, usage: usage);
    }
    final Map<String, Object?> cache = _readCache(cacheFile);
    final List<SubtitleDraftCue> out = List<SubtitleDraftCue>.of(cues);
    int filled = 0;
    bool dirty = false;
    for (final SubtitleSongSpan span in spans) {
      throwIfSubtitleCancelled(cancel);
      final String key = _spanKey(cues, span, workTitle);
      Object? entry = cache[key];
      if (entry is Map) {
        final Object? u = entry['usage'];
        if (u is Map) {
          usage.addTally(
            SubtitleAiUsageTally.fromJson(u.cast<String, Object?>()),
          );
        }
      } else {
        final SubtitleAiUsageTally spanUsage = SubtitleAiUsageTally();
        SubtitleSongLyricsFill? fill;
        try {
          fill = await fillSpan(
            cues: cues,
            span: span,
            workTitle: workTitle,
            usage: spanUsage,
            cancel: cancel,
          );
        } on SubtitleAiRequestFailure catch (e) {
          // 回复反复不合格：放弃这一段（不缓存，下次重试）。请求失败照常抛。
          if (e.reason != kSubtitleAiReplyIncomplete) rethrow;
          fushiDebugPrint('[SubtitleLyrics] span ${span.startMs}: $e');
          usage.addTally(spanUsage);
          continue;
        }
        usage.addTally(spanUsage);
        entry = <String, Object?>{
          if (fill != null) ...<String, Object?>{
            'source': fill.source,
            'title': fill.title,
            'replacements': <String, String>{
              for (final MapEntry<int, String> r in fill.replacements.entries)
                '${r.key}': r.value,
            },
          },
          'usage': spanUsage.toJson(),
        };
        cache[key] = entry;
        dirty = true;
      }
      final Object? reps = entry['replacements'];
      final Object? source = entry['source'];
      if (reps is! Map || source is! String) continue;
      bool any = false;
      reps.forEach((Object? k, Object? v) {
        final int? i = int.tryParse('$k');
        if (i == null || i < 0 || i >= out.length || v is! String) return;
        out[i] = out[i].copyWith(text: v, origin: 'lyrics:$source');
        any = true;
      });
      if (any) filled++;
    }
    if (dirty) {
      await writeSubtitleJobFileAtomic(
        cacheFile,
        const JsonEncoder.withIndent(' ').convert(<String, Object?>{
          'version': kSubtitleLyricsVersion,
          'spans': cache,
        }),
      );
    }
    return SubtitleLyricsPassResult(
      cues: out,
      filledSpans: filled,
      usage: usage,
    );
  }

  /// 一段：认歌 → 查 → 逐个候选对齐并校验，第一个过校验的采用。都不过 → null。
  Future<SubtitleSongLyricsFill?> fillSpan({
    required List<SubtitleDraftCue> cues,
    required SubtitleSongSpan span,
    required String workTitle,
    required SubtitleAiUsageTally usage,
    required SubtitleCancelToken cancel,
  }) async {
    final List<String> sung = <String>[
      for (final int i in span.cueIndexes) stripSongMark(cues[i].text),
    ];
    final (String, String?)? song = await identify(
      workTitle: workTitle,
      span: span,
      sung: sung,
      usage: usage,
      cancel: cancel,
    );
    final SubtitleSongQuery query = SubtitleSongQuery(
      workTitle: workTitle,
      title: song?.$1,
      artist: song?.$2,
      sungLines: sung,
      evidenceLines: span.evidenceLines,
      language: language,
    );
    final List<SubtitleLyricsCandidate> candidates = await finder.find(
      query,
      completer: completer,
      usage: usage,
      cancel: cancel,
    );
    for (final SubtitleLyricsCandidate candidate in candidates) {
      throwIfSubtitleCancelled(cancel);
      final Map<int, String> mapped = await align(
        cues: cues,
        span: span,
        candidate: candidate,
        songLabel: song?.$1,
        usage: usage,
        cancel: cancel,
      );
      final Map<int, String>? verified = verifySubtitleLyricsAlignment(
        cues: cues,
        span: span,
        candidate: candidate,
        mapped: mapped,
      );
      if (verified != null) {
        return SubtitleSongLyricsFill(
          replacements: verified,
          source: candidate.source,
          title: song?.$1,
        );
      }
    }
    return null;
  }

  /// 认歌：(歌名, 歌手)；认不出 null。
  Future<(String, String?)?> identify({
    required String workTitle,
    required SubtitleSongSpan span,
    required List<String> sung,
    required SubtitleAiUsageTally usage,
    required SubtitleCancelToken cancel,
  }) async {
    (String, String?)? result;
    bool answered = false;
    await runAiLineExchange(
      completer: completer,
      stablePrefix: _zh
          ? kSubtitleSongIdentifyPromptZh
          : kSubtitleSongIdentifyPrompt,
      body: () => <String>[
        '${_zh ? SubtitleLyricsLabelsZh.workTitle : '作品名'}: $workTitle',
        '${_zh ? SubtitleLyricsLabelsZh.span : '区間'}: '
            '${formatProofreadTime(span.startMs)}-${formatProofreadTime(span.endMs)}',
        _zh ? SubtitleLyricsLabelsZh.recognized : '音声認識:',
        for (final String s in sung) '  $s',
        if (span.evidenceLines.isNotEmpty) ...<String>[
          _zh ? SubtitleLyricsLabelsZh.evidence : '既存字幕の歌詞行:',
          for (final String s in span.evidenceLines) '  $s',
        ],
      ].join('\n'),
      absorb: (List<String> lines) {
        for (final String line in lines) {
          final String t = line.trim();
          if (t == 'UNKNOWN') {
            answered = true;
            return 1;
          }
          final List<String> parts = t.split('\t');
          if (parts.length >= 2 && parts.first == 'TITLE') {
            final String title = parts[1].trim();
            if (title.isEmpty) continue;
            final String artist = parts.length > 2 ? parts[2].trim() : '';
            result = (title, artist.isEmpty ? null : artist);
            answered = true;
            return 1;
          }
        }
        return 0;
      },
      done: (AiLineReply reply) => answered,
      failureDetail: () => 'song identify ${span.startMs}',
      usage: usage,
      cancel: cancel,
    );
    return result;
  }

  /// 对齐：字幕稿下标 → 歌词（原样，不含 `♪`）。
  Future<Map<int, String>> align({
    required List<SubtitleDraftCue> cues,
    required SubtitleSongSpan span,
    required SubtitleLyricsCandidate candidate,
    required String? songLabel,
    required SubtitleAiUsageTally usage,
    required SubtitleCancelToken cancel,
  }) async {
    final Set<int> ids = span.cueIndexes.toSet();
    final Map<int, String> got = <int, String>{};
    await runAiLineExchange(
      completer: completer,
      stablePrefix: _zh
          ? kSubtitleLyricsAlignPromptZh
          : kSubtitleLyricsAlignPrompt,
      body: () => <String>[
        if (songLabel != null)
          '${_zh ? SubtitleLyricsLabelsZh.song : '曲'}: $songLabel',
        _zh ? SubtitleLyricsLabelsZh.lyrics : '歌詞:',
        for (final String l in candidate.lines) '  $l',
        '',
        _zh ? SubtitleLyricsLabelsZh.sungLines : '歌唱行:',
        for (final int i in span.cueIndexes)
          'id=$i [${formatProofreadTime(cues[i].startMs)}-'
              '${formatProofreadTime(cues[i].endMs)}] ${stripSongMark(cues[i].text)}',
      ].join('\n'),
      absorb: (List<String> lines) {
        int added = 0;
        for (final String line in lines) {
          final (String, String)? r = splitAiLineRecord(line);
          final int? id = r == null ? null : int.tryParse(r.$1);
          if (id == null || !ids.contains(id) || got.containsKey(id)) continue;
          final String text = r!.$2.trim();
          if (text.isEmpty) continue;
          got[id] = text;
          added++;
        }
        return added;
      },
      // 只写对上的行：写了结束标记就算完（没对上的一行也不写是合法回复）。
      done: (AiLineReply reply) => reply.complete,
      failureDetail: () => 'lyrics align ${span.startMs}',
      usage: usage,
      cancel: cancel,
    );
    return got;
  }
}

/// 校验对齐结果：每行歌词必须逐字来自 [candidate]（模型编的丢掉）；对上的行覆盖率与
/// 字面相似度都达标才采用，返回 下标 → `♪` + 歌词；不达标 null。
Map<int, String>? verifySubtitleLyricsAlignment({
  required List<SubtitleDraftCue> cues,
  required SubtitleSongSpan span,
  required SubtitleLyricsCandidate candidate,
  required Map<int, String> mapped,
}) {
  final String source = normalizeLyricsForMatch(candidate.lines.join());
  final Map<int, String> kept = <int, String>{};
  double similarity = 0;
  for (final MapEntry<int, String> e in mapped.entries) {
    final String norm = normalizeLyricsForMatch(e.value);
    if (norm.isEmpty || !source.contains(norm)) continue;
    kept[e.key] = e.value;
    similarity += lyricsBigramDice(stripSongMark(cues[e.key].text), e.value);
  }
  if (kept.isEmpty) return null;
  if (kept.length < span.cueIndexes.length * kSubtitleLyricsMinCoverage) {
    return null;
  }
  if (similarity / kept.length < kSubtitleLyricsMinSimilarity) return null;
  return <int, String>{
    for (final MapEntry<int, String> e in kept.entries) e.key: '♪${e.value}',
  };
}

String _spanKey(
  List<SubtitleDraftCue> cues,
  SubtitleSongSpan span,
  String title,
) => sha1
    .convert(
      utf8.encode(
        jsonEncode(<Object?>[
          kSubtitleLyricsVersion,
          title,
          for (final int i in span.cueIndexes)
            <Object?>[i, cues[i].startMs, cues[i].endMs, cues[i].text],
          span.evidenceLines,
        ]),
      ),
    )
    .toString();

Map<String, Object?> _readCache(File f) {
  if (!f.existsSync()) return <String, Object?>{};
  try {
    final Object? decoded = jsonDecode(f.readAsStringSync());
    if (decoded is! Map || decoded['version'] != kSubtitleLyricsVersion) {
      return <String, Object?>{};
    }
    final Object? spans = decoded['spans'];
    return spans is Map ? spans.cast<String, Object?>() : <String, Object?>{};
  } on FormatException {
    return <String, Object?>{};
  }
}

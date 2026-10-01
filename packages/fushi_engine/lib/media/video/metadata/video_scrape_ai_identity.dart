/// 视频刮削身份消解的**纯 Dart 契约**：协调器只认这里的类型，不认任何 LLM 客户端。
///
/// 协调器在线源判定 ambiguous 后，把「本地目录长什么样 + 有哪些候选」打包成
/// [AiVideoIdentityQuery] 交给注入的 [AiVideoIdentityDecider]；决策器怎么实现
/// （问哪家模型、提示词长什么样）是 app 侧的事（`fushi/lib/src/ai/
/// ai_video_identity_assistant.dart`）。引擎包会被 `dart compile exe` 成服务端，
/// 所以这一层不能依赖 Flutter、偏好仓库或 HTTP 客户端。
///
/// 边界与 `docs/specs/2026-09-08-scrape-provider-choice.md` 的拒绝规则一致：
/// * 决策器不发任何新的资料源请求，只看协调器已经拿到手的候选列表；
/// * 多候选都合理 / 季号对不上 / 集数明显不符 / 一个都不像 → 判定 key 为 null；
/// * 置信度低于 [kAiVideoIdentityAutoAcceptConfidence] 的判定不自动采用，原样进
///   人工确认 / 待确认；
/// * 决策器回 null（未指派提供商等）时这一层完全不参与，刮削行为与没有 AI 一模一样。
library;

import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

/// AI 判定自动采用的置信度门槛（含）。低于它仍走人工确认 / 待确认。
const double kAiVideoIdentityAutoAcceptConfidence = 0.85;

/// 候选简介最多带给模型的字符数：够判断题材/年代，不让 15 条候选把上下文撑爆。
const int kAiVideoIdentitySynopsisMaxChars = 300;

/// 交给模型的示例文件名条数上限。
const int kAiVideoIdentitySampleFileNameLimit = 5;

/// 一条候选作品（来自资料源的已取回结果）。
class AiVideoIdentityCandidate {
  AiVideoIdentityCandidate({
    required this.key,
    required List<String> titles,
    required this.mediaKind,
    this.year,
    this.episodeCount,
    String? synopsis,
  })  : titles = _normalizeTitles(titles),
        synopsis = _clipSynopsis(synopsis);

  /// 候选的稳定键：`<provider>:<externalId>`，与 resolver 合并候选时的去重键同形。
  final String key;

  /// 各语言标题（主标题 + 原名 + 别名），去空去重。
  final List<String> titles;
  final VideoMetadataMediaKind mediaKind;
  final int? year;
  final int? episodeCount;

  /// 简介，已截到 [kAiVideoIdentitySynopsisMaxChars]。
  final String? synopsis;

  /// 去空、trim、保序去重：同一个标题在主标题和别名里各出现一次很常见。
  static List<String> _normalizeTitles(List<String> raw) {
    final Set<String> seen = <String>{};
    return List<String>.unmodifiable(<String>[
      for (final String title in raw)
        if (title.trim().isNotEmpty && seen.add(title.trim())) title.trim(),
    ]);
  }

  static String? _clipSynopsis(String? raw) {
    final String? trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    if (trimmed.length <= kAiVideoIdentitySynopsisMaxChars) {
      return trimmed;
    }
    return '${trimmed.substring(0, kAiVideoIdentitySynopsisMaxChars)}…';
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'key': key,
        'titles': titles,
        'mediaKind': mediaKind.name,
        if (year != null) 'year': year,
        if (episodeCount != null) 'episodeCount': episodeCount,
        if (synopsis != null) 'synopsis': synopsis,
      };
}

/// 一次身份消解提问：本地目录长什么样 + 有哪些候选。
class AiVideoIdentityQuery {
  AiVideoIdentityQuery({
    required List<String> localTitles,
    required List<AiVideoIdentityCandidate> candidates,
    this.season,
    this.episodeCount,
    this.year,
    List<String> sampleFileNames = const <String>[],
    this.locale = 'en',
  })  : localTitles = List<String>.unmodifiable(localTitles),
        candidates = List<AiVideoIdentityCandidate>.unmodifiable(candidates),
        sampleFileNames = List<String>.unmodifiable(
          sampleFileNames.take(kAiVideoIdentitySampleFileNameLimit),
        );

  /// 文件名解析出的标题 + 父/祖父目录名（已过识别词清洗）。
  final List<String> localTitles;

  /// 本地解析出的季号；null = 未知。
  final int? season;

  /// 本地成员数（合集才有）；null = 单文件或未知。
  final int? episodeCount;

  /// 本地解析出的年份；null = 未知。
  final int? year;

  /// 最多 [kAiVideoIdentitySampleFileNameLimit] 条成员文件名。
  final List<String> sampleFileNames;
  final List<AiVideoIdentityCandidate> candidates;

  /// 让模型写 `reason` 时用的语言标签（如 `zh-CN`）。
  final String locale;

  /// 所有候选 key 的集合，解析回复时做白名单。
  Set<String> get candidateKeys => <String>{
        for (final AiVideoIdentityCandidate candidate in candidates)
          candidate.key,
      };

  /// 缓存键里的分隔符：控制字符不会出现在标题 / 候选 key 里，拼接不会撞。
  static final String _fieldSeparator = String.fromCharCode(1);
  static final String _recordSeparator = String.fromCharCode(2);

  /// 「同一目录、同一批候选」的缓存键：协调器按它保证一批只问一次。
  String get cacheKey => <String>[
        localTitles.join(_fieldSeparator),
        '$season',
        '$episodeCount',
        '$year',
        candidateKeys.join(_fieldSeparator),
      ].join(_recordSeparator);

  Map<String, Object?> toJson() => <String, Object?>{
        'localTitles': localTitles,
        if (season != null) 'season': season,
        if (episodeCount != null) 'localEpisodeCount': episodeCount,
        if (year != null) 'year': year,
        if (sampleFileNames.isNotEmpty) 'sampleFileNames': sampleFileNames,
        'candidates': <Map<String, Object?>>[
          for (final AiVideoIdentityCandidate candidate in candidates)
            candidate.toJson(),
        ],
      };
}

/// AI 的判定。[key] 为 null 表示「没有唯一命中」。
class AiVideoIdentityDecision {
  const AiVideoIdentityDecision({
    required this.key,
    required this.confidence,
    this.reason = '',
  });

  final String? key;

  /// 0.0 ~ 1.0；解析失败时为 0。
  final double confidence;
  final String reason;

  /// 是否达到自动采用门槛。
  bool get isAutoAcceptable =>
      key != null && confidence >= kAiVideoIdentityAutoAcceptConfidence;

  /// 百分比整数（UI 与运行记录共用）。
  int get confidencePercent => (confidence * 100).round();
}

/// 单次判定函数：给一个提问，回一个判定；null = 本次不问（未指派提供商等）。
/// AI 下视频（`video_acquisition_service.dart`）按这个形状注入。
typedef AiVideoIdentityDecider = Future<AiVideoIdentityDecision?> Function(
  AiVideoIdentityQuery query,
);

/// 刮削协调器的 AI 注入点。
///
/// 与裸 [AiVideoIdentityDecider] 的区别是带 [capabilityKey]：协调器的判定缓存、
/// 补刮账本的「试过没中」都是**某一套 AI 配置下**的结论，换了提供商 / 模型就
/// 必须作废——以前缓存键里没有这一项，换了提供商仍沿用旧的「不选」（2026-10-01）。
abstract interface class AiVideoIdentityAdvisor {
  /// 当前生效的 AI 能力（提供商 + 协议 + 地址 + 模型）的稳定键；null = 未指派
  /// 或不可用，此时协调器完全不问 AI。实现必须**每次现算**：协调器与补刮器
  /// 生命周期很长，用户在设置里改了指派要立即生效。
  String? get capabilityKey;

  /// 在 [AiVideoIdentityQuery.candidates] 里选唯一命中。抛异常 = 问了但失败
  /// （网络 / 鉴权 / 超时 / 空回复），协调器把它当作临时失败记账。
  Future<AiVideoIdentityDecision> decide(AiVideoIdentityQuery query);

  /// 资料源一个候选都没给时：根据本地线索给出这部作品可能的正式标题（各语言），
  /// **只作搜索词**——重搜回来的候选仍要经 [decide] 达到门槛才采用，AI 不能凭空
  /// 指定作品。[query] 的 candidates 为空。失败语义同 [decide]。
  Future<List<String>> suggestSearchTitles(AiVideoIdentityQuery query);
}

/// AI 给出的搜索词最多用几条：每条都是一轮资料源请求（AniDB 有进程级限流）。
const int kAiVideoIdentitySearchTitleLimit = 3;

// ---------------------------------------------------------------------------
// AI 在刮削运行记录里的落地形态
// ---------------------------------------------------------------------------
//
// 运行记录（`video_source_scrape_runs.summary_json`）只有 warnings/errors 两个
// 自由文本清单，没有结构化的「判定来源」列，也不为此加 DB 列：AI 的每次参与作为
// 一条 warning 记进去，message 用固定前缀编码，UI 侧再用
// [parseVideoScrapeAiIdentityNote] 还原成可翻译的文案。四种形态：
//
// * `ai:matched confidence=0.93 reason=…`  AI 判定并被采用；
// * `ai:declined confidence=0.40 reason=…` 问了 AI，但没有达到门槛的唯一命中；
// * `ai:failed reason=…`                   AI 请求失败（或本趟已失败而跳过）；
// * `ai:searched reason=标题1 / 标题2`      资料源查无，按 AI 给的标题重搜过。
//
// `ai:matched` 是 2026-09 起就在落库的旧形态，格式不变。

/// AI 参与刮削的结果种类。
enum VideoScrapeAiNoteKind { matched, declined, failed, searched }

/// 「AI 判定并采用」标记的前缀（旧形态，格式冻结）。
const String kVideoScrapeAiIdentityNotePrefix = 'ai:matched';

final RegExp _notePattern = RegExp(
  r'^ai:(matched|declined|failed|searched)'
  r'(?: confidence=([0-9.]+))?(?: reason=(.*))?$',
  dotAll: true,
);

/// 已解析的 AI 标记。[confidence] 只有 matched / declined 有。
class VideoScrapeAiIdentityNote {
  const VideoScrapeAiIdentityNote({
    this.kind = VideoScrapeAiNoteKind.matched,
    this.confidence,
    required this.reason,
  });

  final VideoScrapeAiNoteKind kind;
  final double? confidence;
  final String reason;

  int get confidencePercent => ((confidence ?? 0) * 100).round();
}

String _encodeNote(
  VideoScrapeAiNoteKind kind, {
  double? confidence,
  String reason = '',
}) {
  final StringBuffer out = StringBuffer('ai:${kind.name}');
  if (confidence != null) {
    out.write(' confidence=${confidence.toStringAsFixed(2)}');
  }
  final String trimmed = reason.trim();
  if (trimmed.isNotEmpty) out.write(' reason=$trimmed');
  return out.toString();
}

/// 把被采用的 AI 判定编码成运行记录里的一条 message。
String encodeVideoScrapeAiIdentityNote(AiVideoIdentityDecision decision) =>
    _encodeNote(VideoScrapeAiNoteKind.matched,
        confidence: decision.confidence, reason: decision.reason);

/// AI 给了判定但不采用（没有唯一命中或置信度不够）。
String encodeVideoScrapeAiDeclinedNote(AiVideoIdentityDecision decision) =>
    _encodeNote(
      VideoScrapeAiNoteKind.declined,
      confidence: decision.confidence,
      reason: decision.reason,
    );

/// AI 请求失败；[reason] 是已脱敏的失败描述。
String encodeVideoScrapeAiFailedNote(String reason) =>
    _encodeNote(VideoScrapeAiNoteKind.failed, reason: reason);

/// 资料源查无，按 AI 给出的 [titles] 重搜过。
String encodeVideoScrapeAiSearchedNote(List<String> titles) =>
    _encodeNote(VideoScrapeAiNoteKind.searched, reason: titles.join(' / '));

/// 从运行记录 message 还原 AI 标记；不是这种标记回 null。
VideoScrapeAiIdentityNote? parseVideoScrapeAiIdentityNote(String message) {
  final RegExpMatch? match = _notePattern.firstMatch(message.trim());
  if (match == null) {
    return null;
  }
  final VideoScrapeAiNoteKind kind =
      VideoScrapeAiNoteKind.values.byName(match.group(1)!);
  final String? rawConfidence = match.group(2);
  final double? confidence =
      rawConfidence == null ? null : double.tryParse(rawConfidence);
  final bool scored = kind == VideoScrapeAiNoteKind.matched ||
      kind == VideoScrapeAiNoteKind.declined;
  if (scored && confidence == null) {
    return null;
  }
  return VideoScrapeAiIdentityNote(
    kind: kind,
    confidence: confidence?.clamp(0, 1).toDouble(),
    reason: (match.group(3) ?? '').trim(),
  );
}

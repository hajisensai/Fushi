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

/// 协调器注入点：给一个提问，回一个判定；null = 本次不问（未指派提供商等）。
///
/// 抛异常表示「问了但失败」（网络 / 鉴权 / 超时）：协调器会把本趟 run 余下的
/// 歧义作品都跳过 AI，本条照旧进人工确认 / 待确认；诊断日志由实现方自己记。
typedef AiVideoIdentityDecider = Future<AiVideoIdentityDecision?> Function(
  AiVideoIdentityQuery query,
);

// ---------------------------------------------------------------------------
// 「这条作品是 AI 判定的」在刮削运行记录里的落地形态
// ---------------------------------------------------------------------------
//
// 运行记录（`video_source_scrape_runs.summary_json`）只有 warnings/errors 两个
// 自由文本清单，没有结构化的「判定来源」列，也不为此加 DB 列：AI 判定作为一条
// warning 记进去，message 用固定前缀 `ai:matched` 编码置信度与理由，UI 侧再用
// [parseVideoScrapeAiIdentityNote] 还原成可翻译的文案。

/// 标记前缀。整条 message 形如
/// `ai:matched confidence=0.93 reason=标题与年份完全一致`。
const String kVideoScrapeAiIdentityNotePrefix = 'ai:matched';

final RegExp _notePattern = RegExp(
  '^$kVideoScrapeAiIdentityNotePrefix confidence=([0-9.]+)(?: reason=(.*))?\$',
  dotAll: true,
);

/// 已解析的 AI 判定标记。
class VideoScrapeAiIdentityNote {
  const VideoScrapeAiIdentityNote({
    required this.confidence,
    required this.reason,
  });

  final double confidence;
  final String reason;

  int get confidencePercent => (confidence * 100).round();
}

/// 把 AI 判定编码成运行记录里的一条 message。
String encodeVideoScrapeAiIdentityNote(AiVideoIdentityDecision decision) {
  final String confidence = decision.confidence.toStringAsFixed(2);
  final String reason = decision.reason.trim();
  return reason.isEmpty
      ? '$kVideoScrapeAiIdentityNotePrefix confidence=$confidence'
      : '$kVideoScrapeAiIdentityNotePrefix confidence=$confidence reason=$reason';
}

/// 从运行记录 message 还原 AI 判定；不是这种标记回 null。
VideoScrapeAiIdentityNote? parseVideoScrapeAiIdentityNote(String message) {
  final RegExpMatch? match = _notePattern.firstMatch(message.trim());
  if (match == null) {
    return null;
  }
  final double? confidence = double.tryParse(match.group(1)!);
  if (confidence == null) {
    return null;
  }
  return VideoScrapeAiIdentityNote(
    confidence: confidence.clamp(0, 1).toDouble(),
    reason: (match.group(2) ?? '').trim(),
  );
}

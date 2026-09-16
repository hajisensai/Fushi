/// 视频库搜索辅助：让 AI 补搜索词、在**已取回**的字幕 / 资源候选里做语义重排。
///
/// 边界与本仓其它 AI 功能一致（见 `ai_feature.dart`）：AI **不发起任何网络检索**、
/// **不丢弃任何候选**、**不接管确定性判据**（`chooseSubtitleForEpisode` /
/// `deduplicate*` 照旧是本地代码）。它只做三件事：
///
/// 1. 给出 2~4 条备选查询词（日文原名 / Hepburn 罗马字 / 英文名 / 去季号基础名），
///    由用户点 chip 才填进输入框——**绝不静默改写用户输入**
///    （`docs/specs/2026-09-07-video-library-workflow.md` 的硬规则）；
/// 2. 对字幕候选打分重排（时轴对应本地发布版本 > 人翻优于机翻 > 语言偏好 > 下载量）；
/// 3. 对 torrent 候选打分重排（合集/单集、v2 修正、内嵌日字、BDRip/WEB-DL、季集契合）。
///
/// 三者的回复都经本地校验（[parseAiSearchQueries] / [parseAiRankResult]）：下标越界
/// 或重复一律剔除，模型漏掉的候选按原序补在末尾——**返回的永远是全量排列**，模型
/// 抽风最坏也只是「顺序没变」。
library;

import 'dart:convert';

import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_feature.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_reply_json.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_backfill.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/models/preferences_repository.dart';

/// 解析「视频搜索辅助」当前可用的提供商；null = 未指派 / 已删 / 没配全。
///
/// 页面按回调注入而不是自己读偏好（与 galgame 文本处理编辑页同一姿态）：这些搜索
/// 面板的 widget 测试都不挂 `ProviderScope`。
typedef AiProviderResolver = AiProviderConfig? Function();

/// 造 AI 调用客户端。测试注入假 `http.Client` 走这条缝；生产恒是 [AiChatClient] 的
/// 默认构造（内部走 `createAppHttpIoClient()`）。
typedef AiClientFactory = AiChatClient Function();

/// 从偏好里解析视频搜索辅助的提供商。调用方须先确认偏好已就绪。
AiProviderConfig? resolveVideoSearchAiProvider(PreferencesRepository prefs) =>
    prefs.aiFeatureAssignments.resolve(
      AiFeature.videoSearch,
      prefs.aiProviders,
    );

/// 单条 AI 备选查询词的最大长度；再长就不是搜索词而是段落了。
const int kAiSearchQueryMaxLength = 80;

/// 最多采纳的备选查询词条数。
const int kAiSearchQueryMaxCount = 4;

/// 喂给模型的候选上限。列表可能几十上百条，全部塞进去既贵又没意义——
/// 本地排序已把最可能的排在前面，AI 只在前 30 条里做精排；其余按原序补在末尾。
const int kAiRankMaxCandidates = 30;

/// 查询词扩展的用途：决定提示词里对「站点」的描述。
enum AiSearchPurpose {
  /// torrent 索引站（Nyaa / Torznab）：发布名多为罗马字 + 英文，偶有日文。
  torrent,

  /// 字幕站（Jimaku / OpenSubtitles）：条目名多为罗马字 / 英文 / 日文。
  subtitle,
}

/// 查询词归一化：去首尾空白、折叠内部空白、小写。只用于去重比较，不改显示值。
String normalizeAiSearchQuery(String raw) =>
    raw.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// 一次重排的结论。
class AiRankResult {
  const AiRankResult({
    required this.orderedIds,
    this.recommendedIndex,
    this.notes = const <int, String>{},
  });

  /// 恒等排列：0..count-1，无推荐、无备注。
  factory AiRankResult.identity(int count) => AiRankResult(
    orderedIds: List<int>.unmodifiable(List<int>.generate(count, (int i) => i)),
  );

  /// 候选**下标**（相对调用方传入的候选列表）的完整排列。
  final List<int> orderedIds;

  /// 模型认为最值得选的那条的下标；模型没给 / 给的越界为 null。
  final int? recommendedIndex;

  /// 下标 → 一句话理由，只含模型真的给了的那几条。
  final Map<int, String> notes;

  /// 顺序没变、也没有推荐和备注：模型什么有用的都没说。
  bool get isIdentity {
    if (recommendedIndex != null || notes.isNotEmpty) return false;
    for (int i = 0; i < orderedIds.length; i += 1) {
      if (orderedIds[i] != i) return false;
    }
    return true;
  }

  /// 按本排列重排 [items]（长度须与 [orderedIds] 一致）。
  List<T> reorder<T>(List<T> items) {
    assert(items.length == orderedIds.length);
    return List<T>.unmodifiable(<T>[
      for (final int index in orderedIds) items[index],
    ]);
  }
}

// ---------------------------------------------------------------------------
// 查询词扩展
// ---------------------------------------------------------------------------

String buildAiSearchQueriesSystemPrompt(AiSearchPurpose purpose) {
  final String site = switch (purpose) {
    AiSearchPurpose.torrent =>
      'a torrent index for anime and Japanese live-action video (release '
          'names are mostly Hepburn romaji or English, sometimes Japanese)',
    AiSearchPurpose.subtitle =>
      'a Japanese subtitle archive (entry names are romaji, English, or '
          'Japanese)',
  };
  return '''
You suggest alternative search terms for $site. The user already typed one query;
you add spellings the site is more likely to index under.

Give, when they exist for this work:
- the original Japanese title,
- the Hepburn romaji title,
- the official English title,
- the base title with season numbers, part names and subtitles stripped.

Rules:
- Answer with a single JSON object and nothing else: {"queries": ["...", "..."]}.
- 2 to $kAiSearchQueryMaxCount entries, each at most $kAiSearchQueryMaxLength characters.
- Do not repeat the user's own query. Do not invent titles you are unsure of.
- No episode numbers, no resolution or codec tags, no quotes around titles.
''';
}

String buildAiSearchQueriesUserPrompt({
  required String query,
  VideoMediaReference? media,
}) {
  final StringBuffer buffer = StringBuffer()
    ..writeln('User query: ${jsonEncode(query)}');
  if (media != null) {
    buffer.writeln('Known title: ${jsonEncode(media.title)}');
    if (media.originalTitle?.trim().isNotEmpty == true) {
      buffer.writeln('Original title: ${jsonEncode(media.originalTitle)}');
    }
    if (media.aliases.isNotEmpty) {
      buffer.writeln('Aliases: ${jsonEncode(media.aliases)}');
    }
    if (media.year != null) buffer.writeln('Year: ${media.year}');
    if (media.season != null) buffer.writeln('Season: ${media.season}');
    buffer.writeln('Category: ${media.discoveryCategory.name}');
  }
  return buffer.toString();
}

/// 解析查询词回复：去重、剔除与 [exclude] 归一化相等的、超长截断、最多
/// [kAiSearchQueryMaxCount] 条。解析不出返回空列表。
List<String> parseAiSearchQueries(
  String reply, {
  Iterable<String> exclude = const <String>[],
}) {
  final Map<String, Object?>? decoded = decodeAiJsonObject(reply);
  final Object? raw = decoded?['queries'];
  if (raw is! List) return const <String>[];
  final Set<String> seen = <String>{
    for (final String value in exclude) normalizeAiSearchQuery(value),
  };
  final List<String> out = <String>[];
  for (final Object? entry in raw) {
    if (entry is! String) continue;
    String value = entry.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (value.length > kAiSearchQueryMaxLength) {
      value = value.substring(0, kAiSearchQueryMaxLength).trimRight();
    }
    if (value.isEmpty) continue;
    if (!seen.add(normalizeAiSearchQuery(value))) continue;
    out.add(value);
    if (out.length >= kAiSearchQueryMaxCount) break;
  }
  return List<String>.unmodifiable(out);
}

/// 跑一次「AI 补搜索词」。失败原样抛 [AiChatFailure]（文案已脱敏）。
Future<List<String>> requestAiSearchQueries({
  required AiChatClient client,
  required AiProviderConfig provider,
  required String query,
  required AiSearchPurpose purpose,
  VideoMediaReference? media,
}) async {
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(buildAiSearchQueriesSystemPrompt(purpose)),
      AiChatMessage.user(
        buildAiSearchQueriesUserPrompt(query: query, media: media),
      ),
    ],
    maxTokens: 512,
  );
  return parseAiSearchQueries(reply, exclude: <String>[query]);
}

// ---------------------------------------------------------------------------
// 重排：共用解析
// ---------------------------------------------------------------------------

/// 解析重排回复。[count] 是调用方候选总数：越界 / 重复的下标剔除，漏掉的按原序补在
/// 末尾，所以返回值恒是 0..count-1 的完整排列；坏 JSON 返回恒等排列。
AiRankResult parseAiRankResult(String reply, {required int count}) {
  final Map<String, Object?>? decoded = decodeAiJsonObject(reply);
  if (decoded == null) return AiRankResult.identity(count);
  final List<int> order = <int>[];
  final Set<int> seen = <int>{};
  final Object? rawOrder = decoded['order'];
  if (rawOrder is List) {
    for (final Object? entry in rawOrder) {
      final int? index = _readIndex(entry);
      if (index == null || index < 0 || index >= count) continue;
      if (seen.add(index)) order.add(index);
    }
  }
  for (int i = 0; i < count; i += 1) {
    if (seen.add(i)) order.add(i);
  }
  final int? recommended = _readIndex(decoded['recommended']);
  final Map<int, String> notes = <int, String>{};
  final Object? rawNotes = decoded['notes'];
  if (rawNotes is Map) {
    rawNotes.forEach((Object? key, Object? value) {
      final int? index = _readIndex(key);
      if (index == null || index < 0 || index >= count) return;
      if (value is! String || value.trim().isEmpty) return;
      notes[index] = value.trim();
    });
  }
  return AiRankResult(
    orderedIds: List<int>.unmodifiable(order),
    recommendedIndex:
        recommended != null && recommended >= 0 && recommended < count
        ? recommended
        : null,
    notes: Map<int, String>.unmodifiable(notes),
  );
}

/// 模型给下标时 int / "3" / 3.0 都见过，统一收成 int；认不出为 null。
int? _readIndex(Object? raw) {
  if (raw is int) return raw;
  if (raw is double && raw == raw.roundToDouble()) return raw.round();
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

/// 日期只到天：模型不需要毫秒，短一点也省 token。
String _isoDate(DateTime? value) =>
    value == null ? '' : value.toUtc().toIso8601String().substring(0, 10);

String _rankRules(String criteria) =>
    '''
$criteria

Rules:
- Answer with a single JSON object and nothing else:
  {"order": [index, ...], "recommended": index or null, "notes": {"index": "one short reason"}}.
- "order" lists candidate indexes from best to worst. Include every index you were given.
- "recommended" is the single best candidate, or null if none stands out.
- "notes" is optional; give at most one sentence per index and only where it helps.
- Never invent candidates. Only use the indexes provided.
''';

// ---------------------------------------------------------------------------
// 字幕重排
// ---------------------------------------------------------------------------

/// 字幕重排的上下文：本地文件长什么样、用户偏好什么语言。
class AiSubtitleRankContext {
  const AiSubtitleRankContext({
    this.media,
    this.localFileName,
    this.localReleaseGroup,
    this.localResolution,
    this.preferredLanguages = const <String>[],
    this.episode,
  });

  final VideoMediaReference? media;

  /// 本地视频文件名；字幕时轴要对的是**这个**发布版本。
  final String? localFileName;
  final String? localReleaseGroup;
  final String? localResolution;

  /// 语言偏好，靠前优先。
  final List<String> preferredLanguages;
  final int? episode;
}

String buildAiSubtitleRankSystemPrompt() => _rankRules('''
You rank subtitle files already fetched for one local video file. Scoring order:
1. timing likely matches the local release (same release group / source type such
   as BDRip vs WEB-DL / same resolution tag; matching episode number when given);
2. human-made subtitles over machine or AI translations;
3. the user's language preference;
4. download count and recency as weak tie-breakers.''');

String buildAiSubtitleRankUserPrompt({
  required List<VideoSubtitleCandidate> candidates,
  required AiSubtitleRankContext context,
}) {
  final StringBuffer buffer = StringBuffer();
  _writeMedia(buffer, context.media);
  if (context.localFileName != null) {
    buffer.writeln('Local file: ${jsonEncode(context.localFileName)}');
  }
  if (context.localReleaseGroup?.trim().isNotEmpty == true) {
    buffer.writeln('Local release group: ${context.localReleaseGroup}');
  }
  if (context.localResolution?.trim().isNotEmpty == true) {
    buffer.writeln('Local resolution: ${context.localResolution}');
  }
  if (context.episode != null) buffer.writeln('Episode: ${context.episode}');
  if (context.preferredLanguages.isNotEmpty) {
    buffer.writeln(
      'Preferred languages: ${jsonEncode(context.preferredLanguages)}',
    );
  }
  buffer.writeln('Candidates:');
  for (int i = 0; i < candidates.length; i += 1) {
    final VideoSubtitleCandidate c = candidates[i];
    buffer.writeln(
      jsonEncode(<String, Object?>{
        'index': i,
        'file': c.fileName,
        'release': c.releaseName ?? '',
        'language': c.language,
        'episode': c.episode,
        'downloads': c.downloadCount,
        'ai_translated': c.aiTranslated,
        'trusted': c.fromTrusted,
        'uploaded': _isoDate(
          c.uploadedAtMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(c.uploadedAtMs!),
        ),
      }),
    );
  }
  return buffer.toString();
}

/// 跑一次字幕重排。只把前 [kAiRankMaxCandidates] 条喂给模型，返回值仍是
/// [candidates] 全长的排列。失败原样抛 [AiChatFailure]。
Future<AiRankResult> requestAiSubtitleRank({
  required AiChatClient client,
  required AiProviderConfig provider,
  required List<VideoSubtitleCandidate> candidates,
  required AiSubtitleRankContext context,
}) async {
  if (candidates.isEmpty) return AiRankResult.identity(0);
  final List<VideoSubtitleCandidate> fed = candidates
      .take(kAiRankMaxCandidates)
      .toList(growable: false);
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(buildAiSubtitleRankSystemPrompt()),
      AiChatMessage.user(
        buildAiSubtitleRankUserPrompt(candidates: fed, context: context),
      ),
    ],
  );
  return parseAiRankResult(reply, count: candidates.length);
}

// ---------------------------------------------------------------------------
// 资源重排
// ---------------------------------------------------------------------------

/// 资源（torrent）重排的上下文。
class AiResourceRankContext {
  const AiResourceRankContext({
    this.media,
    required this.query,
    this.season,
    this.episode,
    this.preferEmbeddedJapaneseSubs = true,
  });

  final VideoMediaReference? media;
  final String query;
  final int? season;
  final int? episode;

  /// 日语沉浸用户偏好内嵌日文字幕的发布。
  final bool preferEmbeddedJapaneseSubs;
}

String buildAiResourceRankSystemPrompt() => _rankRules('''
You rank torrent releases already fetched for one work. Read each release name and
judge:
- batch/complete-season packs versus single episodes (prefer what matches the
  requested season/episode; a batch is fine when no episode is requested);
- v2/v3 corrected re-releases over the version they replace;
- embedded Japanese subtitles when the user prefers them;
- BDRip/BluRay over WEB-DL over TV rips at the same resolution;
- season and episode numbers that fit the request; other seasons rank last;
- seeders, trusted uploader and size as tie-breakers only.''');

String buildAiResourceRankUserPrompt({
  required List<VideoResourceCandidate> candidates,
  required AiResourceRankContext context,
}) {
  final StringBuffer buffer = StringBuffer();
  _writeMedia(buffer, context.media);
  buffer.writeln('Query: ${jsonEncode(context.query)}');
  if (context.season != null) buffer.writeln('Season: ${context.season}');
  if (context.episode != null) buffer.writeln('Episode: ${context.episode}');
  buffer.writeln(
    'Prefer embedded Japanese subtitles: ${context.preferEmbeddedJapaneseSubs}',
  );
  buffer.writeln('Candidates:');
  for (int i = 0; i < candidates.length; i += 1) {
    final VideoResourceCandidate c = candidates[i];
    buffer.writeln(
      jsonEncode(<String, Object?>{
        'index': i,
        'title': c.title,
        'seeders': c.seeders,
        'size_bytes': c.sizeBytes,
        'resolution': c.resolution ?? '',
        'release_group': c.releaseGroup ?? '',
        'trusted': c.trusted,
        'published': _isoDate(c.publishedAt),
      }),
    );
  }
  return buffer.toString();
}

/// 跑一次资源重排。截断与返回值语义同 [requestAiSubtitleRank]。
Future<AiRankResult> requestAiResourceRank({
  required AiChatClient client,
  required AiProviderConfig provider,
  required List<VideoResourceCandidate> candidates,
  required AiResourceRankContext context,
}) async {
  if (candidates.isEmpty) return AiRankResult.identity(0);
  final List<VideoResourceCandidate> fed = candidates
      .take(kAiRankMaxCandidates)
      .toList(growable: false);
  final String reply = await client.complete(
    provider: provider,
    messages: <AiChatMessage>[
      AiChatMessage.system(buildAiResourceRankSystemPrompt()),
      AiChatMessage.user(
        buildAiResourceRankUserPrompt(candidates: fed, context: context),
      ),
    ],
  );
  return parseAiRankResult(reply, count: candidates.length);
}

void _writeMedia(StringBuffer buffer, VideoMediaReference? media) {
  if (media == null) return;
  buffer.writeln('Work: ${jsonEncode(media.title)}');
  if (media.originalTitle?.trim().isNotEmpty == true) {
    buffer.writeln('Original title: ${jsonEncode(media.originalTitle)}');
  }
  if (media.year != null) buffer.writeln('Year: ${media.year}');
}

// ---------------------------------------------------------------------------
// 自动补字幕的接线
// ---------------------------------------------------------------------------

/// 给 [VideoSubtitleBackfillService.aiReorder] 用的重排闭包。
///
/// 提供商在**每次调用时**解析（用户改设置不用重建服务）；未指派或 AI 失败都回退
/// 原序——补字幕是后台任务，AI 只能锦上添花，绝不能把它变成新的失败点。
SubtitleBackfillReorder aiSubtitleBackfillReorder({
  required AiProviderResolver resolveProvider,
  AiClientFactory? clientFactory,
}) {
  return (
    List<VideoSubtitleCandidate> candidates,
    SubtitleBackfillTarget target,
  ) async {
    final AiProviderConfig? provider = resolveProvider();
    if (provider == null || candidates.length < 2) return candidates;
    final AiChatClient client = clientFactory?.call() ?? AiChatClient();
    try {
      final AiRankResult rank = await requestAiSubtitleRank(
        client: client,
        provider: provider,
        candidates: candidates,
        context: AiSubtitleRankContext(
          media: target.media,
          localFileName: target.videoPath.split(RegExp(r'[/\\]')).last,
          episode: target.media.episode,
          preferredLanguages: <String>[
            if (target.contentLanguage?.trim().isNotEmpty == true)
              target.contentLanguage!,
          ],
        ),
      );
      return rank.reorder(candidates);
    } on AiChatFailure {
      return candidates;
    } finally {
      client.close();
    }
  };
}

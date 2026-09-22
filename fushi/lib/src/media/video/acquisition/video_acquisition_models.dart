/// 「AI 下视频」的领域模型：槽位、问题、状态、事件、效果。
///
/// 这一层是纯数据 + 纯 Dart（无 Flutter、无 IO）。对话的每一步都由
/// `video_acquisition_reducer.dart` 的纯函数决定「缺什么、问什么、何时提交」，
/// AI 只在两处介入：把用户的一句话解析成 [VideoAcquisitionIntent]（补丁），以及
/// 在已取回的作品候选里选唯一命中。热路径（搜作品、搜资源、选版本、入队、建订阅）
/// 永远是本地确定性代码——与 `fushi/lib/src/ai/ai_feature.dart` 的硬边界一致。
///
/// 助手对用户说的每一句都是 [VideoAcquisitionSay]（i18n 模板键 + 参数），页面再
/// 翻成文案；**AI 的输出里没有任何自由文本字段**，模型散文永不进 UI。
library;

import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_library_presence.dart';
import 'package:fushi_engine/media/video/metadata/video_airing_status.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';
import 'package:fushi/src/media/video/download/video_discovery_selection.dart';
import 'package:fushi/src/media/video/download/video_resource_version_groups.dart';

// ---------------------------------------------------------------------------
// 值域
// ---------------------------------------------------------------------------

/// 直接下载已出的，还是订阅追更。
enum VideoAcquisitionMode { download, subscribe }

/// 画质档位。`storageKey` 同时是偏好值与对话补丁里的枚举串。
enum VideoAcquisitionQuality {
  p2160('2160p', 2160),
  p1080('1080p', 1080),
  p720('720p', 720),
  p480('480p', 480),

  /// 不限：不按分辨率过滤，取版本卡的自然顺序。
  any('any', null);

  const VideoAcquisitionQuality(this.storageKey, this.height);

  final String storageKey;
  final int? height;

  static VideoAcquisitionQuality? fromStorageKey(String? raw) {
    final String key = raw?.trim().toLowerCase() ?? '';
    for (final VideoAcquisitionQuality value in values) {
      if (value.storageKey == key) return value;
    }
    return null;
  }

  /// 候选 / 版本卡的 `resolution` 串（`1080p` / `1080P` / `1080`）是否就是本档。
  bool matchesResolution(String? resolution) {
    if (this == any) return true;
    final int? parsed = parseResolutionHeight(resolution);
    return parsed != null && parsed == height;
  }

  /// `1080p` / `2160P` / `1080` → 1080 / 2160；解析不出 → null。
  static int? parseResolutionHeight(String? resolution) {
    final String? digits = RegExp(
      r'^\s*(\d{3,4})\s*[pP]?\s*$',
    ).firstMatch(resolution ?? '')?.group(1);
    return digits == null ? null : int.tryParse(digits);
  }
}

/// 偏好值 `ask`：每次都问（画质 / 字幕语言两个偏好共用）。
const String kVideoAcquisitionPrefAsk = 'ask';

/// 字幕语言偏好值 / 槽位值 `original`：跟随作品语言（解析见
/// `video_work_content_language.dart`）。
const String kVideoAcquisitionSubtitleOriginal = 'original';

/// 字幕语言偏好值 / 槽位值 `none`：不自动配字幕（入队时字幕策略 = none）。
const String kVideoAcquisitionSubtitleNone = 'none';

/// 用户可选的具体字幕语言码（与 `kJimakuLanguageCodes` 同值域，按 UI 顺序）。
const List<String> kVideoAcquisitionSubtitleLanguageCodes = <String>[
  'ja',
  'zh',
  'en',
  'ko',
];

/// 对话里会问到的槽位。
enum VideoAcquisitionSlot {
  /// 你要的是哪一部（多义作品候选）。
  work,

  /// 哪一季（仅非 anime 的多季剧集）。
  season,

  /// 直接下载还是订阅（仅放送中 / 状态未知的剧集）。
  mode,

  /// 画质。
  quality,

  /// 字幕语言。
  subtitleLanguage,

  /// 下到哪个受管视频来源（仅多来源且无默认）。
  targetSource,

  /// 版本确认：就这个 / 换一个 / 取消。
  resource,

  /// 想要的画质没有：只有这些，要吗？
  resolutionFallback,

  /// 订阅模式下没有可订阅的版本：改为直接下载？
  subscribeFallback,

  /// 已在库 / 已订阅：仍要继续？
  presence,
}

/// 下载模式下要哪些集。
sealed class VideoAcquisitionEpisodes {
  const VideoAcquisitionEpisodes();
}

/// 全部已出的集（默认）。
class VideoAcquisitionAllEpisodes extends VideoAcquisitionEpisodes {
  const VideoAcquisitionAllEpisodes();
}

/// 只要第 [episode] 集。
class VideoAcquisitionSingleEpisode extends VideoAcquisitionEpisodes {
  const VideoAcquisitionSingleEpisode(this.episode);

  final int episode;
}

/// 第 [from] 到第 [to] 集（含）。
class VideoAcquisitionEpisodeRange extends VideoAcquisitionEpisodes {
  const VideoAcquisitionEpisodeRange(this.from, this.to)
    : assert(from <= to, 'range must be ascending');

  final int from;
  final int to;
}

// ---------------------------------------------------------------------------
// 槽位
// ---------------------------------------------------------------------------

/// 一次获取请求已经确定的东西。null = 还没定。
///
/// 不可变；reducer 用 [copyWith] 逐槽位填。`quality` / `subtitleLanguage` 为空时
/// 由偏好决定要不要问（见 reducer 的决策表）。
class VideoAcquisitionSlots {
  const VideoAcquisitionSlots({
    this.workQueries = const <String>[],
    this.category,
    this.season,
    this.allSeasons = false,
    this.mode,
    this.quality,
    this.qualityRemember = false,
    this.subtitleLanguage,
    this.subtitleLanguageRemember = false,
    this.episodes = const VideoAcquisitionAllEpisodes(),
    this.targetSourceId,
  });

  /// 作品查询词（AI 补的 2~4 条，或用户原文一条），依次试到首个非空命中。
  final List<String> workQueries;

  /// 用户点明的类别（anime / movie / tv）；null = 不限。
  final VideoDiscoveryCategory? category;

  /// 用户点明的季号；null = 未指定（是否要问见 reducer）。
  final int? season;

  /// 季问题里选了「全部」：不按季过滤资源，也不再问季。
  final bool allSeasons;

  final VideoAcquisitionMode? mode;

  final VideoAcquisitionQuality? quality;

  /// 本次选的画质要不要写成以后的默认（勾选框，默认勾上）。
  final bool qualityRemember;

  /// `original` / 语言码 / `none`；null = 还没定。
  final String? subtitleLanguage;

  /// 本次选的字幕语言要不要写成以后的默认。
  final bool subtitleLanguageRemember;

  final VideoAcquisitionEpisodes episodes;

  final int? targetSourceId;

  VideoAcquisitionSlots copyWith({
    List<String>? workQueries,
    VideoDiscoveryCategory? category,
    int? season,
    bool? allSeasons,
    VideoAcquisitionMode? mode,
    VideoAcquisitionQuality? quality,
    bool? qualityRemember,
    String? subtitleLanguage,
    bool? subtitleLanguageRemember,
    VideoAcquisitionEpisodes? episodes,
    int? targetSourceId,
  }) => VideoAcquisitionSlots(
    workQueries: workQueries ?? this.workQueries,
    category: category ?? this.category,
    season: season ?? this.season,
    allSeasons: allSeasons ?? this.allSeasons,
    mode: mode ?? this.mode,
    quality: quality ?? this.quality,
    qualityRemember: qualityRemember ?? this.qualityRemember,
    subtitleLanguage: subtitleLanguage ?? this.subtitleLanguage,
    subtitleLanguageRemember:
        subtitleLanguageRemember ?? this.subtitleLanguageRemember,
    episodes: episodes ?? this.episodes,
    targetSourceId: targetSourceId ?? this.targetSourceId,
  );
}

// ---------------------------------------------------------------------------
// 助手发言 / 问题
// ---------------------------------------------------------------------------

/// 助手一句话的**种类**；文案由页面按种类 + [VideoAcquisitionSay.args] 取 i18n。
enum VideoAcquisitionSayKind {
  /// 开场：说作品名。
  greeting,

  /// 没找到作品，换个名字？（args: query）
  workNotFound,

  /// 已选：X（AI 判定，置信度）（args: title, confidence）
  aiPicked,

  /// 已选：X（唯一命中）（args: title）
  workChosen,

  /// 这部已在库（到第 N 集）（args: title, highestEpisode）
  alreadyInLibrary,

  /// 这部已订阅（args: title）
  alreadySubscribed,

  /// 放送状态未知，仍按可订阅处理（args: title）
  airingUnknown,

  /// 字幕语言：跟随作品语言解析出 X（args: language, evidence）
  subtitleLanguageResolved,

  /// 字幕语言：作品语言判不出来，再问一次
  subtitleLanguageUnresolved,

  /// 这次的字幕语言已记为本作品偏好（args: language）
  subtitleLanguageRemembered,

  /// 版本摘要（args: releaseGroup, resolution, provider, count, batch, seeders, missing）
  summary,

  /// 没有更多版本了
  noMoreVersions,

  /// 已提交（args: mode, count）
  submitted,

  /// 失败（args: message）
  failed,

  /// 已取消
  cancelled,

  /// AI 暂不可用，请点选（args: code）
  aiUnavailable,

  /// 没听懂，请点选或换个说法
  unclear,

  /// 提问本身（配 [VideoAcquisitionQuestion]）
  question,
}

/// 助手的一句话：种类 + 模板参数。
class VideoAcquisitionSay {
  const VideoAcquisitionSay(this.kind, {this.args = const <String, Object?>{}});

  final VideoAcquisitionSayKind kind;
  final Map<String, Object?> args;
}

/// 问题里的一个可点选项。
///
/// [id] 是槽位内稳定的值（画质档 `1080p`、模式 `download`、候选下标 `0`…），
/// [label] 是**已经确定的显示文本**（作品标题、来源名、分辨率串这类不需要翻译
/// 的字面量）；null 时页面按 (slot, id) 取 i18n。
class VideoAcquisitionOption {
  const VideoAcquisitionOption({required this.id, this.label, this.hint});

  final String id;
  final String? label;

  /// 副标题（作品年份 / 类型、版本卡做种数…）。
  final String? hint;
}

/// 当前挂起的问题：最多一个。
class VideoAcquisitionQuestion {
  const VideoAcquisitionQuestion({
    required this.slot,
    required this.options,
    this.rememberToggle = false,
    this.rememberDefault = true,
    this.preselectedIndex,
    this.args = const <String, Object?>{},
  });

  final VideoAcquisitionSlot slot;
  final List<VideoAcquisitionOption> options;

  /// 是否显示「以后默认」勾选框（画质 / 字幕语言）。
  final bool rememberToggle;

  /// 勾选框的初值。所有者 2026-09-22：**默认勾上**；偏好为 `ask` 时不勾。
  final bool rememberDefault;

  /// 预选项（字幕语言问句预选「跟随作品语言」）。
  final int? preselectedIndex;

  /// 问句模板参数（如 resolutionFallback 的 wanted / available）。
  final Map<String, Object?> args;

  int get optionCount => options.length;
}

/// 对话记录里的一条。
sealed class VideoAcquisitionMessage {
  const VideoAcquisitionMessage();
}

class VideoAcquisitionUserMessage extends VideoAcquisitionMessage {
  const VideoAcquisitionUserMessage(this.text);

  final String text;
}

class VideoAcquisitionAssistantMessage extends VideoAcquisitionMessage {
  const VideoAcquisitionAssistantMessage(this.say, {this.question});

  final VideoAcquisitionSay say;

  /// 这句话带的问题（选项在渲染时已失效也留着，作历史）。
  final VideoAcquisitionQuestion? question;
}

// ---------------------------------------------------------------------------
// 意图（AI 解析产物，已本地校验）
// ---------------------------------------------------------------------------

enum VideoAcquisitionIntentKind {
  /// 提供了新信息（补丁非空）。
  provide,

  /// 在回答当前问题（`choiceIndex` 有效）。
  choose,

  /// 换一个版本。
  next,

  /// 就这个 / 好。
  confirm,

  /// 算了。
  cancel,

  /// 没听懂。
  unclear,
}

/// 从一句话里能确定的字段；每个都可空，null = 这句话没提。
class VideoAcquisitionIntentPatch {
  const VideoAcquisitionIntentPatch({
    this.workQueries = const <String>[],
    this.category,
    this.season,
    this.episode,
    this.episodeRange,
    this.allEpisodes,
    this.quality,
    this.qualityRemember,
    this.subtitleLanguage,
    this.subtitleLanguageRemember,
    this.mode,
    this.choiceIndex,
  });

  final List<String> workQueries;
  final VideoDiscoveryCategory? category;
  final int? season;
  final int? episode;
  final ({int from, int to})? episodeRange;
  final bool? allEpisodes;
  final VideoAcquisitionQuality? quality;
  final bool? qualityRemember;

  /// `original` / 归一后的语言码 / `none`。
  final String? subtitleLanguage;
  final bool? subtitleLanguageRemember;
  final VideoAcquisitionMode? mode;

  /// 对当前问题选项的下标（已校验在范围内）。
  final int? choiceIndex;

  bool get isEmpty =>
      workQueries.isEmpty &&
      category == null &&
      season == null &&
      episode == null &&
      episodeRange == null &&
      allEpisodes == null &&
      quality == null &&
      qualityRemember == null &&
      subtitleLanguage == null &&
      subtitleLanguageRemember == null &&
      mode == null &&
      choiceIndex == null;
}

class VideoAcquisitionIntent {
  const VideoAcquisitionIntent(this.kind, this.patch);

  const VideoAcquisitionIntent.unclear()
    : kind = VideoAcquisitionIntentKind.unclear,
      patch = const VideoAcquisitionIntentPatch();

  final VideoAcquisitionIntentKind kind;
  final VideoAcquisitionIntentPatch patch;
}

// ---------------------------------------------------------------------------
// 资源计划（picker 产物）
// ---------------------------------------------------------------------------

/// 一张版本卡在当前模式 / 集选择下的落地计划。
class VideoAcquisitionResourcePlan {
  const VideoAcquisitionResourcePlan({
    required this.group,
    required this.picks,
    this.usesBatch = false,
    this.filter,
    this.startAfterEpisode,
    this.missingEpisodes = const <int>[],
  });

  final VideoResourceVersionGroup group;

  /// 下载模式：真正入队的发布（合集时恰 1 条）；订阅模式：作模板的代表条。
  final List<VideoResourceCandidate> picks;

  /// 下载模式取的是整季合集。
  final bool usesBatch;

  /// 订阅模式的严格规则；下载模式为 null。
  final StrictVideoSubscriptionFilter? filter;

  /// 订阅从这一集起（含）；电影 / 无集号为 null。
  final int? startAfterEpisode;

  /// 用户要的范围里没找到的集号（摘要里说明）。
  final List<int> missingEpisodes;
}

// ---------------------------------------------------------------------------
// 状态
// ---------------------------------------------------------------------------

enum VideoAcquisitionStage {
  /// 等用户第一句话。
  idle,

  /// 正在按查询词搜作品。
  resolvingWork,

  /// 多义候选等用户 / AI 选。
  awaitingWorkChoice,

  /// 选定作品后拉详情（放送状态 / 原语言 / 库内存在性）。
  loadingDetails,

  /// 逐槽位收集：模式 / 画质 / 字幕语言 / 季 / 来源。
  collectingSlots,

  /// 正在搜资源。
  resolvingResources,

  /// 版本摘要等确认。
  awaitingResourceConfirm,

  /// 正在入队 / 建订阅。
  submitting,

  done,
  cancelled,
}

/// 「跟随作品语言」的解析结论：码 + 证据（摘要里要说得出依据）。
enum VideoWorkLanguageEvidence {
  originalLanguage,
  countries,
  titleScript,
  none,
}

class VideoWorkContentLanguage {
  const VideoWorkContentLanguage({required this.code, required this.evidence});

  static const VideoWorkContentLanguage unknown = VideoWorkContentLanguage(
    code: null,
    evidence: VideoWorkLanguageEvidence.none,
  );

  final String? code;
  final VideoWorkLanguageEvidence evidence;
}

/// 整个会话的快照。不可变；reducer 返回新实例。
class VideoAcquisitionState {
  const VideoAcquisitionState({
    this.stage = VideoAcquisitionStage.idle,
    this.slots = const VideoAcquisitionSlots(),
    this.question,
    this.transcript = const <VideoAcquisitionMessage>[],
    this.pendingQueries = const <String>[],
    this.workCandidates = const <VideoDiscoveryItem>[],
    this.chosenItem,
    this.work,
    this.airing,
    this.contentLanguage,
    this.presence,
    this.alreadySubscribed = false,
    this.presenceAcknowledged = false,
    this.subtitleLanguageAsked = false,
    this.subtitleLanguageResolutionSaid = false,
    this.groups = const <VideoResourceVersionGroup>[],
    this.eligibleGroups = const <VideoResourceVersionGroup>[],
    this.availableResolutions = const <String>[],
    this.groupCursor = 0,
    this.plan,
    this.aiDecision,
    this.busy = false,
  });

  final VideoAcquisitionStage stage;
  final VideoAcquisitionSlots slots;

  /// 当前挂起的问题；null = 没在等用户选。
  final VideoAcquisitionQuestion? question;

  final List<VideoAcquisitionMessage> transcript;

  /// 还没试过的作品查询词（首个非空命中即停）。
  final List<String> pendingQueries;

  /// 最近一次作品搜索的候选（≥2 时进 awaitingWorkChoice）。
  final List<VideoDiscoveryItem> workCandidates;

  final VideoDiscoveryItem? chosenItem;

  /// `loadDetails` 之后的完整作品资料（TMDB 搜索项在这之前没有 status）。
  final VideoMetadataWork? work;

  final VideoAiringStatus? airing;

  /// 「跟随作品语言」解析结论；null = 还没解析。
  final VideoWorkContentLanguage? contentLanguage;

  final VideoLibraryPresence? presence;
  final bool alreadySubscribed;

  /// 「已在库 / 已订阅」提示用户已确认继续。
  final bool presenceAcknowledged;

  /// 本会话已经问过一次字幕语言（`original` 判不出时只允许追问这一次）。
  final bool subtitleLanguageAsked;

  /// 「跟随作品语言 → 解析出 X」这句已经说过（决策表每次重跑不重复说）。
  final bool subtitleLanguageResolutionSaid;

  /// 资源搜索结果的全部版本卡（相关度序）。
  final List<VideoResourceVersionGroup> groups;

  /// 按画质 / 模式过滤后的版本卡；[groupCursor] 指向当前展示的那张。
  final List<VideoResourceVersionGroup> eligibleGroups;

  /// 画质不命中时可用的分辨率串（去重、按高度降序）。
  final List<String> availableResolutions;

  final int groupCursor;

  /// 当前版本卡的落地计划（awaitingResourceConfirm 时非空）。
  final VideoAcquisitionResourcePlan? plan;

  final AiVideoIdentityDecision? aiDecision;

  /// 有效果在执行（页面禁用输入）。
  final bool busy;

  VideoMediaReference? get reference => chosenItem?.reference;

  VideoAcquisitionState copyWith({
    VideoAcquisitionStage? stage,
    VideoAcquisitionSlots? slots,
    VideoAcquisitionQuestion? question,
    bool clearQuestion = false,
    List<VideoAcquisitionMessage>? transcript,
    List<String>? pendingQueries,
    List<VideoDiscoveryItem>? workCandidates,
    VideoDiscoveryItem? chosenItem,
    VideoMetadataWork? work,
    VideoAiringStatus? airing,
    bool clearAiring = false,
    VideoWorkContentLanguage? contentLanguage,
    VideoLibraryPresence? presence,
    bool? alreadySubscribed,
    bool? presenceAcknowledged,
    bool? subtitleLanguageAsked,
    bool? subtitleLanguageResolutionSaid,
    List<VideoResourceVersionGroup>? groups,
    List<VideoResourceVersionGroup>? eligibleGroups,
    List<String>? availableResolutions,
    int? groupCursor,
    VideoAcquisitionResourcePlan? plan,
    bool clearPlan = false,
    AiVideoIdentityDecision? aiDecision,
    bool? busy,
  }) => VideoAcquisitionState(
    stage: stage ?? this.stage,
    slots: slots ?? this.slots,
    question: clearQuestion ? null : (question ?? this.question),
    transcript: transcript ?? this.transcript,
    pendingQueries: pendingQueries ?? this.pendingQueries,
    workCandidates: workCandidates ?? this.workCandidates,
    chosenItem: chosenItem ?? this.chosenItem,
    work: work ?? this.work,
    airing: clearAiring ? null : (airing ?? this.airing),
    contentLanguage: contentLanguage ?? this.contentLanguage,
    presence: presence ?? this.presence,
    alreadySubscribed: alreadySubscribed ?? this.alreadySubscribed,
    presenceAcknowledged: presenceAcknowledged ?? this.presenceAcknowledged,
    subtitleLanguageAsked: subtitleLanguageAsked ?? this.subtitleLanguageAsked,
    subtitleLanguageResolutionSaid:
        subtitleLanguageResolutionSaid ?? this.subtitleLanguageResolutionSaid,
    groups: groups ?? this.groups,
    eligibleGroups: eligibleGroups ?? this.eligibleGroups,
    availableResolutions: availableResolutions ?? this.availableResolutions,
    groupCursor: groupCursor ?? this.groupCursor,
    plan: clearPlan ? null : (plan ?? this.plan),
    aiDecision: aiDecision ?? this.aiDecision,
    busy: busy ?? this.busy,
  );

  /// 追加一条对话记录。
  VideoAcquisitionState say(
    VideoAcquisitionSay say, {
    VideoAcquisitionQuestion? question,
  }) => copyWith(
    transcript: <VideoAcquisitionMessage>[
      ...transcript,
      VideoAcquisitionAssistantMessage(say, question: question),
    ],
    question: question,
    clearQuestion: question == null,
  );
}

// ---------------------------------------------------------------------------
// 会话默认值（偏好快照 + 来源清单）
// ---------------------------------------------------------------------------

/// 受管视频来源（`MediaSourceRow` 的最小投影，模型层不依赖 Drift 行类型）。
class VideoAcquisitionSource {
  const VideoAcquisitionSource({required this.id, required this.label});

  final int id;
  final String label;
}

/// 打开对话时的偏好快照。reducer 只读它，不碰偏好仓库。
class VideoAcquisitionDefaults {
  const VideoAcquisitionDefaults({
    this.qualityPref = '',
    this.subtitleLanguagePref = '',
    this.sources = const <VideoAcquisitionSource>[],
    this.defaultSourceId,
    this.locale = 'en',
  });

  /// `ai_video_download_quality`：`''` 未设置 / `ask` / 固定档。
  final String qualityPref;

  /// `ai_video_download_subtitle_language`：`''` 未设置 / `ask` / `original` /
  /// 语言码 / `none`。
  final String subtitleLanguagePref;

  final List<VideoAcquisitionSource> sources;

  /// `video_download_target_source_id`；0 / null = 未选。
  final int? defaultSourceId;

  final String locale;
}

// ---------------------------------------------------------------------------
// 事件（进 reducer）
// ---------------------------------------------------------------------------

sealed class VideoAcquisitionEvent {
  const VideoAcquisitionEvent();
}

/// 用户输入了一句话（页面先记录，再由 service 决定要不要经 AI）。
class VideoAcquisitionUserTextEvent extends VideoAcquisitionEvent {
  const VideoAcquisitionUserTextEvent(this.text);

  final String text;
}

/// 用户点了当前问题的一个选项。**永不经 AI。**
class VideoAcquisitionChipChosenEvent extends VideoAcquisitionEvent {
  const VideoAcquisitionChipChosenEvent({
    required this.slot,
    required this.optionId,
    this.remember,
  });

  final VideoAcquisitionSlot slot;
  final String optionId;

  /// 勾选框终值；问题没有勾选框时为 null。
  final bool? remember;
}

/// AI 把用户那句话解析成了意图补丁。
class VideoAcquisitionAiIntentEvent extends VideoAcquisitionEvent {
  const VideoAcquisitionAiIntentEvent(this.intent, {required this.utterance});

  final VideoAcquisitionIntent intent;
  final String utterance;
}

/// AI 不可用（未指派 / 调用失败）；[utterance] 是那句没解析成的话。
class VideoAcquisitionAiUnavailableEvent extends VideoAcquisitionEvent {
  const VideoAcquisitionAiUnavailableEvent({
    required this.utterance,
    this.code,
  });

  final String utterance;
  final String? code;
}

/// 一次作品搜索返回。
class VideoAcquisitionWorksLoadedEvent extends VideoAcquisitionEvent {
  const VideoAcquisitionWorksLoadedEvent({
    required this.query,
    required this.items,
  });

  final String query;
  final List<VideoDiscoveryItem> items;
}

/// AI 在候选里做了判定（null = 它也不确定 / 调用失败）。
class VideoAcquisitionIdentityDecidedEvent extends VideoAcquisitionEvent {
  const VideoAcquisitionIdentityDecidedEvent(this.decision);

  final AiVideoIdentityDecision? decision;
}

/// 详情 + 库内存在性到了。
class VideoAcquisitionDetailsLoadedEvent extends VideoAcquisitionEvent {
  const VideoAcquisitionDetailsLoadedEvent({
    this.work,
    this.presence,
    this.alreadySubscribed = false,
  });

  final VideoMetadataWork? work;
  final VideoLibraryPresence? presence;
  final bool alreadySubscribed;
}

/// 资源搜索返回。
class VideoAcquisitionResourcesLoadedEvent extends VideoAcquisitionEvent {
  const VideoAcquisitionResourcesLoadedEvent(this.items);

  final List<VideoResourceCandidate> items;
}

/// 提交成功（[count] = 入队条数；订阅为 1）。
class VideoAcquisitionSubmittedEvent extends VideoAcquisitionEvent {
  const VideoAcquisitionSubmittedEvent({required this.count});

  final int count;
}

/// 某个效果失败了（网络 / 后端 / 提交）。
class VideoAcquisitionFailedEvent extends VideoAcquisitionEvent {
  const VideoAcquisitionFailedEvent(this.message);

  final String message;
}

/// 用户取消（按钮）。
class VideoAcquisitionCancelEvent extends VideoAcquisitionEvent {
  const VideoAcquisitionCancelEvent();
}

// ---------------------------------------------------------------------------
// 效果（reducer 产出，service 执行）
// ---------------------------------------------------------------------------

sealed class VideoAcquisitionEffect {
  const VideoAcquisitionEffect();
}

/// 把这句话交给 AI 解析（提供商未指派时 service 直接回 aiUnavailable）。
class VideoAcquisitionParseIntentEffect extends VideoAcquisitionEffect {
  const VideoAcquisitionParseIntentEffect(this.utterance);

  final String utterance;
}

class VideoAcquisitionSearchWorksEffect extends VideoAcquisitionEffect {
  const VideoAcquisitionSearchWorksEffect({required this.query, this.category});

  final String query;
  final VideoDiscoveryCategory? category;
}

class VideoAcquisitionDecideIdentityEffect extends VideoAcquisitionEffect {
  const VideoAcquisitionDecideIdentityEffect(this.query);

  final AiVideoIdentityQuery query;
}

class VideoAcquisitionLoadDetailsEffect extends VideoAcquisitionEffect {
  const VideoAcquisitionLoadDetailsEffect(this.item);

  final VideoDiscoveryItem item;
}

class VideoAcquisitionSearchResourcesEffect extends VideoAcquisitionEffect {
  const VideoAcquisitionSearchResourcesEffect({
    required this.reference,
    this.season,
  });

  final VideoMediaReference reference;
  final int? season;
}

/// 要写的偏好。
enum VideoAcquisitionPreference { quality, subtitleLanguage }

class VideoAcquisitionPersistPreferenceEffect extends VideoAcquisitionEffect {
  const VideoAcquisitionPersistPreferenceEffect(this.preference, this.value);

  final VideoAcquisitionPreference preference;
  final String value;
}

/// 把这部作品的字幕语言写进每系列记忆（键与导入落库的合集名同源）。
class VideoAcquisitionSetSeriesSubtitleLanguageEffect
    extends VideoAcquisitionEffect {
  const VideoAcquisitionSetSeriesSubtitleLanguageEffect({
    required this.reference,
    required this.languageCode,
  });

  final VideoMediaReference reference;
  final String languageCode;
}

class VideoAcquisitionSubmitDownloadEffect extends VideoAcquisitionEffect {
  const VideoAcquisitionSubmitDownloadEffect({
    required this.item,
    required this.plan,
    required this.targetSourceId,
    required this.installSubtitles,
  });

  final VideoDiscoveryItem item;
  final VideoAcquisitionResourcePlan plan;
  final int targetSourceId;

  /// false = 用户选了「不配字幕」（字幕策略 none）。
  final bool installSubtitles;
}

class VideoAcquisitionSubmitSubscriptionEffect extends VideoAcquisitionEffect {
  const VideoAcquisitionSubmitSubscriptionEffect({
    required this.item,
    required this.plan,
    required this.targetSourceId,
    required this.installSubtitles,
  });

  final VideoDiscoveryItem item;
  final VideoAcquisitionResourcePlan plan;
  final int targetSourceId;
  final bool installSubtitles;
}

/// 会话结束（done / cancelled），页面可以关。
class VideoAcquisitionCloseEffect extends VideoAcquisitionEffect {
  const VideoAcquisitionCloseEffect();
}

// ---------------------------------------------------------------------------
// 问题选项的稳定 id（chip 点击回传的就是这些串；页面按 (slot, id) 取 i18n 文案）
// ---------------------------------------------------------------------------

/// resource 问题：「就这个」。
const String kVideoAcquisitionOptionConfirm = 'confirm';

/// resource 问题：「换一个」。
const String kVideoAcquisitionOptionNext = 'next';

/// 任意问题里的「取消」。
const String kVideoAcquisitionOptionCancel = 'cancel';

/// presence 问题：「仍要继续」。
const String kVideoAcquisitionOptionContinue = 'continue';

/// work 问题：「都不是」。
const String kVideoAcquisitionOptionNone = 'none';

/// season 问题：「全部」。
const String kVideoAcquisitionOptionAll = 'all';

/// subscribeFallback 问题：「改为直接下载」（值与 [VideoAcquisitionMode.download] 同名）。
const String kVideoAcquisitionOptionDownload = 'download';

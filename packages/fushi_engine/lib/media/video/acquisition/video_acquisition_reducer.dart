/// 「AI 下视频」的纯函数状态机：决定**缺什么、问什么、何时提交**。
///
/// 边界（与计划「方案形态」一致）：
/// * 这里没有 IO、没有 Flutter。输入是 [VideoAcquisitionState] + 一个
///   [VideoAcquisitionEvent]，输出是新状态 + 要 service 去执行的
///   [VideoAcquisitionEffect] 清单。
/// * AI **只解析、不决策**：用户的一句话先经 [VideoAcquisitionParseIntentEffect]
///   变成结构化补丁（[VideoAcquisitionIntentPatch]），多义作品候选交
///   [VideoAcquisitionDecideIdentityEffect] 选唯一命中；之后每一步——缺哪个槽位、
///   要不要问、问什么选项、何时搜资源、何时提交——都由下面的决策表决定，
///   AI 不可用时把原文当查询词、重出同一组 chip，流程照样走完。
/// * chip 点击（[VideoAcquisitionChipChosenEvent]）**永不经 AI**，直接落槽位。
/// * 助手对用户说的每一句都是 [VideoAcquisitionSay]（i18n 键 + 参数），没有任何
///   模型散文。
///
/// 槽位决策表（[_advance]）按顺序找第一个未定的槽位提问：
/// presence → mode → season → quality → subtitleLanguage → targetSource →
/// 搜资源；资源阶段的确定性规则在 `video_acquisition_resource_picker.dart`。
///
/// 整套下载（[VideoAcquisitionScope.isFranchise]）走同一张决策表的后半段
/// （quality → subtitleLanguage → targetSource），然后找系列、逐部搜资源、逐部按
/// 放送状态定下载 / 订阅，最后一张清单一次提交。
library;

import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_airing_status.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi_engine/media/video/discovery/video_franchise.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_resource_picker.dart';
import 'package:fushi_engine/media/video/acquisition/video_work_content_language.dart';
import 'package:fushi_engine/media/video/download/video_resource_version_groups.dart';

/// reducer 的返回：新状态 + 要执行的效果（按顺序）。
typedef VideoAcquisitionReduction = (
  VideoAcquisitionState,
  List<VideoAcquisitionEffect>,
);

/// 作品查询词最多依次试几个（首个非空命中即停）。
const int kVideoAcquisitionMaxWorkQueries = 3;

/// 多义候选最多保留几条（交 AI 判定 / 出 chip）。
const int kVideoAcquisitionMaxWorkCandidates = 8;

/// 季问题最多列几季（超出的走「全部」或用户口述）。
const int kVideoAcquisitionMaxSeasonOptions = 8;

/// `failed` 的 message 固定键：资源搜索一条都没有。
const String kVideoAcquisitionFailureNoCandidates = 'no_candidates';

/// `failed` 的 message 固定键：有版本卡但没有一张给得出落地计划。
const String kVideoAcquisitionFailureNoPlannableVersion =
    'no_plannable_version';

/// `failed` 的 message 固定键：没有受管视频来源可下。
const String kVideoAcquisitionFailureNoSources = 'no_sources';

const List<VideoAcquisitionEffect> _noEffects = <VideoAcquisitionEffect>[];

/// 决策表一行的产物：新状态 + 这一行是否已经提问（提了就停在这里等用户）。
typedef _SlotStep = ({VideoAcquisitionState state, bool asked});

// ---------------------------------------------------------------------------
// 入口：只做分派
// ---------------------------------------------------------------------------

VideoAcquisitionReduction reduceVideoAcquisition(
  VideoAcquisitionState state,
  VideoAcquisitionEvent event,
  VideoAcquisitionDefaults defaults,
) {
  if (event is VideoAcquisitionRestartEvent) {
    return (_restart(state), _noEffects);
  }
  if (_isTerminal(state)) {
    // 结束后接着打字 = 再下一部：页面不用先点「再下一部」。
    if (event is VideoAcquisitionUserTextEvent) {
      return _onUserText(_restart(state, greet: false), event);
    }
    return (state, _noEffects);
  }
  return switch (event) {
    VideoAcquisitionRestartEvent _ => (_restart(state), _noEffects),
    VideoAcquisitionUserTextEvent e => _onUserText(state, e),
    VideoAcquisitionChipChosenEvent e => _onChipChosen(state, e, defaults),
    VideoAcquisitionAiIntentEvent e => _onAiIntent(state, e, defaults),
    VideoAcquisitionAiUnavailableEvent e => _onAiUnavailable(state, e),
    VideoAcquisitionWorksLoadedEvent e => _onWorksLoaded(state, e, defaults),
    VideoAcquisitionAliasResolvedEvent e => _onAliasResolved(state, e),
    VideoAcquisitionIdentityDecidedEvent e => _onIdentityDecided(
      state,
      e,
      defaults,
    ),
    VideoAcquisitionDetailsLoadedEvent e => _onDetailsLoaded(
      state,
      e,
      defaults,
    ),
    VideoAcquisitionResourcesLoadedEvent e => _onResourcesLoaded(
      state,
      e,
      defaults,
    ),
    VideoAcquisitionFranchiseLoadedEvent e => _onFranchiseLoaded(
      state,
      e,
      defaults,
    ),
    VideoAcquisitionFranchiseEntryResolvedEvent e => _onFranchiseEntryResolved(
      state,
      e,
      defaults,
    ),
    VideoAcquisitionFranchiseEntryToggledEvent e => (
      _toggleFranchiseEntry(state, e.index),
      _noEffects,
    ),
    VideoAcquisitionFranchiseSubmittedEvent e => _onFranchiseSubmitted(
      state,
      e,
    ),
    VideoAcquisitionSubmittedEvent e => _onSubmitted(state, e),
    VideoAcquisitionFailedEvent e => _onFailed(state, e),
    VideoAcquisitionCancelEvent _ => _cancel(state),
  };
}

bool _isTerminal(VideoAcquisitionState state) =>
    state.stage == VideoAcquisitionStage.done ||
    state.stage == VideoAcquisitionStage.cancelled;

// ---------------------------------------------------------------------------
// 用户文本 / AI 解析
// ---------------------------------------------------------------------------

/// 每条用户文本都先交 AI 解析；这里只记录并挂起。
VideoAcquisitionReduction _onUserText(
  VideoAcquisitionState state,
  VideoAcquisitionUserTextEvent event,
) {
  final String text = event.text.trim();
  if (text.isEmpty) return (state, _noEffects);
  final VideoAcquisitionState next = state.copyWith(
    transcript: <VideoAcquisitionMessage>[
      ...state.transcript,
      VideoAcquisitionUserMessage(text),
    ],
    busy: true,
  );
  return (
    next,
    <VideoAcquisitionEffect>[VideoAcquisitionParseIntentEffect(text)],
  );
}

VideoAcquisitionReduction _onAiIntent(
  VideoAcquisitionState state,
  VideoAcquisitionAiIntentEvent event,
  VideoAcquisitionDefaults defaults,
) {
  final VideoAcquisitionState idle = state.copyWith(busy: false);
  final VideoAcquisitionIntent intent = event.intent;
  switch (intent.kind) {
    case VideoAcquisitionIntentKind.cancel:
      return _cancel(idle);
    case VideoAcquisitionIntentKind.next:
      if (idle.stage == VideoAcquisitionStage.awaitingResourceConfirm) {
        return _nextGroup(idle);
      }
      return _unclear(idle);
    case VideoAcquisitionIntentKind.confirm:
      if (idle.stage == VideoAcquisitionStage.awaitingResourceConfirm) {
        return _submit(idle, defaults);
      }
      if (idle.stage == VideoAcquisitionStage.awaitingFranchiseConfirm) {
        return _submitFranchise(idle);
      }
      return _unclear(idle);
    case VideoAcquisitionIntentKind.choose:
      return _onAiChoose(idle, intent.patch, defaults);
    case VideoAcquisitionIntentKind.provide:
      return _onAiProvide(idle, intent.patch, defaults);
    case VideoAcquisitionIntentKind.recommend:
      return _recommend(idle, intent.patch);
    case VideoAcquisitionIntentKind.unclear:
      return _unclear(idle);
  }
}

/// `recommend` = 问「哪个最好」。只在挑版本时有意义：AI 按用户说的条件给了
/// `choiceIndex`（指向「就这个」或某个 `alt:N`）就推荐那张；没说条件就推荐资源
/// 排序第一张能落地的卡（[rankResourceGroups] 已按偏好排好）。推荐的不是当前这
/// 张就切过去展示，但**不提交**——下载 / 订阅仍要用户点「就这个」。
VideoAcquisitionReduction _recommend(
  VideoAcquisitionState state,
  VideoAcquisitionIntentPatch patch,
) {
  if (state.stage != VideoAcquisitionStage.awaitingResourceConfirm) {
    return _unclear(state);
  }
  final int? byCriteria = _recommendedByCriteria(state, patch.choiceIndex);
  final ({int index, VideoAcquisitionResourcePlan plan})? target =
      byCriteria != null
      ? _indexedPlan(state, byCriteria)
      : _findPlan(state, 0);
  if (target == null) return _unclear(state);
  final bool current = target.index == state.groupCursor;
  final VideoAcquisitionSay say = VideoAcquisitionSay(
    VideoAcquisitionSayKind.recommendation,
    args: <String, Object?>{
      'index': target.index + 1,
      'current': current,
      'byCriteria': byCriteria != null,
    },
  );
  if (current) return (_sayThenReask(state, say), _noEffects);
  return (_presentPlan(state.say(say), target.index, target.plan), _noEffects);
}

/// `choiceIndex` → 卡下标：「就这个」= 当前卡，`alt:N` = 第 N 张；其余选项
/// （换一个 / 取消 / 只下最新一集…）不是版本，不算推荐。
int? _recommendedByCriteria(VideoAcquisitionState state, int? choiceIndex) {
  final VideoAcquisitionQuestion? question = state.question;
  if (question == null ||
      question.slot != VideoAcquisitionSlot.resource ||
      choiceIndex == null ||
      choiceIndex < 0 ||
      choiceIndex >= question.options.length) {
    return null;
  }
  final String id = question.options[choiceIndex].id;
  if (id == kVideoAcquisitionOptionConfirm) return state.groupCursor;
  if (!id.startsWith(kVideoAcquisitionOptionAltPrefix)) return null;
  return int.tryParse(id.substring(kVideoAcquisitionOptionAltPrefix.length));
}

({int index, VideoAcquisitionResourcePlan plan})? _indexedPlan(
  VideoAcquisitionState state,
  int index,
) {
  final VideoAcquisitionResourcePlan? plan = _planAt(state, index);
  return plan == null ? null : (index: index, plan: plan);
}

/// 给意图解析看的候选版本：正在挑版本时，问题里每个代表版本的选项（「就这个」=
/// 当前卡、`alt:N`）各一条，带上让 AI 能比较「哪个更小 / 做种更多」的事实。
/// 选项本身没有 label（页面按 i18n 渲染），不给这份 AI 只能看见 `confirm` /
/// `alt:3` 这种 id，回答不了「哪个最好」（BUG-2933）。不在挑版本时为空。
List<Map<String, Object?>> videoAcquisitionCandidateContext(
  VideoAcquisitionState state,
) {
  final VideoAcquisitionQuestion? question = state.question;
  if (state.stage != VideoAcquisitionStage.awaitingResourceConfirm ||
      question == null ||
      question.slot != VideoAcquisitionSlot.resource) {
    return const <Map<String, Object?>>[];
  }
  return <Map<String, Object?>>[
    for (int i = 0; i < question.options.length; i++)
      ?_candidateOf(state, i, question.options[i].id),
  ];
}

Map<String, Object?>? _candidateOf(
  VideoAcquisitionState state,
  int optionIndex,
  String optionId,
) {
  final int? index = optionId == kVideoAcquisitionOptionConfirm
      ? state.groupCursor
      : optionId.startsWith(kVideoAcquisitionOptionAltPrefix)
      ? int.tryParse(
          optionId.substring(kVideoAcquisitionOptionAltPrefix.length),
        )
      : null;
  if (index == null) return null;
  final VideoAcquisitionResourcePlan? plan = _planAt(state, index);
  if (plan == null) return null;
  return <String, Object?>{
    'optionIndex': optionIndex,
    'rank': index + 1,
    'current': index == state.groupCursor,
    ...videoAcquisitionVersionArgs(plan),
  };
}

/// `choose` = 在回答当前问题：等价于点了 `question.options[choiceIndex]`。
VideoAcquisitionReduction _onAiChoose(
  VideoAcquisitionState state,
  VideoAcquisitionIntentPatch patch,
  VideoAcquisitionDefaults defaults,
) {
  final VideoAcquisitionQuestion? question = state.question;
  final int? index = patch.choiceIndex;
  if (question == null ||
      index == null ||
      index < 0 ||
      index >= question.options.length) {
    return _unclear(state);
  }
  final bool? remember = switch (question.slot) {
    VideoAcquisitionSlot.quality =>
      patch.qualityRemember ?? _rememberDefaultOf(question),
    VideoAcquisitionSlot.subtitleLanguage =>
      patch.subtitleLanguageRemember ?? _rememberDefaultOf(question),
    _ => null,
  };
  return _applyChoice(
    state,
    slot: question.slot,
    optionId: question.options[index].id,
    remember: remember,
    defaults: defaults,
  );
}

bool? _rememberDefaultOf(VideoAcquisitionQuestion question) =>
    question.rememberToggle ? question.rememberDefault : null;

/// 正在回答 [slot] 的问题时，AI 补丁没带 `*Remember` 就沿用问题的勾选默认——与
/// 点 chip / AI `choose` 同口径。否则「只问一次」在打字回答这条路上不成立：偏好
/// `''` 时问题带 `rememberDefault: true`，用户打「日语字幕」被判成 `provide` 却不
/// 写偏好，下次会话再问一遍。不在回答该槽位（无挂起问题 / 问的是别的槽位）时
/// 补丁仍是单次覆盖，不碰偏好。
bool? _rememberDefaultForSlot(
  VideoAcquisitionQuestion? question,
  VideoAcquisitionSlot slot,
) => question != null && question.slot == slot
    ? _rememberDefaultOf(question)
    : null;

/// `provide` = 把补丁里非空字段并进槽位，然后从当前阶段继续。
VideoAcquisitionReduction _onAiProvide(
  VideoAcquisitionState state,
  VideoAcquisitionIntentPatch patch,
  VideoAcquisitionDefaults defaults,
) {
  final (VideoAcquisitionState patched, List<VideoAcquisitionEffect> effects) =
      _applyPatch(state, patch);
  if (patched.chosenItem == null) {
    if (patch.workQueries.isNotEmpty) {
      final (VideoAcquisitionState s, List<VideoAcquisitionEffect> e) =
          _startWorkSearch(patched, patch.workQueries);
      return (s, <VideoAcquisitionEffect>[...effects, ...e]);
    }
    if (patched.question != null) {
      return (_reask(patched), effects);
    }
    return _withEffects(_unclear(patched), effects);
  }
  return _withEffects(_resumeAfterPatch(patched, patch, defaults), effects);
}

/// 已选定作品后收到新信息：按阶段决定从哪里继续。
VideoAcquisitionReduction _resumeAfterPatch(
  VideoAcquisitionState state,
  VideoAcquisitionIntentPatch patch,
  VideoAcquisitionDefaults defaults,
) {
  if (patch.scope != null) return _changeScope(state, patch.scope!, defaults);
  switch (state.stage) {
    case VideoAcquisitionStage.collectingSlots:
      return _advance(state, defaults);
    case VideoAcquisitionStage.awaitingResourceConfirm:
      if (patch.season != null) return _advance(state, defaults);
      final bool refilter =
          patch.quality != null ||
          patch.mode != null ||
          patch.episode != null ||
          patch.episodeRange != null ||
          patch.allEpisodes != null;
      if (refilter) return _refilter(state, defaults);
      return (_reask(state), _noEffects);
    case VideoAcquisitionStage.idle:
    case VideoAcquisitionStage.resolvingWork:
    case VideoAcquisitionStage.awaitingWorkChoice:
    case VideoAcquisitionStage.loadingDetails:
    case VideoAcquisitionStage.resolvingResources:
    case VideoAcquisitionStage.resolvingFranchise:
    case VideoAcquisitionStage.planningFranchise:
    case VideoAcquisitionStage.awaitingFranchiseConfirm:
    case VideoAcquisitionStage.submitting:
    case VideoAcquisitionStage.done:
    case VideoAcquisitionStage.cancelled:
      if (state.question != null) return (_reask(state), _noEffects);
      return (state, _noEffects);
  }
}

/// 补丁 → 槽位。`quality` / `subtitleLanguage` 带 `*Remember: true` 才写偏好。
VideoAcquisitionReduction _applyPatch(
  VideoAcquisitionState state,
  VideoAcquisitionIntentPatch patch,
) {
  final List<VideoAcquisitionEffect> effects = <VideoAcquisitionEffect>[];
  VideoAcquisitionSlots slots = state.slots;
  if (patch.category != null) {
    slots = slots.copyWith(category: patch.category);
  }
  if (patch.season != null) {
    slots = slots.copyWith(season: patch.season, allSeasons: false);
  }
  if (patch.mode != null) {
    slots = slots.copyWith(mode: patch.mode);
  }
  final VideoAcquisitionEpisodes? episodes = _episodesOf(patch);
  if (episodes != null) {
    slots = slots.copyWith(episodes: episodes);
  }
  final VideoAcquisitionQuestion? pending = state.question;
  final VideoAcquisitionQuality? quality = patch.quality;
  if (quality != null) {
    final bool remember =
        patch.qualityRemember ??
        _rememberDefaultForSlot(pending, VideoAcquisitionSlot.quality) ??
        false;
    slots = slots.copyWith(quality: quality, qualityRemember: remember);
    if (remember) {
      effects.add(
        VideoAcquisitionPersistPreferenceEffect(
          VideoAcquisitionPreference.quality,
          quality.storageKey,
        ),
      );
    }
  }
  final VideoAcquisitionScope? scope = patch.scope;
  if (scope != null) slots = slots.copyWith(scope: scope);
  final String? subtitleLanguage = patch.subtitleLanguage?.trim();
  if (subtitleLanguage != null && subtitleLanguage.isNotEmpty) {
    final bool remember =
        patch.subtitleLanguageRemember ??
        _rememberDefaultForSlot(
          pending,
          VideoAcquisitionSlot.subtitleLanguage,
        ) ??
        false;
    slots = slots.copyWith(
      subtitleLanguage: subtitleLanguage,
      subtitleLanguageRemember: remember,
    );
    if (remember) {
      effects.add(
        VideoAcquisitionPersistPreferenceEffect(
          VideoAcquisitionPreference.subtitleLanguage,
          subtitleLanguage,
        ),
      );
    }
  }
  return (state.copyWith(slots: slots), effects);
}

VideoAcquisitionEpisodes? _episodesOf(VideoAcquisitionIntentPatch patch) {
  final ({int from, int to})? range = patch.episodeRange;
  if (range != null) {
    return range.from <= range.to
        ? VideoAcquisitionEpisodeRange(range.from, range.to)
        : VideoAcquisitionEpisodeRange(range.to, range.from);
  }
  final int? episode = patch.episode;
  if (episode != null) return VideoAcquisitionSingleEpisode(episode);
  if (patch.allEpisodes == true) return const VideoAcquisitionAllEpisodes();
  return null;
}

/// AI 不可用：有问题挂起就重出；还没选作品就把原文当唯一查询词；否则没听懂。
VideoAcquisitionReduction _onAiUnavailable(
  VideoAcquisitionState state,
  VideoAcquisitionAiUnavailableEvent event,
) {
  final VideoAcquisitionQuestion? question = state.question;
  final VideoAcquisitionState said = state
      .copyWith(busy: false)
      .say(
        VideoAcquisitionSay(
          VideoAcquisitionSayKind.aiUnavailable,
          args: <String, Object?>{'code': event.code},
        ),
      );
  if (question != null) return (_ask(said, question), _noEffects);
  if (said.chosenItem == null) {
    return _startWorkSearch(said, <String>[event.utterance]);
  }
  return _unclear(said);
}

VideoAcquisitionReduction _unclear(VideoAcquisitionState state) => (
  _sayThenReask(
    state,
    const VideoAcquisitionSay(VideoAcquisitionSayKind.unclear),
  ),
  _noEffects,
);

// ---------------------------------------------------------------------------
// 作品搜索 / 多义判定 / 选定
// ---------------------------------------------------------------------------

/// [aliasResolved] 为 true 只用于「别名解析后按正式名再搜」这一轮：用户新说的
/// 作品名一律从 false 起算，每轮最多查一次别名。
VideoAcquisitionReduction _startWorkSearch(
  VideoAcquisitionState state,
  List<String> rawQueries, {
  bool aliasResolved = false,
}) {
  final Set<String> seen = <String>{};
  final List<String> queries = <String>[
    for (final String raw in rawQueries)
      if (raw.trim().isNotEmpty && seen.add(raw.trim())) raw.trim(),
  ].take(kVideoAcquisitionMaxWorkQueries).toList(growable: false);
  if (queries.isEmpty) return _unclear(state);
  final VideoAcquisitionState next = state.copyWith(
    stage: VideoAcquisitionStage.resolvingWork,
    slots: state.slots.copyWith(workQueries: queries),
    pendingQueries: queries.sublist(1),
    workCandidates: const <VideoDiscoveryItem>[],
    clearQuestion: true,
    busy: true,
    aliasResolved: aliasResolved,
  );
  return (
    next,
    <VideoAcquisitionEffect>[
      VideoAcquisitionSearchWorksEffect(
        query: queries.first,
        category: next.slots.category,
      ),
    ],
  );
}

VideoAcquisitionReduction _workNotFound(
  VideoAcquisitionState state,
  String query,
) => (
  state
      .copyWith(stage: VideoAcquisitionStage.idle, busy: false)
      .say(
        VideoAcquisitionSay(
          VideoAcquisitionSayKind.workNotFound,
          args: <String, Object?>{'query': query},
        ),
      ),
  _noEffects,
);

/// 别名解析回来：去掉已经搜过的词；剩下的按正式名再搜一轮（用户原话仍排在
/// [VideoAcquisitionSlots.workQueries] 首位，供 AI 判定与「没找到」提示用）。
VideoAcquisitionReduction _onAliasResolved(
  VideoAcquisitionState state,
  VideoAcquisitionAliasResolvedEvent event,
) {
  if (state.stage != VideoAcquisitionStage.resolvingWork) {
    return (state, _noEffects);
  }
  final List<String> tried = state.slots.workQueries;
  final Set<String> seen = <String>{
    for (final String query in tried) query.trim().toLowerCase(),
  };
  final List<String> titles = <String>[
    for (final String title in event.titles)
      if (title.trim().isNotEmpty && seen.add(title.trim().toLowerCase()))
        title.trim(),
  ];
  if (titles.isEmpty) return _workNotFound(state, event.query);
  final VideoAcquisitionState said = state.say(
    VideoAcquisitionSay(
      VideoAcquisitionSayKind.workAliasResolved,
      args: <String, Object?>{
        'query': event.query,
        'titles': titles.take(kVideoAcquisitionMaxWorkQueries).join(' / '),
      },
    ),
  );
  final (VideoAcquisitionState next, List<VideoAcquisitionEffect> effects) =
      _startWorkSearch(said, titles, aliasResolved: true);
  return (
    next.copyWith(
      slots: next.slots.copyWith(
        workQueries: <String>[event.query, ...next.slots.workQueries],
      ),
    ),
    effects,
  );
}

VideoAcquisitionReduction _onWorksLoaded(
  VideoAcquisitionState state,
  VideoAcquisitionWorksLoadedEvent event,
  VideoAcquisitionDefaults defaults,
) {
  if (state.stage != VideoAcquisitionStage.resolvingWork) {
    return (state, _noEffects);
  }
  final List<VideoDiscoveryItem> items = event.items;
  if (items.isEmpty) {
    if (state.pendingQueries.isNotEmpty) {
      final String query = state.pendingQueries.first;
      return (
        state.copyWith(pendingQueries: state.pendingQueries.sublist(1)),
        <VideoAcquisitionEffect>[
          VideoAcquisitionSearchWorksEffect(
            query: query,
            category: state.slots.category,
          ),
        ],
      );
    }
    final List<String> tried = state.slots.workQueries;
    if (!state.aliasResolved && tried.isNotEmpty) {
      // 用户说的可能是别名 / 俗称（「fx外汇战士」），资料站只收正式名：先去
      // 联网资料里查这个叫法是哪部作品，再按正式名搜一轮。
      return (
        state.copyWith(aliasResolved: true),
        <VideoAcquisitionEffect>[
          VideoAcquisitionResolveAliasEffect(query: tried.first, tried: tried),
        ],
      );
    }
    return _workNotFound(state, tried.isEmpty ? event.query : tried.first);
  }
  if (items.length == 1) {
    return _chooseWork(
      state.copyWith(busy: false),
      items.single,
      say: VideoAcquisitionSay(
        VideoAcquisitionSayKind.workChosen,
        args: <String, Object?>{'title': items.single.reference.title},
      ),
    );
  }
  final List<VideoDiscoveryItem> candidates = items
      .take(kVideoAcquisitionMaxWorkCandidates)
      .toList(growable: false);
  final VideoAcquisitionState next = state.copyWith(
    stage: VideoAcquisitionStage.awaitingWorkChoice,
    workCandidates: candidates,
    busy: true,
  );
  return (
    next,
    <VideoAcquisitionEffect>[
      VideoAcquisitionDecideIdentityEffect(
        _identityQueryOf(next, candidates, defaults),
      ),
    ],
  );
}

AiVideoIdentityQuery _identityQueryOf(
  VideoAcquisitionState state,
  List<VideoDiscoveryItem> candidates,
  VideoAcquisitionDefaults defaults,
) {
  final String? userText = _lastUserText(state);
  // 作品名（AI 从原话里抠出的查询词）在前、原话在后：`localTitles.first` 会被拿去
  // 搜联网资料，整句「帮我下载 xx 第二季 1080p」既搜不准，也不该原样外发。
  return AiVideoIdentityQuery(
    localTitles: <String>[
      ...state.slots.workQueries,
      if (userText != null && !state.slots.workQueries.contains(userText))
        userText,
    ],
    season: state.slots.season,
    candidates: <AiVideoIdentityCandidate>[
      for (final VideoDiscoveryItem item in candidates)
        AiVideoIdentityCandidate(
          key: _candidateKeyOf(item),
          titles: <String>[
            item.reference.title,
            if (item.reference.originalTitle != null)
              item.reference.originalTitle!,
            ...item.reference.aliases,
          ],
          mediaKind: item.reference.mediaKind,
          year: item.reference.year,
          episodeCount: item.metadataWork?.episodeCount,
          synopsis: item.overview,
        ),
    ],
    locale: defaults.locale,
  );
}

String _candidateKeyOf(VideoDiscoveryItem item) =>
    '${item.reference.providerId}:${item.reference.mediaId}';

String? _lastUserText(VideoAcquisitionState state) {
  for (final VideoAcquisitionMessage message in state.transcript.reversed) {
    if (message is VideoAcquisitionUserMessage) return message.text;
  }
  return null;
}

VideoAcquisitionReduction _onIdentityDecided(
  VideoAcquisitionState state,
  VideoAcquisitionIdentityDecidedEvent event,
  VideoAcquisitionDefaults defaults,
) {
  if (state.stage != VideoAcquisitionStage.awaitingWorkChoice) {
    return (state, _noEffects);
  }
  final AiVideoIdentityDecision? decision = event.decision;
  final VideoAcquisitionState idle = state.copyWith(
    busy: false,
    aiDecision: decision,
  );
  final String? decidedKey = decision?.key;
  final int matched = decidedKey == null
      ? -1
      : idle.workCandidates.indexWhere(
          (VideoDiscoveryItem item) => _candidateKeyOf(item) == decidedKey,
        );
  if (decision != null && decision.isAutoAcceptable && matched >= 0) {
    final VideoDiscoveryItem item = idle.workCandidates[matched];
    // 「换一部」作为一个不阻塞的 chip 挂在这句话上：用户不点就继续往下走。
    final VideoAcquisitionQuestion changeWork = VideoAcquisitionQuestion(
      slot: VideoAcquisitionSlot.work,
      options: const <VideoAcquisitionOption>[
        VideoAcquisitionOption(id: kVideoAcquisitionOptionNone),
      ],
    );
    final VideoAcquisitionState picked = idle
        .say(
          VideoAcquisitionSay(
            VideoAcquisitionSayKind.aiPicked,
            args: <String, Object?>{
              'title': item.reference.title,
              'confidence': decision.confidence,
              'confidencePercent': decision.confidencePercent,
            },
          ),
          question: changeWork,
        )
        .copyWith(clearQuestion: true);
    return _chooseWork(picked, item);
  }
  return (
    _askWork(idle, preselected: matched >= 0 ? matched : null),
    _noEffects,
  );
}

VideoAcquisitionState _askWork(
  VideoAcquisitionState state, {
  int? preselected,
}) {
  final List<VideoAcquisitionOption> options = <VideoAcquisitionOption>[
    for (int i = 0; i < state.workCandidates.length; i++)
      VideoAcquisitionOption(
        id: '$i',
        label: state.workCandidates[i].reference.title,
        hint: _candidateHintOf(state.workCandidates[i]),
      ),
    const VideoAcquisitionOption(id: kVideoAcquisitionOptionNone),
  ];
  return _ask(
    state,
    VideoAcquisitionQuestion(
      slot: VideoAcquisitionSlot.work,
      options: options,
      preselectedIndex: preselected,
    ),
  );
}

/// 作品候选的副标题：年份 + 原名（类别由页面按候选取 i18n，这里只放不用翻译的
/// 字面量）。
String? _candidateHintOf(VideoDiscoveryItem item) {
  final VideoMediaReference reference = item.reference;
  final String original = reference.originalTitle?.trim() ?? '';
  final List<String> parts = <String>[
    if (reference.year != null) '${reference.year}',
    if (original.isNotEmpty && original != reference.title) original,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// 选定作品：落 `chosenItem`，拉详情。
VideoAcquisitionReduction _chooseWork(
  VideoAcquisitionState state,
  VideoDiscoveryItem item, {
  VideoAcquisitionSay? say,
}) {
  VideoAcquisitionState next = state;
  if (say != null) next = next.say(say);
  next = next.copyWith(
    stage: VideoAcquisitionStage.loadingDetails,
    chosenItem: item,
    workCandidates: const <VideoDiscoveryItem>[],
    clearQuestion: true,
    busy: true,
  );
  return (
    next,
    <VideoAcquisitionEffect>[VideoAcquisitionLoadDetailsEffect(item)],
  );
}

/// 「都不是 / 换一部」：保留对话记录与用户已说过的通用偏好，回到等文本。
VideoAcquisitionReduction _restartWork(VideoAcquisitionState state) {
  final List<String> queries = state.slots.workQueries;
  final String query = queries.isEmpty
      ? (_lastUserText(state) ?? '')
      : queries.first;
  return (
    _resetToIdle(state).say(
      VideoAcquisitionSay(
        VideoAcquisitionSayKind.workNotFound,
        args: <String, Object?>{'query': query},
      ),
    ),
    _noEffects,
  );
}

// ---------------------------------------------------------------------------
// 详情 → 槽位收集
// ---------------------------------------------------------------------------

VideoAcquisitionReduction _onDetailsLoaded(
  VideoAcquisitionState state,
  VideoAcquisitionDetailsLoadedEvent event,
  VideoAcquisitionDefaults defaults,
) {
  if (state.stage != VideoAcquisitionStage.loadingDetails) {
    return (state, _noEffects);
  }
  final VideoDiscoveryItem item = state.chosenItem!;
  final VideoMetadataWork? work = event.work ?? item.metadataWork;
  final VideoAiringStatus? airing = work?.airingStatus;
  final VideoAcquisitionState next = state.copyWith(
    stage: VideoAcquisitionStage.collectingSlots,
    // 资源搜索 / 订阅都按这份身份走：搜索列表项的别名可能只有元数据的风格化
    // 写法（TMDB `FX Senshi KURUMICHAN`，Nyaa 0 条），用详情的罗马字 / 英文名
    // 补齐——与资源搜索页的别名补齐端口同一条判据（BUG-2794 / BUG-2854）。
    chosenItem: item.withReference(item.reference.withWorkLatinTitles(work)),
    work: work,
    airing: airing,
    clearAiring: airing == null,
    contentLanguage: resolveVideoWorkContentLanguage(work, item.reference),
    presence: event.presence,
    alreadySubscribed: event.alreadySubscribed,
    busy: false,
  );
  return _advance(next, defaults);
}

/// 槽位决策表：按顺序找第一个未定的槽位提问；全部就绪 → 搜资源。
VideoAcquisitionReduction _advance(
  VideoAcquisitionState state,
  VideoAcquisitionDefaults defaults,
) {
  VideoAcquisitionState s = state.copyWith(
    stage: VideoAcquisitionStage.collectingSlots,
    busy: false,
  );
  final bool franchise = s.slots.scope.isFranchise;
  final List<_SlotStep Function(VideoAcquisitionState)> rows =
      <_SlotStep Function(VideoAcquisitionState)>[
        // 整套：在库 / 模式 / 季都是逐部决定的，不在会话层问。
        if (!franchise) ...<_SlotStep Function(VideoAcquisitionState)>[
          _decidePresence,
          _decideMode,
          _decideSeason,
        ],
        (VideoAcquisitionState current) => _decideQuality(current, defaults),
        (VideoAcquisitionState current) =>
            _decideSubtitleLanguage(current, defaults),
        (VideoAcquisitionState current) =>
            _decideTargetSource(current, defaults),
      ];
  for (final _SlotStep Function(VideoAcquisitionState) row in rows) {
    final _SlotStep step = row(s);
    s = step.state;
    if (step.asked) return (s, _noEffects);
    if (s.stage != VideoAcquisitionStage.collectingSlots) {
      // 某一行判定为无法继续（如没有来源），已经把状态收掉。
      return (s, _noEffects);
    }
  }
  return franchise ? _startFranchise(s) : _searchResources(s);
}

/// 已在库 / 已订阅：先说明，让用户选继续或取消。
_SlotStep _decidePresence(VideoAcquisitionState state) {
  final bool inLibrary = state.presence?.inLibrary == true;
  if (!(inLibrary || state.alreadySubscribed) || state.presenceAcknowledged) {
    return (state: state, asked: false);
  }
  final String title = state.reference!.title;
  VideoAcquisitionState next = state;
  if (inLibrary) {
    next = next.say(
      VideoAcquisitionSay(
        VideoAcquisitionSayKind.alreadyInLibrary,
        args: <String, Object?>{
          'title': title,
          'highestEpisode': state.presence?.highestEpisode,
        },
      ),
    );
  }
  if (state.alreadySubscribed) {
    next = next.say(
      VideoAcquisitionSay(
        VideoAcquisitionSayKind.alreadySubscribed,
        args: <String, Object?>{'title': title},
      ),
    );
  }
  return (
    state: _ask(
      next,
      const VideoAcquisitionQuestion(
        slot: VideoAcquisitionSlot.presence,
        options: <VideoAcquisitionOption>[
          VideoAcquisitionOption(id: kVideoAcquisitionOptionContinue),
          VideoAcquisitionOption(id: kVideoAcquisitionOptionCancel),
        ],
      ),
    ),
    asked: true,
  );
}

/// mode：电影 / 已完结 / 已取消 → download 不问；放送中 / 未定 / 未知 → 问。
_SlotStep _decideMode(VideoAcquisitionState state) {
  if (state.slots.mode != null) return (state: state, asked: false);
  final VideoMediaReference reference = state.reference!;
  final VideoAiringStatus? airing = state.airing;
  final bool downloadOnly =
      reference.mediaKind == VideoMetadataMediaKind.movie ||
      airing == VideoAiringStatus.finished ||
      airing == VideoAiringStatus.cancelled;
  if (downloadOnly) {
    return (
      state: state.copyWith(
        slots: state.slots.copyWith(mode: VideoAcquisitionMode.download),
      ),
      asked: false,
    );
  }
  VideoAcquisitionState next = state;
  if (airing == null && state.question?.slot != VideoAcquisitionSlot.mode) {
    next = next.say(
      VideoAcquisitionSay(
        VideoAcquisitionSayKind.airingUnknown,
        args: <String, Object?>{'title': reference.title},
      ),
    );
  }
  return (
    state: _ask(
      next,
      VideoAcquisitionQuestion(
        slot: VideoAcquisitionSlot.mode,
        options: <VideoAcquisitionOption>[
          VideoAcquisitionOption(id: VideoAcquisitionMode.download.name),
          VideoAcquisitionOption(id: VideoAcquisitionMode.subscribe.name),
        ],
      ),
    ),
    asked: true,
  );
}

/// season：仅非 anime 的多季剧集且用户没指定。
_SlotStep _decideSeason(VideoAcquisitionState state) {
  final VideoMediaReference reference = state.reference!;
  final int seasonCount = state.work?.seasonCount ?? 1;
  final bool ask =
      reference.mediaKind == VideoMetadataMediaKind.tv &&
      reference.discoveryCategory != VideoDiscoveryCategory.anime &&
      seasonCount > 1 &&
      state.slots.season == null &&
      !state.slots.allSeasons;
  if (!ask) return (state: state, asked: false);
  final int shown = seasonCount < kVideoAcquisitionMaxSeasonOptions
      ? seasonCount
      : kVideoAcquisitionMaxSeasonOptions;
  return (
    state: _ask(
      state,
      VideoAcquisitionQuestion(
        slot: VideoAcquisitionSlot.season,
        options: <VideoAcquisitionOption>[
          for (int i = 1; i <= shown; i++) VideoAcquisitionOption(id: '$i'),
          const VideoAcquisitionOption(id: kVideoAcquisitionOptionAll),
        ],
      ),
    ),
    asked: true,
  );
}

/// quality：偏好固定档直接填；`''` 问且默认勾「以后默认」；`ask` 问且不勾。
_SlotStep _decideQuality(
  VideoAcquisitionState state,
  VideoAcquisitionDefaults defaults,
) {
  if (state.slots.quality != null) return (state: state, asked: false);
  final String pref = defaults.qualityPref.trim();
  final VideoAcquisitionQuality? fixed = VideoAcquisitionQuality.fromStorageKey(
    pref,
  );
  if (fixed != null) {
    return (
      state: state.copyWith(slots: state.slots.copyWith(quality: fixed)),
      asked: false,
    );
  }
  final bool askEveryTime = pref.toLowerCase() == kVideoAcquisitionPrefAsk;
  return (
    state: _ask(
      state,
      VideoAcquisitionQuestion(
        slot: VideoAcquisitionSlot.quality,
        options: <VideoAcquisitionOption>[
          for (final VideoAcquisitionQuality quality
              in VideoAcquisitionQuality.values)
            VideoAcquisitionOption(id: quality.storageKey),
        ],
        rememberToggle: true,
        rememberDefault: !askEveryTime,
      ),
    ),
    asked: true,
  );
}

/// subtitleLanguage：偏好直接填 / `''` 问一次（预选跟随作品语言）/ `ask` 每次问；
/// 定为 `original` 后解析作品语言，判不出只追问这一次（不含 original 选项）。
_SlotStep _decideSubtitleLanguage(
  VideoAcquisitionState state,
  VideoAcquisitionDefaults defaults,
) {
  VideoAcquisitionState next = state;
  if (next.slots.subtitleLanguage == null) {
    final String pref = defaults.subtitleLanguagePref.trim();
    if (pref.isEmpty || pref.toLowerCase() == kVideoAcquisitionPrefAsk) {
      return (
        state: _ask(
          next,
          _subtitleLanguageQuestion(
            includeOriginal: true,
            rememberToggle: true,
            rememberDefault: pref.isEmpty,
          ),
        ),
        asked: true,
      );
    }
    next = next.copyWith(slots: next.slots.copyWith(subtitleLanguage: pref));
  }
  if (next.slots.subtitleLanguage != kVideoAcquisitionSubtitleOriginal) {
    return (state: next, asked: false);
  }
  final VideoWorkContentLanguage language =
      next.contentLanguage ?? VideoWorkContentLanguage.unknown;
  final String? code = language.code;
  if (code != null) {
    if (!next.subtitleLanguageResolutionSaid) {
      next = next
          .say(
            VideoAcquisitionSay(
              VideoAcquisitionSayKind.subtitleLanguageResolved,
              args: <String, Object?>{
                'language': code,
                'evidence': language.evidence.name,
              },
            ),
          )
          .copyWith(subtitleLanguageResolutionSaid: true);
    }
    return (state: next, asked: false);
  }
  if (!next.subtitleLanguageAsked) {
    next = next
        .say(
          const VideoAcquisitionSay(
            VideoAcquisitionSayKind.subtitleLanguageUnresolved,
          ),
        )
        .copyWith(subtitleLanguageAsked: true);
  }
  return (
    state: _ask(
      next,
      _subtitleLanguageQuestion(
        includeOriginal: false,
        rememberToggle: false,
        rememberDefault: false,
      ),
    ),
    asked: true,
  );
}

VideoAcquisitionQuestion _subtitleLanguageQuestion({
  required bool includeOriginal,
  required bool rememberToggle,
  required bool rememberDefault,
}) => VideoAcquisitionQuestion(
  slot: VideoAcquisitionSlot.subtitleLanguage,
  options: <VideoAcquisitionOption>[
    if (includeOriginal)
      const VideoAcquisitionOption(id: kVideoAcquisitionSubtitleOriginal),
    for (final String code in kVideoAcquisitionSubtitleLanguageCodes)
      VideoAcquisitionOption(id: code),
    const VideoAcquisitionOption(id: kVideoAcquisitionSubtitleNone),
  ],
  rememberToggle: rememberToggle,
  rememberDefault: rememberDefault,
  preselectedIndex: includeOriginal ? 0 : null,
);

/// targetSource：偏好默认来源 / 唯一来源直接填；多来源无默认才问。
_SlotStep _decideTargetSource(
  VideoAcquisitionState state,
  VideoAcquisitionDefaults defaults,
) {
  if (state.slots.targetSourceId != null) return (state: state, asked: false);
  final List<VideoAcquisitionSource> sources = defaults.sources;
  final int? preferred = defaults.defaultSourceId;
  final bool preferredKnown =
      preferred != null &&
      preferred != 0 &&
      sources.any((VideoAcquisitionSource source) => source.id == preferred);
  if (preferredKnown) {
    return (
      state: state.copyWith(
        slots: state.slots.copyWith(targetSourceId: preferred),
      ),
      asked: false,
    );
  }
  if (sources.length == 1) {
    return (
      state: state.copyWith(
        slots: state.slots.copyWith(targetSourceId: sources.single.id),
      ),
      asked: false,
    );
  }
  if (sources.isEmpty) {
    return (
      state: _failToIdle(state, kVideoAcquisitionFailureNoSources),
      asked: false,
    );
  }
  return (
    state: _ask(
      state,
      VideoAcquisitionQuestion(
        slot: VideoAcquisitionSlot.targetSource,
        options: <VideoAcquisitionOption>[
          for (final VideoAcquisitionSource source in sources)
            VideoAcquisitionOption(id: '${source.id}', label: source.label),
        ],
      ),
    ),
    asked: true,
  );
}

VideoAcquisitionReduction _searchResources(VideoAcquisitionState state) {
  final VideoMediaReference reference = state.reference!;
  final int? season = state.slots.allSeasons
      ? null
      : (state.slots.season ?? reference.season);
  final VideoAcquisitionState next = state.copyWith(
    stage: VideoAcquisitionStage.resolvingResources,
    groups: const <VideoResourceVersionGroup>[],
    eligibleGroups: const <VideoResourceVersionGroup>[],
    availableResolutions: const <String>[],
    groupCursor: 0,
    clearPlan: true,
    clearQuestion: true,
    busy: true,
  );
  return (
    next,
    <VideoAcquisitionEffect>[
      VideoAcquisitionSearchResourcesEffect(
        reference: reference,
        season: season,
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// chip 回填
// ---------------------------------------------------------------------------

VideoAcquisitionReduction _onChipChosen(
  VideoAcquisitionState state,
  VideoAcquisitionChipChosenEvent event,
  VideoAcquisitionDefaults defaults,
) {
  // 作品操作条（换一部 / 整个系列 / 全部剧场版…）不是阻塞问题：选定作品后到
  // 提交前任何时候都可点，页面据 [videoAcquisitionWorkActions] 渲染。
  if (event.slot == VideoAcquisitionSlot.work &&
      videoAcquisitionWorkActions(state).contains(event.optionId)) {
    if (event.optionId == kVideoAcquisitionOptionNone) {
      return _restartWork(state);
    }
    final VideoAcquisitionScope? scope = VideoAcquisitionScope.fromStorageKey(
      event.optionId.substring(kVideoAcquisitionOptionScopePrefix.length),
    );
    if (scope != null) return _changeScope(state, scope, defaults);
  }
  final VideoAcquisitionQuestion? question = state.question;
  if (question == null || question.slot != event.slot) {
    return (state, _noEffects);
  }
  final bool known = question.options.any(
    (VideoAcquisitionOption option) => option.id == event.optionId,
  );
  if (!known) return (state, _noEffects);
  return _applyChoice(
    state,
    slot: event.slot,
    optionId: event.optionId,
    remember: event.remember,
    defaults: defaults,
  );
}

/// 一个选项落到槽位上（chip 与 AI `choose` 共用）。
VideoAcquisitionReduction _applyChoice(
  VideoAcquisitionState state, {
  required VideoAcquisitionSlot slot,
  required String optionId,
  required bool? remember,
  required VideoAcquisitionDefaults defaults,
}) {
  switch (slot) {
    case VideoAcquisitionSlot.work:
      return _chooseWorkOption(state, optionId);
    case VideoAcquisitionSlot.season:
      return _chooseSeasonOption(state, optionId, defaults);
    case VideoAcquisitionSlot.mode:
      final VideoAcquisitionMode? mode = _modeOf(optionId);
      if (mode == null) return (state, _noEffects);
      return _advance(
        state.copyWith(slots: state.slots.copyWith(mode: mode)),
        defaults,
      );
    case VideoAcquisitionSlot.quality:
      return _chooseQualityOption(state, optionId, remember, defaults);
    case VideoAcquisitionSlot.subtitleLanguage:
      return _chooseSubtitleLanguageOption(state, optionId, remember, defaults);
    case VideoAcquisitionSlot.targetSource:
      final int? id = int.tryParse(optionId);
      if (id == null) return (state, _noEffects);
      return _advance(
        state.copyWith(slots: state.slots.copyWith(targetSourceId: id)),
        defaults,
      );
    case VideoAcquisitionSlot.presence:
      if (optionId == kVideoAcquisitionOptionCancel) return _cancel(state);
      return _advance(state.copyWith(presenceAcknowledged: true), defaults);
    case VideoAcquisitionSlot.resource:
      if (optionId.startsWith(kVideoAcquisitionOptionAltPrefix)) {
        return _chooseAlternative(state, optionId, defaults);
      }
      return switch (optionId) {
        kVideoAcquisitionOptionConfirm => _submit(state, defaults),
        kVideoAcquisitionOptionNext => _nextGroup(state),
        kVideoAcquisitionOptionLatest => _onlyLatestEpisode(state),
        kVideoAcquisitionOptionAll => _allEpisodesAgain(state),
        kVideoAcquisitionOptionCancel => _cancel(state),
        _ => (state, _noEffects),
      };
    case VideoAcquisitionSlot.franchise:
      return switch (optionId) {
        kVideoAcquisitionOptionSubmitAll => _submitFranchise(state),
        kVideoAcquisitionOptionCancel => _cancel(state),
        _ => (state, _noEffects),
      };
    case VideoAcquisitionSlot.franchiseFallback:
      if (optionId == kVideoAcquisitionOptionCancel) return _cancel(state);
      if (optionId != kVideoAcquisitionOptionContinue) {
        return (state, _noEffects);
      }
      return _advance(
        state.copyWith(
          slots: state.slots.copyWith(scope: VideoAcquisitionScope.work),
        ),
        defaults,
      );
    case VideoAcquisitionSlot.resolutionFallback:
      if (optionId == kVideoAcquisitionOptionCancel) return _cancel(state);
      return _refilter(
        state.copyWith(
          slots: state.slots.copyWith(quality: _qualityForResolution(optionId)),
        ),
        defaults,
      );
    case VideoAcquisitionSlot.subscribeFallback:
      if (optionId == kVideoAcquisitionOptionCancel) return _cancel(state);
      if (optionId != kVideoAcquisitionOptionDownload) {
        return (state, _noEffects);
      }
      return _refilter(
        state.copyWith(
          slots: state.slots.copyWith(mode: VideoAcquisitionMode.download),
        ),
        defaults,
      );
  }
}

VideoAcquisitionReduction _chooseWorkOption(
  VideoAcquisitionState state,
  String optionId,
) {
  if (optionId == kVideoAcquisitionOptionNone) return _restartWork(state);
  final int? index = int.tryParse(optionId);
  if (index == null || index < 0 || index >= state.workCandidates.length) {
    return (state, _noEffects);
  }
  final VideoDiscoveryItem item = state.workCandidates[index];
  return _chooseWork(
    state,
    item,
    say: VideoAcquisitionSay(
      VideoAcquisitionSayKind.workChosen,
      args: <String, Object?>{'title': item.reference.title},
    ),
  );
}

VideoAcquisitionReduction _chooseSeasonOption(
  VideoAcquisitionState state,
  String optionId,
  VideoAcquisitionDefaults defaults,
) {
  if (optionId == kVideoAcquisitionOptionAll) {
    return _advance(
      state.copyWith(slots: state.slots.copyWith(allSeasons: true)),
      defaults,
    );
  }
  final int? season = int.tryParse(optionId);
  if (season == null || season < 1) return (state, _noEffects);
  return _advance(
    state.copyWith(
      slots: state.slots.copyWith(season: season, allSeasons: false),
    ),
    defaults,
  );
}

VideoAcquisitionReduction _chooseQualityOption(
  VideoAcquisitionState state,
  String optionId,
  bool? remember,
  VideoAcquisitionDefaults defaults,
) {
  final VideoAcquisitionQuality? quality =
      VideoAcquisitionQuality.fromStorageKey(optionId);
  if (quality == null) return (state, _noEffects);
  final bool persist = remember == true;
  final VideoAcquisitionState next = state.copyWith(
    slots: state.slots.copyWith(quality: quality, qualityRemember: persist),
  );
  return _withEffects(_advance(next, defaults), <VideoAcquisitionEffect>[
    if (persist)
      VideoAcquisitionPersistPreferenceEffect(
        VideoAcquisitionPreference.quality,
        quality.storageKey,
      ),
  ]);
}

VideoAcquisitionReduction _chooseSubtitleLanguageOption(
  VideoAcquisitionState state,
  String optionId,
  bool? remember,
  VideoAcquisitionDefaults defaults,
) {
  final bool persist = remember == true;
  final VideoAcquisitionState next = state.copyWith(
    slots: state.slots.copyWith(
      subtitleLanguage: optionId,
      subtitleLanguageRemember: persist,
    ),
  );
  return _withEffects(_advance(next, defaults), <VideoAcquisitionEffect>[
    if (persist)
      VideoAcquisitionPersistPreferenceEffect(
        VideoAcquisitionPreference.subtitleLanguage,
        optionId,
      ),
  ]);
}

VideoAcquisitionMode? _modeOf(String optionId) {
  for (final VideoAcquisitionMode mode in VideoAcquisitionMode.values) {
    if (mode.name == optionId) return mode;
  }
  return null;
}

/// 分辨率串 → 档位；没有对应档（如 `576p`）→ `any`（picker 只认档位）。
VideoAcquisitionQuality _qualityForResolution(String resolution) {
  for (final VideoAcquisitionQuality quality
      in VideoAcquisitionQuality.values) {
    if (quality != VideoAcquisitionQuality.any &&
        quality != VideoAcquisitionQuality.best &&
        quality.matchesResolution(resolution)) {
      return quality;
    }
  }
  return VideoAcquisitionQuality.any;
}

// ---------------------------------------------------------------------------
// 资源阶段
// ---------------------------------------------------------------------------

VideoAcquisitionReduction _onResourcesLoaded(
  VideoAcquisitionState state,
  VideoAcquisitionResourcesLoadedEvent event,
  VideoAcquisitionDefaults defaults,
) {
  if (state.stage != VideoAcquisitionStage.resolvingResources) {
    return (state, _noEffects);
  }
  final VideoMediaReference reference = state.reference!;
  final VideoAcquisitionState next = state.copyWith(
    groups: buildVideoResourceVersionGroups(
      cleanResourceCandidates(
        event.items,
        skipExtras: defaults.skipExtras,
        movieYear: reference.mediaKind == VideoMetadataMediaKind.movie
            ? reference.year
            : null,
      ),
    ),
    busy: false,
  );
  return _refilter(next, defaults);
}

/// 用当前 mode / quality 重过滤 `groups`（再按片源 / 码率偏好排序），并展示第一张
/// 给得出计划的卡。
VideoAcquisitionReduction _refilter(
  VideoAcquisitionState state,
  VideoAcquisitionDefaults defaults,
) {
  final VideoAcquisitionMode mode = state.slots.mode!;
  final VideoAcquisitionQuality quality = state.slots.quality!;
  final VideoAcquisitionResourceOutcome outcome = filterResourceGroups(
    state.groups,
    mode: mode,
    quality: quality,
    source: defaults.sourcePref,
    bitrate: defaults.bitratePref,
  );
  final VideoAcquisitionState base = state.copyWith(
    eligibleGroups: outcome.eligible,
    availableResolutions: outcome.availableResolutions,
    groupCursor: 0,
    clearPlan: true,
    busy: false,
  );
  switch (outcome.reason) {
    case VideoAcquisitionResourceReason.noCandidates:
      return (
        _failToIdle(base, kVideoAcquisitionFailureNoCandidates),
        _noEffects,
      );
    case VideoAcquisitionResourceReason.resolutionMismatch:
      return (
        _ask(
          base.copyWith(stage: VideoAcquisitionStage.collectingSlots),
          VideoAcquisitionQuestion(
            slot: VideoAcquisitionSlot.resolutionFallback,
            options: <VideoAcquisitionOption>[
              for (final String resolution in outcome.availableResolutions)
                VideoAcquisitionOption(id: resolution, label: resolution),
              const VideoAcquisitionOption(id: kVideoAcquisitionOptionCancel),
            ],
            args: <String, Object?>{
              'wanted': quality.storageKey,
              'available': outcome.availableResolutions,
            },
          ),
        ),
        _noEffects,
      );
    case VideoAcquisitionResourceReason.noSubscribableVersion:
      return (_askSubscribeFallback(base), _noEffects);
    case VideoAcquisitionResourceReason.ok:
      return _present(base, 0);
  }
}

VideoAcquisitionState _askSubscribeFallback(VideoAcquisitionState state) =>
    _ask(
      state.copyWith(stage: VideoAcquisitionStage.collectingSlots),
      const VideoAcquisitionQuestion(
        slot: VideoAcquisitionSlot.subscribeFallback,
        options: <VideoAcquisitionOption>[
          VideoAcquisitionOption(id: kVideoAcquisitionOptionDownload),
          VideoAcquisitionOption(id: kVideoAcquisitionOptionCancel),
        ],
      ),
    );

/// 从 [from] 起第一张给得出计划的卡；一张都没有 → null。
({int index, VideoAcquisitionResourcePlan plan})? _findPlan(
  VideoAcquisitionState state,
  int from,
) {
  final VideoAcquisitionMode mode = state.slots.mode!;
  final VideoMetadataMediaKind kind = state.reference!.mediaKind;
  for (int i = from < 0 ? 0 : from; i < state.eligibleGroups.length; i++) {
    final VideoAcquisitionResourcePlan? plan = planResourceFromGroup(
      state.eligibleGroups[i],
      mode: mode,
      kind: kind,
      episodes: state.slots.episodes,
    );
    if (plan != null) return (index: i, plan: plan);
  }
  return null;
}

/// 展示从 [from] 起第一张可落地的卡：摘要 + 「就这个 / 换一个 / 取消」。
VideoAcquisitionReduction _present(VideoAcquisitionState state, int from) {
  final ({int index, VideoAcquisitionResourcePlan plan})? found = _findPlan(
    state,
    from,
  );
  if (found == null) {
    if (state.slots.mode == VideoAcquisitionMode.subscribe) {
      return (_askSubscribeFallback(state), _noEffects);
    }
    return (
      _failToIdle(state, kVideoAcquisitionFailureNoPlannableVersion),
      _noEffects,
    );
  }
  return (_presentPlan(state, found.index, found.plan), _noEffects);
}

VideoAcquisitionState _presentPlan(
  VideoAcquisitionState state,
  int index,
  VideoAcquisitionResourcePlan plan,
) {
  final VideoAcquisitionState next = state
      .copyWith(
        stage: VideoAcquisitionStage.awaitingResourceConfirm,
        groupCursor: index,
        plan: plan,
        busy: false,
      )
      .say(
        VideoAcquisitionSay(
          VideoAcquisitionSayKind.summary,
          args: <String, Object?>{
            'title': state.reference?.title,
            'mode': state.slots.mode?.name,
            ...videoAcquisitionVersionArgs(plan),
            'index': index + 1,
            'total': state.eligibleGroups.length,
          },
        ),
      );
  final bool episodic =
      state.slots.mode == VideoAcquisitionMode.download &&
      state.reference?.mediaKind == VideoMetadataMediaKind.tv;
  final bool canPickLatest =
      episodic &&
      state.slots.episodes is VideoAcquisitionAllEpisodes &&
      plan.group.episodes.length > 1;
  // 点过「只下最新一集」后给回头路：否则只能打字改回全部。
  final bool canPickAll =
      episodic && state.slots.episodes is VideoAcquisitionSingleEpisode;
  return _ask(
    next,
    VideoAcquisitionQuestion(
      slot: VideoAcquisitionSlot.resource,
      options: <VideoAcquisitionOption>[
        const VideoAcquisitionOption(id: kVideoAcquisitionOptionConfirm),
        // 直接点其它版本：不用一张张「换一个」翻过去。带上与当前卡同一份事实，
        // 否则 chip 上只有组 / 分辨率，几个版本比不出差别（BUG-2958）。
        for (final (int alt, VideoAcquisitionResourcePlan altPlan)
            in _alternativePlans(state, index))
          VideoAcquisitionOption(
            id: '$kVideoAcquisitionOptionAltPrefix$alt',
            args: videoAcquisitionVersionArgs(altPlan),
          ),
        if (canPickLatest)
          const VideoAcquisitionOption(id: kVideoAcquisitionOptionLatest),
        if (canPickAll)
          const VideoAcquisitionOption(id: kVideoAcquisitionOptionAll),
        const VideoAcquisitionOption(id: kVideoAcquisitionOptionNext),
        const VideoAcquisitionOption(id: kVideoAcquisitionOptionCancel),
      ],
    ),
  );
}

/// 「换一个」：下一张能落地的卡；没有了就说一声、停在当前这张。
VideoAcquisitionReduction _nextGroup(VideoAcquisitionState state) {
  final ({int index, VideoAcquisitionResourcePlan plan})? found = _findPlan(
    state,
    state.groupCursor + 1,
  );
  if (found == null) {
    return (
      _sayThenReask(
        state,
        const VideoAcquisitionSay(VideoAcquisitionSayKind.noMoreVersions),
      ),
      _noEffects,
    );
  }
  return (_presentPlan(state, found.index, found.plan), _noEffects);
}

// ---------------------------------------------------------------------------
// 提交 / 结束
// ---------------------------------------------------------------------------

VideoAcquisitionReduction _submit(
  VideoAcquisitionState state,
  VideoAcquisitionDefaults defaults,
) {
  final VideoAcquisitionResourcePlan? plan = state.plan;
  final VideoDiscoveryItem? item = state.chosenItem;
  final VideoAcquisitionMode? mode = state.slots.mode;
  final int? targetSourceId = state.slots.targetSourceId;
  if (plan == null || item == null || mode == null || targetSourceId == null) {
    return _advance(state, defaults);
  }
  final String? subtitleLanguage = state.slots.subtitleLanguage;
  String? code;
  if (subtitleLanguage == null) {
    return _advance(state, defaults);
  } else if (subtitleLanguage == kVideoAcquisitionSubtitleNone) {
    code = null;
  } else if (subtitleLanguage == kVideoAcquisitionSubtitleOriginal) {
    code = state.contentLanguage?.code;
    // 前面的决策表已追问过；这里为空只可能是状态被绕过，重新走一遍决策表。
    if (code == null) return _advance(state, defaults);
  } else {
    code = subtitleLanguage;
  }
  final bool installSubtitles = code != null;
  VideoAcquisitionState next = state;
  final List<VideoAcquisitionEffect> effects = <VideoAcquisitionEffect>[];
  if (code != null) {
    effects.add(
      VideoAcquisitionSetSeriesSubtitleLanguageEffect(
        reference: item.reference,
        languageCode: code,
      ),
    );
    next = next.say(
      VideoAcquisitionSay(
        VideoAcquisitionSayKind.subtitleLanguageRemembered,
        args: <String, Object?>{'language': code},
      ),
    );
  }
  effects.add(switch (mode) {
    VideoAcquisitionMode.download => VideoAcquisitionSubmitDownloadEffect(
      item: item,
      plan: plan,
      targetSourceId: targetSourceId,
      installSubtitles: installSubtitles,
    ),
    VideoAcquisitionMode.subscribe => VideoAcquisitionSubmitSubscriptionEffect(
      item: item,
      plan: plan,
      targetSourceId: targetSourceId,
      installSubtitles: installSubtitles,
    ),
  });
  next = next.copyWith(
    stage: VideoAcquisitionStage.submitting,
    clearQuestion: true,
    busy: true,
  );
  return (next, effects);
}

VideoAcquisitionReduction _onSubmitted(
  VideoAcquisitionState state,
  VideoAcquisitionSubmittedEvent event,
) {
  if (state.stage != VideoAcquisitionStage.submitting) {
    return (state, _noEffects);
  }
  final VideoAcquisitionState next = state
      .copyWith(stage: VideoAcquisitionStage.done, busy: false)
      .say(
        VideoAcquisitionSay(
          VideoAcquisitionSayKind.submitted,
          args: <String, Object?>{
            'mode': state.slots.mode?.name,
            'count': event.count,
          },
        ),
      );
  return (next, const <VideoAcquisitionEffect>[VideoAcquisitionCloseEffect()]);
}

/// 失败：说明原因；有问题挂起就重出让用户再试，提交失败回到版本确认，
/// 其它（搜作品 / 拉详情 / 搜资源）回到等文本。
VideoAcquisitionReduction _onFailed(
  VideoAcquisitionState state,
  VideoAcquisitionFailedEvent event,
) {
  final VideoAcquisitionQuestion? question = state.question;
  final VideoAcquisitionSay say = VideoAcquisitionSay(
    VideoAcquisitionSayKind.failed,
    args: <String, Object?>{'message': event.message},
  );
  final VideoAcquisitionState said = state.copyWith(busy: false).say(say);
  if (question != null) return (_ask(said, question), _noEffects);
  if (state.stage == VideoAcquisitionStage.submitting &&
      state.franchiseEntries.isNotEmpty) {
    return (_askFranchiseConfirm(said), _noEffects);
  }
  if (state.stage == VideoAcquisitionStage.submitting && state.plan != null) {
    return (_presentPlan(said, state.groupCursor, state.plan!), _noEffects);
  }
  return (_resetToIdle(said), _noEffects);
}

VideoAcquisitionReduction _cancel(VideoAcquisitionState state) {
  // 提交在飞时取消不了：入队 / 建订阅已经在做，这时说「已取消」而结果随后照样
  // 落地（且 Submitted 事件会因终态被丢），界面就与事实相反。提交完成后自然结束。
  if (state.stage == VideoAcquisitionStage.submitting) {
    return (state, _noEffects);
  }
  final VideoAcquisitionState next = state
      .copyWith(stage: VideoAcquisitionStage.cancelled, busy: false)
      .say(const VideoAcquisitionSay(VideoAcquisitionSayKind.cancelled));
  return (next, const <VideoAcquisitionEffect>[VideoAcquisitionCloseEffect()]);
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

VideoAcquisitionState _ask(
  VideoAcquisitionState state,
  VideoAcquisitionQuestion question,
) => state.say(
  VideoAcquisitionSay(VideoAcquisitionSayKind.question, args: question.args),
  question: question,
);

/// 重出当前挂起的问题（没有就原样返回）。
VideoAcquisitionState _reask(VideoAcquisitionState state) {
  final VideoAcquisitionQuestion? question = state.question;
  return question == null ? state : _ask(state, question);
}

/// 先说一句，再把之前挂起的问题重出（`say` 会清掉 question，所以要先记下来）。
VideoAcquisitionState _sayThenReask(
  VideoAcquisitionState state,
  VideoAcquisitionSay say,
) {
  final VideoAcquisitionQuestion? question = state.question;
  final VideoAcquisitionState said = state.say(say);
  return question == null ? said : _ask(said, question);
}

/// 说 `failed(message)` 并回到等文本（保留对话记录与通用偏好槽位）。
VideoAcquisitionState _failToIdle(
  VideoAcquisitionState state,
  String message,
) => _resetToIdle(
  state.say(
    VideoAcquisitionSay(
      VideoAcquisitionSayKind.failed,
      args: <String, Object?>{'message': message},
    ),
  ),
);

/// 回到等文本：丢掉作品 / 资源相关的一切，保留对话记录与用户已说过的通用偏好。
VideoAcquisitionState _resetToIdle(VideoAcquisitionState state) {
  final VideoAcquisitionSlots slots = state.slots;
  return VideoAcquisitionState(
    transcript: state.transcript,
    slots: VideoAcquisitionSlots(
      category: slots.category,
      quality: slots.quality,
      qualityRemember: slots.qualityRemember,
      subtitleLanguage: slots.subtitleLanguage,
      subtitleLanguageRemember: slots.subtitleLanguageRemember,
      targetSourceId: slots.targetSourceId,
    ),
  );
}

/// 「再下一部」：回到等文本，保留对话记录与通用偏好槽位，再说一次开场白。
VideoAcquisitionState _restart(
  VideoAcquisitionState state, {
  bool greet = true,
}) {
  final VideoAcquisitionState reset = _resetToIdle(state);
  return greet
      ? reset.say(const VideoAcquisitionSay(VideoAcquisitionSayKind.greeting))
      : reset;
}

// ---------------------------------------------------------------------------
// 作品操作条 / 范围切换
// ---------------------------------------------------------------------------

/// 选定作品后常驻的非阻塞操作（option id 列表）；空 = 不渲染。
///
/// 此前「换一部」挂在 aiPicked 那句话上，而页面只渲染当前挂起问题的选项——它
/// 实际从来没出现过。操作条改成由状态推导，页面照这张表渲染。
List<String> videoAcquisitionWorkActions(VideoAcquisitionState state) {
  if (state.chosenItem == null || state.busy) return const <String>[];
  switch (state.stage) {
    case VideoAcquisitionStage.collectingSlots:
    case VideoAcquisitionStage.awaitingResourceConfirm:
    case VideoAcquisitionStage.awaitingFranchiseConfirm:
      break;
    case VideoAcquisitionStage.idle:
    case VideoAcquisitionStage.resolvingWork:
    case VideoAcquisitionStage.awaitingWorkChoice:
    case VideoAcquisitionStage.loadingDetails:
    case VideoAcquisitionStage.resolvingResources:
    case VideoAcquisitionStage.resolvingFranchise:
    case VideoAcquisitionStage.planningFranchise:
    case VideoAcquisitionStage.submitting:
    case VideoAcquisitionStage.done:
    case VideoAcquisitionStage.cancelled:
      return const <String>[];
  }
  final VideoAcquisitionScope current = state.slots.scope;
  return <String>[
    kVideoAcquisitionOptionNone,
    for (final VideoAcquisitionScope scope in VideoAcquisitionScope.values)
      if (scope != current)
        '$kVideoAcquisitionOptionScopePrefix${scope.storageKey}',
  ];
}

/// 换范围：丢掉已搜到的资源 / 清单，按新范围从决策表重新走（已定的画质 / 字幕 /
/// 来源保留，不重问）。
VideoAcquisitionReduction _changeScope(
  VideoAcquisitionState state,
  VideoAcquisitionScope scope,
  VideoAcquisitionDefaults defaults,
) {
  final VideoAcquisitionState next = VideoAcquisitionState(
    stage: VideoAcquisitionStage.collectingSlots,
    slots: state.slots.copyWith(scope: scope),
    transcript: state.transcript,
    chosenItem: state.chosenItem,
    work: state.work,
    airing: state.airing,
    contentLanguage: state.contentLanguage,
    presence: state.presence,
    alreadySubscribed: state.alreadySubscribed,
    presenceAcknowledged: state.presenceAcknowledged,
    subtitleLanguageAsked: state.subtitleLanguageAsked,
    subtitleLanguageResolutionSaid: state.subtitleLanguageResolutionSaid,
    aiDecision: state.aiDecision,
  );
  if (state.chosenItem == null) return (next, _noEffects);
  return _advance(next, defaults);
}

// ---------------------------------------------------------------------------
// 版本卡：直接点选 / 只下最新一集
// ---------------------------------------------------------------------------

/// 当前卡之外、给得出计划的前几张卡（按 eligibleGroups 次序）。
const int kVideoAcquisitionMaxAlternatives = 3;

List<(int, VideoAcquisitionResourcePlan)> _alternativePlans(
  VideoAcquisitionState state,
  int current,
) {
  final List<(int, VideoAcquisitionResourcePlan)> result =
      <(int, VideoAcquisitionResourcePlan)>[];
  for (int i = 0; i < state.eligibleGroups.length; i++) {
    if (i == current) continue;
    if (result.length >= kVideoAcquisitionMaxAlternatives) break;
    if (_planAt(state, i) case final VideoAcquisitionResourcePlan plan) {
      result.add((i, plan));
    }
  }
  return result;
}

VideoAcquisitionResourcePlan? _planAt(VideoAcquisitionState state, int index) {
  final VideoMediaReference? reference = state.reference;
  final VideoAcquisitionMode? mode = state.slots.mode;
  if (reference == null || mode == null) return null;
  if (index < 0 || index >= state.eligibleGroups.length) return null;
  return planResourceFromGroup(
    state.eligibleGroups[index],
    mode: mode,
    kind: reference.mediaKind,
    episodes: state.slots.episodes,
  );
}

/// 点了某张候选版本：直接就用它（点具体版本本身就是决定，不再多问一句）。
VideoAcquisitionReduction _chooseAlternative(
  VideoAcquisitionState state,
  String optionId,
  VideoAcquisitionDefaults defaults,
) {
  final int? index = int.tryParse(
    optionId.substring(kVideoAcquisitionOptionAltPrefix.length),
  );
  final VideoAcquisitionResourcePlan? plan = index == null
      ? null
      : _planAt(state, index);
  if (index == null || plan == null) return (state, _noEffects);
  return _submit(state.copyWith(groupCursor: index, plan: plan), defaults);
}

/// 「只下最新一集」：把集选择收成当前卡里最大的集号，重算当前卡的计划。
VideoAcquisitionReduction _onlyLatestEpisode(VideoAcquisitionState state) {
  final VideoAcquisitionResourcePlan? current = state.plan;
  if (current == null || current.group.episodes.isEmpty) {
    return (state, _noEffects);
  }
  final int latest = current.group.episodes.reduce(
    (int a, int b) => a > b ? a : b,
  );
  final VideoAcquisitionState narrowed = state.copyWith(
    slots: state.slots.copyWith(
      episodes: VideoAcquisitionSingleEpisode(latest),
    ),
  );
  final VideoAcquisitionResourcePlan? plan = _planAt(
    narrowed,
    state.groupCursor,
  );
  if (plan == null) return (state, _noEffects);
  return (_presentPlan(narrowed, state.groupCursor, plan), _noEffects);
}

/// 撤销「只下最新一集」：集选择回到全部，重算当前卡。
VideoAcquisitionReduction _allEpisodesAgain(VideoAcquisitionState state) {
  final VideoAcquisitionState widened = state.copyWith(
    slots: state.slots.copyWith(episodes: const VideoAcquisitionAllEpisodes()),
  );
  final VideoAcquisitionResourcePlan? plan = _planAt(
    widened,
    state.groupCursor,
  );
  if (plan == null) return (state, _noEffects);
  return (_presentPlan(widened, state.groupCursor, plan), _noEffects);
}

// ---------------------------------------------------------------------------
// 整套下载
// ---------------------------------------------------------------------------

/// `failed` 的 message 固定键：整套清单里一部都没勾 / 一部都没有资源。
const String kVideoAcquisitionFailureNothingSelected = 'nothing_selected';

VideoAcquisitionReduction _startFranchise(VideoAcquisitionState state) {
  final VideoDiscoveryItem item = state.chosenItem!;
  final VideoAcquisitionState next = state
      .say(
        VideoAcquisitionSay(
          VideoAcquisitionSayKind.franchiseSearching,
          args: <String, Object?>{'title': item.reference.title},
        ),
      )
      .copyWith(
        stage: VideoAcquisitionStage.resolvingFranchise,
        clearQuestion: true,
        clearFranchiseDraft: true,
        busy: true,
      );
  return (
    next,
    <VideoAcquisitionEffect>[VideoAcquisitionLoadFranchiseEffect(item)],
  );
}

/// 系列里属于用户要的范围（整套 / 只要剧场版 / 只要剧集）的那些作品。
List<VideoDiscoveryItem> _franchiseMembers(
  VideoFranchise? franchise,
  VideoAcquisitionScope scope,
) => franchise == null
    ? const <VideoDiscoveryItem>[]
    : <VideoDiscoveryItem>[
        if (scope != VideoAcquisitionScope.franchiseMovies) ...franchise.series,
        if (scope != VideoAcquisitionScope.franchiseSeries) ...franchise.movies,
      ];

int _countKind(List<VideoDiscoveryItem> items, VideoMetadataMediaKind kind) =>
    items
        .where((VideoDiscoveryItem item) => item.reference.mediaKind == kind)
        .length;

VideoAcquisitionReduction _onFranchiseLoaded(
  VideoAcquisitionState state,
  VideoAcquisitionFranchiseLoadedEvent event,
  VideoAcquisitionDefaults defaults,
) {
  if (state.stage != VideoAcquisitionStage.resolvingFranchise) {
    return (state, _noEffects);
  }
  final VideoDiscoveryItem anchor = state.chosenItem!;
  final VideoAcquisitionScope scope = state.slots.scope;
  // 分批：每一批交的是「到目前为止」的全部，与已收到的（含 TMDB / 联网补全）合并
  // 去重；草稿不带续查入口，合并结果的 `more` 就是这一批的。
  final VideoFranchise? franchise = mergeVideoFranchises(<VideoFranchise?>[
    state.franchiseDraft,
    event.franchise,
  ]);
  final Future<VideoFranchise> Function()? more = franchise?.more;
  if (franchise != null && more != null) {
    // 还没查完：报一次进度、接着查下一批，不在半张清单上开始逐部找资源。
    final List<VideoDiscoveryItem> soFar = _franchiseMembers(franchise, scope);
    return (
      state
          .say(
            VideoAcquisitionSay(
              VideoAcquisitionSayKind.franchiseProgress,
              args: <String, Object?>{
                'name': franchise.name,
                'series': _countKind(soFar, VideoMetadataMediaKind.tv),
                'movies': _countKind(soFar, VideoMetadataMediaKind.movie),
              },
            ),
          )
          .copyWith(franchiseDraft: franchise.withoutMore()),
      <VideoAcquisitionEffect>[VideoAcquisitionContinueFranchiseEffect(more)],
    );
  }
  final VideoAcquisitionState settled = state.copyWith(
    clearFranchiseDraft: true,
  );
  final List<VideoDiscoveryItem> members = _franchiseMembers(franchise, scope);
  final bool onlyAnchor =
      members.length == 1 &&
      _sameWork(members.single.reference, anchor.reference);
  if (members.isEmpty || onlyAnchor) {
    return _franchiseHasNothingMore(settled, franchise, defaults);
  }
  final List<VideoAcquisitionFranchiseEntry> entries =
      <VideoAcquisitionFranchiseEntry>[
        for (final VideoDiscoveryItem item in members)
          VideoAcquisitionFranchiseEntry(item: item),
      ];
  final VideoAcquisitionState found = settled.say(
    VideoAcquisitionSay(
      VideoAcquisitionSayKind.franchiseFound,
      args: <String, Object?>{
        'name': franchise!.name,
        'series': _countKind(members, VideoMetadataMediaKind.tv),
        'movies': _countKind(members, VideoMetadataMediaKind.movie),
      },
    ),
  );
  // 解析因失败停在半路：照常往下走（已收到的照样要下），但不能让用户把它当成
  // 「全部」（BUG-2935）。
  final VideoAcquisitionState next =
      (franchise.truncated
              ? found.say(
                  VideoAcquisitionSay(
                    VideoAcquisitionSayKind.franchiseTruncated,
                    args: <String, Object?>{'name': franchise.name},
                  ),
                )
              : found)
          .copyWith(
            stage: VideoAcquisitionStage.planningFranchise,
            franchiseName: franchise.name,
            franchiseEntries: entries,
            busy: true,
          );
  return (
    next,
    <VideoAcquisitionEffect>[
      VideoAcquisitionResolveFranchiseEntryEffect(
        index: 0,
        item: entries.first.item,
      ),
    ],
  );
}

/// 系列里没有锚点以外的、用户要的那部分。
///
/// 只有清单**走完了**且锚点本身就属于用户要的范围（整套 / 要剧场版而锚点是剧场版 /
/// 要剧集而锚点是剧集）时，「只下这一部」才就是用户要的东西，说一声直接按单部
/// 继续。否则——「全部哆啦A梦剧场版」却只剩锚点那部 TV（1979 版 1700+ 集），
/// 或资料源出错 / 不可用、根本不知道有没有——静默降级就是替用户下了别的东西，
/// 必须先问（BUG-2936）。
VideoAcquisitionReduction _franchiseHasNothingMore(
  VideoAcquisitionState state,
  VideoFranchise? franchise,
  VideoAcquisitionDefaults defaults,
) {
  final VideoMediaReference anchor = state.chosenItem!.reference;
  final bool known = franchise != null && !franchise.truncated;
  if (known && _anchorFitsScope(anchor, state.slots.scope)) {
    final VideoAcquisitionState single = state
        .copyWith(
          busy: false,
          slots: state.slots.copyWith(scope: VideoAcquisitionScope.work),
        )
        .say(
          VideoAcquisitionSay(
            VideoAcquisitionSayKind.franchiseNotFound,
            args: <String, Object?>{'title': anchor.title},
          ),
        );
    return _advance(single, defaults);
  }
  VideoAcquisitionState next = state.copyWith(busy: false);
  if (!known) {
    next = next.say(
      VideoAcquisitionSay(
        VideoAcquisitionSayKind.franchiseUnavailable,
        args: <String, Object?>{'title': anchor.title},
      ),
    );
  }
  return (
    _ask(
      next,
      VideoAcquisitionQuestion(
        slot: VideoAcquisitionSlot.franchiseFallback,
        options: const <VideoAcquisitionOption>[
          VideoAcquisitionOption(id: kVideoAcquisitionOptionContinue),
          VideoAcquisitionOption(id: kVideoAcquisitionOptionCancel),
        ],
        args: <String, Object?>{'title': anchor.title},
      ),
    ),
    _noEffects,
  );
}

bool _anchorFitsScope(
  VideoMediaReference anchor,
  VideoAcquisitionScope scope,
) => switch (scope) {
  VideoAcquisitionScope.franchiseMovies =>
    anchor.mediaKind == VideoMetadataMediaKind.movie,
  VideoAcquisitionScope.franchiseSeries =>
    anchor.mediaKind == VideoMetadataMediaKind.tv,
  VideoAcquisitionScope.franchise || VideoAcquisitionScope.work => true,
};

bool _sameWork(VideoMediaReference a, VideoMediaReference b) =>
    (a.providerId == b.providerId && a.mediaId == b.mediaId) ||
    (a.tmdbId != null && a.tmdbId == b.tmdbId && a.mediaKind == b.mediaKind);

/// 一部搜完：定模式、定计划，然后发下一部；最后一部完了出清单。
VideoAcquisitionReduction _onFranchiseEntryResolved(
  VideoAcquisitionState state,
  VideoAcquisitionFranchiseEntryResolvedEvent event,
  VideoAcquisitionDefaults defaults,
) {
  final int index = event.index;
  if (state.stage != VideoAcquisitionStage.planningFranchise ||
      index < 0 ||
      index >= state.franchiseEntries.length) {
    return (state, _noEffects);
  }
  // 同一颗种子只归一部：没写年份的剧场版合集包能通过每一部的年份过滤，不排除
  // 就会被几部同时选中——第二部入队时撞重复种子失败，第一部又把整包当单部入库。
  final Set<String> used = <String>{
    for (final VideoAcquisitionFranchiseEntry entry in state.franchiseEntries)
      for (final VideoResourceCandidate pick
          in entry.plan?.picks ?? const <VideoResourceCandidate>[])
        pick.identityKey,
  };
  final VideoAcquisitionFranchiseEntry target = state.franchiseEntries[index];
  final VideoAcquisitionFranchiseEntry resolved = planFranchiseEntry(
    target,
    VideoAcquisitionFranchiseEntryResolvedEvent(
      index: event.index,
      work: event.work,
      presence: event.presence,
      alreadySubscribed: event.alreadySubscribed,
      items: <VideoResourceCandidate>[
        for (final VideoResourceCandidate item in event.items)
          if (!used.contains(item.identityKey)) item,
      ],
    ),
    quality: state.slots.quality ?? VideoAcquisitionQuality.best,
    defaults: defaults,
    // 同名剧集（哆啦A梦 1979 / 2005）靠标题搜到的是同一批发布：清单里有同名
    // 剧集时按年份排除写了别的年份的发布。独一份的长寿剧不排（逐集发布常带
    // 播出年份，按首播年排会误杀）。
    filterSeriesByYear: _hasSameTitledSeries(state.franchiseEntries, target),
  );
  final List<VideoAcquisitionFranchiseEntry> entries =
      List<VideoAcquisitionFranchiseEntry>.of(state.franchiseEntries);
  entries[index] = resolved;
  final VideoAcquisitionState next = state.copyWith(franchiseEntries: entries);
  final int following = index + 1;
  if (following < entries.length) {
    return (
      next,
      <VideoAcquisitionEffect>[
        VideoAcquisitionResolveFranchiseEntryEffect(
          index: following,
          item: entries[following].item,
        ),
      ],
    );
  }
  final int ready = entries
      .where(
        (VideoAcquisitionFranchiseEntry e) =>
            e.status == VideoAcquisitionFranchiseEntryStatus.ready,
      )
      .length;
  return (
    _askFranchiseConfirm(
      next
          .copyWith(busy: false)
          .say(
            VideoAcquisitionSay(
              VideoAcquisitionSayKind.franchiseReady,
              args: <String, Object?>{'ready': ready, 'total': entries.length},
            ),
          ),
    ),
    _noEffects,
  );
}

/// 一部作品的计划（纯函数，单测直接打）：
///
/// * 模式：电影 / 已完结 / 已取消 → 下载；在播 / 未开播 / 状态未知 → 订阅（订阅
///   从已知最小集号起，已出的集会一起下）。订阅推不出严格规则时退回下载。
/// * 画质：会话画质找不到时退到「最高可用」——整套里不逐部追问。
/// * 已在库 / 已订阅：照样给计划，默认不勾。
VideoAcquisitionFranchiseEntry planFranchiseEntry(
  VideoAcquisitionFranchiseEntry entry,
  VideoAcquisitionFranchiseEntryResolvedEvent event, {
  required VideoAcquisitionQuality quality,
  required VideoAcquisitionDefaults defaults,
  bool filterSeriesByYear = false,
}) {
  final VideoMediaReference reference = entry.item.reference;
  final VideoMetadataMediaKind kind = reference.mediaKind;
  final VideoAiringStatus? airing = event.work?.airingStatus;
  final VideoAcquisitionMode preferred =
      kind == VideoMetadataMediaKind.movie ||
          airing == VideoAiringStatus.finished ||
          airing == VideoAiringStatus.cancelled
      ? VideoAcquisitionMode.download
      : VideoAcquisitionMode.subscribe;
  final List<VideoResourceVersionGroup> groups =
      buildVideoResourceVersionGroups(
        cleanResourceCandidates(
          event.items,
          skipExtras: defaults.skipExtras,
          movieYear: kind == VideoMetadataMediaKind.movie || filterSeriesByYear
              ? reference.year
              : null,
        ),
      );
  ({VideoAcquisitionMode mode, VideoAcquisitionResourcePlan plan})? found;
  for (final VideoAcquisitionMode mode in <VideoAcquisitionMode>[
    preferred,
    if (preferred == VideoAcquisitionMode.subscribe)
      VideoAcquisitionMode.download,
  ]) {
    for (final VideoAcquisitionQuality wanted in <VideoAcquisitionQuality>[
      quality,
      if (quality != VideoAcquisitionQuality.best) VideoAcquisitionQuality.best,
    ]) {
      final VideoAcquisitionResourceOutcome outcome = filterResourceGroups(
        groups,
        mode: mode,
        quality: wanted,
        source: defaults.sourcePref,
        bitrate: defaults.bitratePref,
      );
      for (final VideoResourceVersionGroup group in outcome.eligible) {
        final VideoAcquisitionResourcePlan? plan = planResourceFromGroup(
          group,
          mode: mode,
          kind: kind,
          episodes: const VideoAcquisitionAllEpisodes(),
        );
        if (plan != null) {
          found = (mode: mode, plan: plan);
          break;
        }
      }
      if (found != null) break;
    }
    if (found != null) break;
  }
  final bool owned =
      event.presence?.inLibrary == true || event.alreadySubscribed;
  // 与单作品路径同一份补齐：订阅行的检索词 / 身份要带上详情的拉丁标题。
  final VideoDiscoveryItem item = entry.item.withReference(
    reference.withWorkLatinTitles(event.work),
  );
  if (found == null) {
    return entry.copyWith(
      item: item,
      status: VideoAcquisitionFranchiseEntryStatus.noResource,
      selected: false,
      owned: owned,
    );
  }
  return entry.copyWith(
    item: item,
    status: VideoAcquisitionFranchiseEntryStatus.ready,
    mode: found.mode,
    plan: found.plan,
    selected: !owned,
    owned: owned,
  );
}

bool _hasSameTitledSeries(
  List<VideoAcquisitionFranchiseEntry> entries,
  VideoAcquisitionFranchiseEntry target,
) {
  final VideoMediaReference reference = target.item.reference;
  if (reference.mediaKind != VideoMetadataMediaKind.tv) return false;
  final String title = TitleNormalizer.normalize(reference.title);
  return entries.any(
    (VideoAcquisitionFranchiseEntry other) =>
        !identical(other, target) &&
        other.item.reference.mediaKind == VideoMetadataMediaKind.tv &&
        TitleNormalizer.normalize(other.item.reference.title) == title,
  );
}

VideoAcquisitionState _askFranchiseConfirm(VideoAcquisitionState state) => _ask(
  state.copyWith(stage: VideoAcquisitionStage.awaitingFranchiseConfirm),
  const VideoAcquisitionQuestion(
    slot: VideoAcquisitionSlot.franchise,
    options: <VideoAcquisitionOption>[
      VideoAcquisitionOption(id: kVideoAcquisitionOptionSubmitAll),
      VideoAcquisitionOption(id: kVideoAcquisitionOptionCancel),
    ],
  ),
);

VideoAcquisitionState _toggleFranchiseEntry(
  VideoAcquisitionState state,
  int index,
) {
  if (state.stage != VideoAcquisitionStage.awaitingFranchiseConfirm ||
      index < 0 ||
      index >= state.franchiseEntries.length) {
    return state;
  }
  final VideoAcquisitionFranchiseEntry entry = state.franchiseEntries[index];
  if (entry.status != VideoAcquisitionFranchiseEntryStatus.ready) return state;
  final List<VideoAcquisitionFranchiseEntry> entries =
      List<VideoAcquisitionFranchiseEntry>.of(state.franchiseEntries);
  entries[index] = entry.copyWith(selected: !entry.selected);
  return state.copyWith(franchiseEntries: entries);
}

VideoAcquisitionReduction _submitFranchise(VideoAcquisitionState state) {
  final int? targetSourceId = state.slots.targetSourceId;
  final String? subtitleLanguage = state.slots.subtitleLanguage;
  final List<VideoAcquisitionFranchiseEntry> picked =
      <VideoAcquisitionFranchiseEntry>[
        for (final VideoAcquisitionFranchiseEntry entry
            in state.franchiseEntries)
          if (entry.submittable) entry,
      ];
  if (picked.isEmpty || targetSourceId == null || subtitleLanguage == null) {
    return (
      _sayThenReask(
        state,
        const VideoAcquisitionSay(
          VideoAcquisitionSayKind.failed,
          args: <String, Object?>{
            'message': kVideoAcquisitionFailureNothingSelected,
          },
        ),
      ),
      _noEffects,
    );
  }
  final String? code = switch (subtitleLanguage) {
    kVideoAcquisitionSubtitleNone => null,
    kVideoAcquisitionSubtitleOriginal => state.contentLanguage?.code,
    _ => subtitleLanguage,
  };
  return (
    state.copyWith(
      stage: VideoAcquisitionStage.submitting,
      clearQuestion: true,
      busy: true,
    ),
    <VideoAcquisitionEffect>[
      VideoAcquisitionSubmitFranchiseEffect(
        entries: picked,
        targetSourceId: targetSourceId,
        subtitleLanguageCode: code,
      ),
    ],
  );
}

VideoAcquisitionReduction _onFranchiseSubmitted(
  VideoAcquisitionState state,
  VideoAcquisitionFranchiseSubmittedEvent event,
) {
  if (state.stage != VideoAcquisitionStage.submitting) {
    return (state, _noEffects);
  }
  return (
    state
        .copyWith(stage: VideoAcquisitionStage.done, busy: false)
        .say(
          VideoAcquisitionSay(
            VideoAcquisitionSayKind.franchiseSubmitted,
            args: <String, Object?>{
              'downloads': event.downloads,
              'subscriptions': event.subscriptions,
              'failed': event.failed,
            },
          ),
        ),
    const <VideoAcquisitionEffect>[VideoAcquisitionCloseEffect()],
  );
}

VideoAcquisitionReduction _withEffects(
  VideoAcquisitionReduction reduction,
  List<VideoAcquisitionEffect> before,
) {
  final (VideoAcquisitionState state, List<VideoAcquisitionEffect> after) =
      reduction;
  if (before.isEmpty) return reduction;
  return (state, <VideoAcquisitionEffect>[...before, ...after]);
}

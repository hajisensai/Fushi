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
library;

import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_airing_status.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_resource_picker.dart';
import 'package:fushi/src/media/video/acquisition/video_work_content_language.dart';
import 'package:fushi/src/media/video/download/video_resource_version_groups.dart';

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
  if (_isTerminal(state)) return (state, _noEffects);
  return switch (event) {
    VideoAcquisitionUserTextEvent e => _onUserText(state, e),
    VideoAcquisitionChipChosenEvent e => _onChipChosen(state, e, defaults),
    VideoAcquisitionAiIntentEvent e => _onAiIntent(state, e, defaults),
    VideoAcquisitionAiUnavailableEvent e => _onAiUnavailable(state, e),
    VideoAcquisitionWorksLoadedEvent e => _onWorksLoaded(state, e, defaults),
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
    VideoAcquisitionResourcesLoadedEvent e => _onResourcesLoaded(state, e),
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
      return _unclear(idle);
    case VideoAcquisitionIntentKind.choose:
      return _onAiChoose(idle, intent.patch, defaults);
    case VideoAcquisitionIntentKind.provide:
      return _onAiProvide(idle, intent.patch, defaults);
    case VideoAcquisitionIntentKind.unclear:
      return _unclear(idle);
  }
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
      if (refilter) return _refilter(state);
      return (_reask(state), _noEffects);
    case VideoAcquisitionStage.idle:
    case VideoAcquisitionStage.resolvingWork:
    case VideoAcquisitionStage.awaitingWorkChoice:
    case VideoAcquisitionStage.loadingDetails:
    case VideoAcquisitionStage.resolvingResources:
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

VideoAcquisitionReduction _startWorkSearch(
  VideoAcquisitionState state,
  List<String> rawQueries,
) {
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
    final VideoAcquisitionState notFound = state
        .copyWith(stage: VideoAcquisitionStage.idle, busy: false)
        .say(
          VideoAcquisitionSay(
            VideoAcquisitionSayKind.workNotFound,
            args: <String, Object?>{'query': event.query},
          ),
        );
    return (notFound, _noEffects);
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
  return AiVideoIdentityQuery(
    localTitles: <String>[
      if (userText != null) userText,
      ...state.slots.workQueries,
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

String? _candidateHintOf(VideoDiscoveryItem item) {
  final List<String> parts = <String>[
    if (item.reference.year != null) '${item.reference.year}',
    item.reference.discoveryCategory.name,
  ];
  return parts.join(' · ');
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
  final List<_SlotStep Function(VideoAcquisitionState)> rows =
      <_SlotStep Function(VideoAcquisitionState)>[
        _decidePresence,
        _decideMode,
        _decideSeason,
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
  return _searchResources(s);
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
  // 「换一部」挂在 aiPicked 那句上，不是阻塞问题：提交前任何时候都可点。
  if (event.slot == VideoAcquisitionSlot.work &&
      event.optionId == kVideoAcquisitionOptionNone &&
      state.stage != VideoAcquisitionStage.submitting) {
    return _restartWork(state);
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
      return switch (optionId) {
        kVideoAcquisitionOptionConfirm => _submit(state, defaults),
        kVideoAcquisitionOptionNext => _nextGroup(state),
        kVideoAcquisitionOptionCancel => _cancel(state),
        _ => (state, _noEffects),
      };
    case VideoAcquisitionSlot.resolutionFallback:
      if (optionId == kVideoAcquisitionOptionCancel) return _cancel(state);
      return _refilter(
        state.copyWith(
          slots: state.slots.copyWith(quality: _qualityForResolution(optionId)),
        ),
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
) {
  if (state.stage != VideoAcquisitionStage.resolvingResources) {
    return (state, _noEffects);
  }
  final VideoAcquisitionState next = state.copyWith(
    groups: buildVideoResourceVersionGroups(event.items),
    busy: false,
  );
  return _refilter(next);
}

/// 用当前 mode / quality 重过滤 `groups`，并展示第一张给得出计划的卡。
VideoAcquisitionReduction _refilter(VideoAcquisitionState state) {
  final VideoAcquisitionMode mode = state.slots.mode!;
  final VideoAcquisitionQuality quality = state.slots.quality!;
  final VideoAcquisitionResourceOutcome outcome = filterResourceGroups(
    state.groups,
    mode: mode,
    quality: quality,
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
  final VideoResourceVersionGroup group = plan.group;
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
            'releaseGroup': group.releaseGroup,
            'resolution': group.resolution,
            'provider': group.providerId,
            'count': plan.picks.length,
            'batch': plan.usesBatch,
            'seeders': group.bestSeeders,
            'missing': plan.missingEpisodes,
            'startAfterEpisode': plan.startAfterEpisode,
            'index': index + 1,
            'total': state.eligibleGroups.length,
          },
        ),
      );
  return _ask(
    next,
    const VideoAcquisitionQuestion(
      slot: VideoAcquisitionSlot.resource,
      options: <VideoAcquisitionOption>[
        VideoAcquisitionOption(id: kVideoAcquisitionOptionConfirm),
        VideoAcquisitionOption(id: kVideoAcquisitionOptionNext),
        VideoAcquisitionOption(id: kVideoAcquisitionOptionCancel),
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
  if (state.stage == VideoAcquisitionStage.submitting && state.plan != null) {
    return (_presentPlan(said, state.groupCursor, state.plan!), _noEffects);
  }
  return (_resetToIdle(said), _noEffects);
}

VideoAcquisitionReduction _cancel(VideoAcquisitionState state) {
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

VideoAcquisitionReduction _withEffects(
  VideoAcquisitionReduction reduction,
  List<VideoAcquisitionEffect> before,
) {
  final (VideoAcquisitionState state, List<VideoAcquisitionEffect> after) =
      reduction;
  if (before.isEmpty) return reduction;
  return (state, <VideoAcquisitionEffect>[...before, ...after]);
}

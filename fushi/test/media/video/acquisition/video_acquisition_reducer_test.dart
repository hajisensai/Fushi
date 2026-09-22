// 「AI 下视频」纯函数状态机：槽位决策表 / 作品消解 / 资源阶段 / 提交 / 取消。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_library_presence.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_reducer.dart';

class _FakeResource extends VideoResourceCandidate {
  _FakeResource({
    required super.remoteId,
    required super.title,
    super.providerId = 'nyaa',
    super.providerInstanceId = 'nyaa',
    super.providerPriority = 100,
    super.releaseGroup,
    super.resolution,
    super.seeders,
  }) : super(trusted: true);
}

/// 把 reducer 串成会话：每次 feed 一个事件，累积状态、返回这一步的效果。
class _Session {
  _Session(this.defaults);

  final VideoAcquisitionDefaults defaults;
  VideoAcquisitionState state = const VideoAcquisitionState();

  List<VideoAcquisitionEffect> feed(VideoAcquisitionEvent event) {
    final (VideoAcquisitionState next, List<VideoAcquisitionEffect> effects) =
        reduceVideoAcquisition(state, event, defaults);
    state = next;
    return effects;
  }

  List<VideoAcquisitionSayKind> get said => <VideoAcquisitionSayKind>[
    for (final VideoAcquisitionMessage message in state.transcript)
      if (message is VideoAcquisitionAssistantMessage) message.say.kind,
  ];

  VideoAcquisitionAssistantMessage get lastAssistant =>
      state.transcript.whereType<VideoAcquisitionAssistantMessage>().last;

  List<String> get optionIds => <String>[
    for (final VideoAcquisitionOption option in state.question!.options)
      option.id,
  ];
}

VideoDiscoveryItem _item({
  String id = '1',
  String title = 'Show',
  VideoMetadataMediaKind kind = VideoMetadataMediaKind.tv,
  VideoDiscoveryCategory category = VideoDiscoveryCategory.anime,
  String? status = 'Currently Airing',
  int? seasonCount,
  String? originalLanguage,
  int? year,
}) => VideoDiscoveryItem(
  reference: VideoMediaReference(
    providerId: 'mal',
    mediaId: id,
    mediaKind: kind,
    discoveryCategory: category,
    title: title,
    year: year,
  ),
  metadataWork: VideoMetadataWork(
    provider: VideoMetadataProviderKind.mal,
    kind: kind,
    title: title,
    status: status,
    seasonCount: seasonCount,
    originalLanguage: originalLanguage,
    episodeCount: 12,
  ),
);

const VideoAcquisitionDefaults _oneSource = VideoAcquisitionDefaults(
  qualityPref: '1080p',
  subtitleLanguagePref: 'ja',
  sources: <VideoAcquisitionSource>[
    VideoAcquisitionSource(id: 7, label: 'Anime'),
  ],
);

VideoAcquisitionDefaults _defaults({
  String qualityPref = '1080p',
  String subtitleLanguagePref = 'ja',
  List<VideoAcquisitionSource> sources = const <VideoAcquisitionSource>[
    VideoAcquisitionSource(id: 7, label: 'Anime'),
  ],
  int? defaultSourceId,
}) => VideoAcquisitionDefaults(
  qualityPref: qualityPref,
  subtitleLanguagePref: subtitleLanguagePref,
  sources: sources,
  defaultSourceId: defaultSourceId,
);

VideoAcquisitionAiIntentEvent _provide(
  VideoAcquisitionIntentPatch patch, {
  String utterance = 'Show',
}) => VideoAcquisitionAiIntentEvent(
  VideoAcquisitionIntent(VideoAcquisitionIntentKind.provide, patch),
  utterance: utterance,
);

/// 走到「作品选定、详情已到」这一步；返回 DetailsLoaded 那一步的效果。
List<VideoAcquisitionEffect> _reachDetails(
  _Session session,
  VideoDiscoveryItem item, {
  VideoLibraryPresence? presence,
  bool alreadySubscribed = false,
}) {
  session.feed(const VideoAcquisitionUserTextEvent('Show'));
  session.feed(
    _provide(const VideoAcquisitionIntentPatch(workQueries: <String>['Show'])),
  );
  final List<VideoAcquisitionEffect> load = session.feed(
    VideoAcquisitionWorksLoadedEvent(
      query: 'Show',
      items: <VideoDiscoveryItem>[item],
    ),
  );
  expect(load.single, isA<VideoAcquisitionLoadDetailsEffect>());
  return session.feed(
    VideoAcquisitionDetailsLoadedEvent(
      work: item.metadataWork,
      presence: presence,
      alreadySubscribed: alreadySubscribed,
    ),
  );
}

/// 一直走到资源搜索效果发出（所有槽位由偏好填满）。
VideoAcquisitionSearchResourcesEffect _reachResources(
  _Session session,
  VideoDiscoveryItem item,
) {
  final List<VideoAcquisitionEffect> effects = _reachDetails(session, item);
  expect(session.state.stage, VideoAcquisitionStage.resolvingResources);
  return effects.single as VideoAcquisitionSearchResourcesEffect;
}

List<VideoResourceCandidate> _episodeResources({
  String resolution = '1080p',
  String group = 'Grp',
}) => <VideoResourceCandidate>[
  _FakeResource(
    remoteId: 'a1',
    title: '[$group] Show - 01 ($resolution)',
    releaseGroup: group,
    resolution: resolution,
    seeders: 50,
  ),
  _FakeResource(
    remoteId: 'a2',
    title: '[$group] Show - 02 ($resolution)',
    releaseGroup: group,
    resolution: resolution,
    seeders: 40,
  ),
];

void main() {
  group('画质槽位三态', () {
    test("偏好 '' → 问且勾选框默认勾上", () {
      final _Session s = _Session(_defaults(qualityPref: ''));
      _reachDetails(s, _item(status: 'Finished Airing'));
      final VideoAcquisitionQuestion q = s.state.question!;
      expect(q.slot, VideoAcquisitionSlot.quality);
      expect(q.rememberToggle, isTrue);
      expect(q.rememberDefault, isTrue);
      expect(s.optionIds, <String>['2160p', '1080p', '720p', '480p', 'any']);
    });

    test("偏好 'ask' → 问且勾选框默认不勾", () {
      final _Session s = _Session(_defaults(qualityPref: 'ask'));
      _reachDetails(s, _item(status: 'Finished Airing'));
      final VideoAcquisitionQuestion q = s.state.question!;
      expect(q.slot, VideoAcquisitionSlot.quality);
      expect(q.rememberToggle, isTrue);
      expect(q.rememberDefault, isFalse);
    });

    test('固定档 → 不问直接填', () {
      final _Session s = _Session(_defaults(qualityPref: '1080p'));
      _reachDetails(s, _item(status: 'Finished Airing'));
      expect(s.state.slots.quality, VideoAcquisitionQuality.p1080);
      expect(s.state.question?.slot, isNot(VideoAcquisitionSlot.quality));
    });

    test('chip 选画质且 remember → 写偏好并继续', () {
      final _Session s = _Session(_defaults(qualityPref: ''));
      _reachDetails(s, _item(status: 'Finished Airing'));
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.quality,
          optionId: '720p',
          remember: true,
        ),
      );
      final VideoAcquisitionPersistPreferenceEffect persist = effects
          .whereType<VideoAcquisitionPersistPreferenceEffect>()
          .single;
      expect(persist.preference, VideoAcquisitionPreference.quality);
      expect(persist.value, '720p');
      expect(s.state.slots.quality, VideoAcquisitionQuality.p720);
      expect(s.state.stage, VideoAcquisitionStage.resolvingResources);
    });
  });

  group('字幕语言槽位', () {
    test("偏好 '' → 问一次，预选 original，勾选默认 true", () {
      final _Session s = _Session(_defaults(subtitleLanguagePref: ''));
      _reachDetails(
        s,
        _item(status: 'Finished Airing', originalLanguage: 'ja'),
      );
      final VideoAcquisitionQuestion q = s.state.question!;
      expect(q.slot, VideoAcquisitionSlot.subtitleLanguage);
      expect(q.preselectedIndex, 0);
      expect(q.options.first.id, kVideoAcquisitionSubtitleOriginal);
      expect(q.options.last.id, kVideoAcquisitionSubtitleNone);
      expect(q.rememberToggle, isTrue);
      expect(q.rememberDefault, isTrue);
      expect(s.optionIds, <String>['original', 'ja', 'zh', 'en', 'ko', 'none']);
    });

    test("偏好 'ask' → 问且勾选默认 false", () {
      final _Session s = _Session(_defaults(subtitleLanguagePref: 'ask'));
      _reachDetails(
        s,
        _item(status: 'Finished Airing', originalLanguage: 'ja'),
      );
      final VideoAcquisitionQuestion q = s.state.question!;
      expect(q.slot, VideoAcquisitionSlot.subtitleLanguage);
      expect(q.rememberDefault, isFalse);
    });

    test('chip 选 ja 且 remember=true → 写偏好', () {
      final _Session s = _Session(_defaults(subtitleLanguagePref: ''));
      _reachDetails(
        s,
        _item(status: 'Finished Airing', originalLanguage: 'ja'),
      );
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.subtitleLanguage,
          optionId: 'ja',
          remember: true,
        ),
      );
      final VideoAcquisitionPersistPreferenceEffect persist = effects
          .whereType<VideoAcquisitionPersistPreferenceEffect>()
          .single;
      expect(persist.preference, VideoAcquisitionPreference.subtitleLanguage);
      expect(persist.value, 'ja');
      expect(s.state.slots.subtitleLanguage, 'ja');
    });

    test('chip 选 ja 且 remember=false → 不写偏好', () {
      final _Session s = _Session(_defaults(subtitleLanguagePref: ''));
      _reachDetails(
        s,
        _item(status: 'Finished Airing', originalLanguage: 'ja'),
      );
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.subtitleLanguage,
          optionId: 'ja',
          remember: false,
        ),
      );
      expect(
        effects.whereType<VideoAcquisitionPersistPreferenceEffect>(),
        isEmpty,
      );
      expect(s.state.slots.subtitleLanguage, 'ja');
      expect(s.state.stage, VideoAcquisitionStage.resolvingResources);
    });

    test("偏好 'original' → 不问，解析出作品语言并说明依据", () {
      final _Session s = _Session(_defaults(subtitleLanguagePref: 'original'));
      _reachDetails(
        s,
        _item(status: 'Finished Airing', originalLanguage: 'ja'),
      );
      expect(s.state.question, isNull);
      expect(s.state.slots.subtitleLanguage, kVideoAcquisitionSubtitleOriginal);
      expect(
        s.said,
        contains(VideoAcquisitionSayKind.subtitleLanguageResolved),
      );
      final VideoAcquisitionAssistantMessage resolved = s.state.transcript
          .whereType<VideoAcquisitionAssistantMessage>()
          .firstWhere(
            (VideoAcquisitionAssistantMessage m) =>
                m.say.kind == VideoAcquisitionSayKind.subtitleLanguageResolved,
          );
      expect(resolved.say.args['language'], 'ja');
      expect(resolved.say.args['evidence'], 'originalLanguage');
      expect(s.state.stage, VideoAcquisitionStage.resolvingResources);
    });

    test("偏好 'original' 但作品语言判不出 → 追问一次（不含 original、无勾选）", () {
      final _Session s = _Session(_defaults(subtitleLanguagePref: 'original'));
      _reachDetails(s, _item(status: 'Finished Airing'));
      expect(
        s.said,
        contains(VideoAcquisitionSayKind.subtitleLanguageUnresolved),
      );
      final VideoAcquisitionQuestion q = s.state.question!;
      expect(q.slot, VideoAcquisitionSlot.subtitleLanguage);
      expect(q.rememberToggle, isFalse);
      expect(s.optionIds, isNot(contains(kVideoAcquisitionSubtitleOriginal)));
      expect(s.state.subtitleLanguageAsked, isTrue);
    });

    test('AI 补丁 subtitleLanguage: en → 落槽位、不写偏好', () {
      final _Session s = _Session(_defaults(subtitleLanguagePref: ''));
      s.feed(const VideoAcquisitionUserTextEvent('Show with english subs'));
      final List<VideoAcquisitionEffect> effects = s.feed(
        _provide(
          const VideoAcquisitionIntentPatch(
            workQueries: <String>['Show'],
            subtitleLanguage: 'en',
          ),
        ),
      );
      expect(
        effects.whereType<VideoAcquisitionPersistPreferenceEffect>(),
        isEmpty,
      );
      expect(
        effects.whereType<VideoAcquisitionSearchWorksEffect>(),
        hasLength(1),
      );
      expect(s.state.slots.subtitleLanguage, 'en');
      expect(s.state.slots.subtitleLanguageRemember, isFalse);
    });

    test('AI 补丁 subtitleLanguageRemember: true → 写偏好', () {
      final _Session s = _Session(_defaults(subtitleLanguagePref: ''));
      s.feed(const VideoAcquisitionUserTextEvent('Show, always english subs'));
      final List<VideoAcquisitionEffect> effects = s.feed(
        _provide(
          const VideoAcquisitionIntentPatch(
            workQueries: <String>['Show'],
            subtitleLanguage: 'en',
            subtitleLanguageRemember: true,
          ),
        ),
      );
      final VideoAcquisitionPersistPreferenceEffect persist = effects
          .whereType<VideoAcquisitionPersistPreferenceEffect>()
          .single;
      expect(persist.preference, VideoAcquisitionPreference.subtitleLanguage);
      expect(persist.value, 'en');
      expect(s.state.slots.subtitleLanguageRemember, isTrue);
    });
  });

  group('回答挂起问题的 AI 补丁与 chip 同口径（只问一次）', () {
    test('问字幕时打字回答 → 沿用勾选默认写偏好', () {
      final _Session s = _Session(_defaults(subtitleLanguagePref: ''));
      _reachDetails(s, _item(status: 'Finished Airing'));
      expect(s.state.question!.slot, VideoAcquisitionSlot.subtitleLanguage);
      expect(s.state.question!.rememberDefault, isTrue);
      final List<VideoAcquisitionEffect> effects = s.feed(
        _provide(
          const VideoAcquisitionIntentPatch(subtitleLanguage: 'en'),
          utterance: '英文字幕',
        ),
      );
      final VideoAcquisitionPersistPreferenceEffect persist = effects
          .whereType<VideoAcquisitionPersistPreferenceEffect>()
          .single;
      expect(persist.preference, VideoAcquisitionPreference.subtitleLanguage);
      expect(persist.value, 'en');
      expect(s.state.slots.subtitleLanguageRemember, isTrue);
    });

    test('问画质时打字回答 → 沿用勾选默认写偏好', () {
      final _Session s = _Session(_defaults(qualityPref: ''));
      _reachDetails(s, _item(status: 'Finished Airing'));
      expect(s.state.question!.slot, VideoAcquisitionSlot.quality);
      final List<VideoAcquisitionEffect> effects = s.feed(
        _provide(
          const VideoAcquisitionIntentPatch(
            quality: VideoAcquisitionQuality.p1080,
          ),
          utterance: '1080p',
        ),
      );
      final VideoAcquisitionPersistPreferenceEffect persist = effects
          .whereType<VideoAcquisitionPersistPreferenceEffect>()
          .single;
      expect(persist.preference, VideoAcquisitionPreference.quality);
      expect(s.state.slots.qualityRemember, isTrue);
    });

    test("偏好 'ask' 时打字回答 → 勾选默认不勾，不写偏好", () {
      final _Session s = _Session(_defaults(subtitleLanguagePref: 'ask'));
      _reachDetails(s, _item(status: 'Finished Airing'));
      expect(s.state.question!.slot, VideoAcquisitionSlot.subtitleLanguage);
      final List<VideoAcquisitionEffect> effects = s.feed(
        _provide(
          const VideoAcquisitionIntentPatch(subtitleLanguage: 'en'),
          utterance: '英文字幕',
        ),
      );
      expect(
        effects.whereType<VideoAcquisitionPersistPreferenceEffect>(),
        isEmpty,
      );
      expect(s.state.slots.subtitleLanguageRemember, isFalse);
    });
  });

  group('模式槽位', () {
    test('Currently Airing 的 tv → 问，选项恰为 [download, subscribe]', () {
      final _Session s = _Session(_oneSource);
      _reachDetails(s, _item(status: 'Currently Airing'));
      expect(s.state.question!.slot, VideoAcquisitionSlot.mode);
      expect(s.optionIds, <String>['download', 'subscribe']);
      expect(s.said, isNot(contains(VideoAcquisitionSayKind.airingUnknown)));
    });

    test('Finished Airing → 直接 download 不问', () {
      final _Session s = _Session(_oneSource);
      _reachDetails(s, _item(status: 'Finished Airing'));
      expect(s.state.slots.mode, VideoAcquisitionMode.download);
      expect(s.state.question?.slot, isNot(VideoAcquisitionSlot.mode));
    });

    test('电影 → 不问', () {
      final _Session s = _Session(_oneSource);
      _reachDetails(
        s,
        _item(kind: VideoMetadataMediaKind.movie, status: 'Currently Airing'),
      );
      expect(s.state.slots.mode, VideoAcquisitionMode.download);
      expect(s.state.question, isNull);
    });

    test('status null → 先说 airingUnknown 再问', () {
      final _Session s = _Session(_oneSource);
      _reachDetails(s, _item(status: null));
      expect(s.state.question!.slot, VideoAcquisitionSlot.mode);
      final List<VideoAcquisitionSayKind> kinds = s.said;
      final int unknownAt = kinds.indexOf(
        VideoAcquisitionSayKind.airingUnknown,
      );
      expect(unknownAt, greaterThanOrEqualTo(0));
      expect(kinds[unknownAt + 1], VideoAcquisitionSayKind.question);
    });

    test('chip 选 subscribe → 落槽位并继续', () {
      final _Session s = _Session(_oneSource);
      _reachDetails(s, _item(status: 'Currently Airing'));
      s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.mode,
          optionId: 'subscribe',
        ),
      );
      expect(s.state.slots.mode, VideoAcquisitionMode.subscribe);
      expect(s.state.stage, VideoAcquisitionStage.resolvingResources);
    });
  });

  group('季槽位', () {
    test('非 anime 的 tv 且 seasonCount 3 → 问，选项 1..3 + all', () {
      final _Session s = _Session(_oneSource);
      _reachDetails(
        s,
        _item(
          category: VideoDiscoveryCategory.tv,
          status: 'Ended',
          seasonCount: 3,
        ),
      );
      expect(s.state.question!.slot, VideoAcquisitionSlot.season);
      expect(s.optionIds, <String>['1', '2', '3', kVideoAcquisitionOptionAll]);
    });

    test('anime → 不问季', () {
      final _Session s = _Session(_oneSource);
      _reachDetails(s, _item(status: 'Finished Airing', seasonCount: 3));
      expect(s.state.question?.slot, isNot(VideoAcquisitionSlot.season));
      expect(s.state.stage, VideoAcquisitionStage.resolvingResources);
    });

    test('chip 选 2 → 资源搜索带 season 2；选 all → 不带季', () {
      final _Session a = _Session(_oneSource);
      _reachDetails(
        a,
        _item(
          category: VideoDiscoveryCategory.tv,
          status: 'Ended',
          seasonCount: 3,
        ),
      );
      final VideoAcquisitionSearchResourcesEffect bySeason =
          a
                  .feed(
                    const VideoAcquisitionChipChosenEvent(
                      slot: VideoAcquisitionSlot.season,
                      optionId: '2',
                    ),
                  )
                  .single
              as VideoAcquisitionSearchResourcesEffect;
      expect(bySeason.season, 2);

      final _Session b = _Session(_oneSource);
      _reachDetails(
        b,
        _item(
          category: VideoDiscoveryCategory.tv,
          status: 'Ended',
          seasonCount: 3,
        ),
      );
      final VideoAcquisitionSearchResourcesEffect all =
          b
                  .feed(
                    const VideoAcquisitionChipChosenEvent(
                      slot: VideoAcquisitionSlot.season,
                      optionId: kVideoAcquisitionOptionAll,
                    ),
                  )
                  .single
              as VideoAcquisitionSearchResourcesEffect;
      expect(all.season, isNull);
      expect(b.state.slots.allSeasons, isTrue);
    });
  });

  group('来源槽位', () {
    test('多来源无默认 → 问 targetSource；有默认 → 直接填', () {
      final List<VideoAcquisitionSource> two = <VideoAcquisitionSource>[
        const VideoAcquisitionSource(id: 1, label: 'A'),
        const VideoAcquisitionSource(id: 2, label: 'B'),
      ];
      final _Session ask = _Session(_defaults(sources: two));
      _reachDetails(ask, _item(status: 'Finished Airing'));
      expect(ask.state.question!.slot, VideoAcquisitionSlot.targetSource);
      expect(ask.optionIds, <String>['1', '2']);
      expect(ask.state.question!.options.first.label, 'A');

      final _Session fill = _Session(
        _defaults(sources: two, defaultSourceId: 2),
      );
      _reachDetails(fill, _item(status: 'Finished Airing'));
      expect(fill.state.slots.targetSourceId, 2);
      expect(fill.state.stage, VideoAcquisitionStage.resolvingResources);
    });
  });

  group('作品消解', () {
    test('开场用户文本 → 记录并交 AI 解析', () {
      final _Session s = _Session(_oneSource);
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionUserTextEvent('  Show  '),
      );
      expect(effects.single, isA<VideoAcquisitionParseIntentEffect>());
      expect(
        (effects.single as VideoAcquisitionParseIntentEffect).utterance,
        'Show',
      );
      expect(s.state.busy, isTrue);
      expect(s.state.transcript.single, isA<VideoAcquisitionUserMessage>());
    });

    test('0 命中（两个词都空）→ workNotFound 回到等文本', () {
      final _Session s = _Session(_oneSource);
      s.feed(const VideoAcquisitionUserTextEvent('Show'));
      final List<VideoAcquisitionEffect> first = s.feed(
        _provide(
          const VideoAcquisitionIntentPatch(workQueries: <String>['A', 'B']),
        ),
      );
      expect((first.single as VideoAcquisitionSearchWorksEffect).query, 'A');
      final List<VideoAcquisitionEffect> second = s.feed(
        const VideoAcquisitionWorksLoadedEvent(
          query: 'A',
          items: <VideoDiscoveryItem>[],
        ),
      );
      expect((second.single as VideoAcquisitionSearchWorksEffect).query, 'B');
      final List<VideoAcquisitionEffect> third = s.feed(
        const VideoAcquisitionWorksLoadedEvent(
          query: 'B',
          items: <VideoDiscoveryItem>[],
        ),
      );
      expect(third, isEmpty);
      expect(s.said.last, VideoAcquisitionSayKind.workNotFound);
      expect(s.state.stage, VideoAcquisitionStage.idle);
      expect(s.state.busy, isFalse);
      expect(s.state.transcript, isNotEmpty);
    });

    test('1 命中 → 直接 LoadDetailsEffect', () {
      final _Session s = _Session(_oneSource);
      s.feed(const VideoAcquisitionUserTextEvent('Show'));
      s.feed(
        _provide(
          const VideoAcquisitionIntentPatch(workQueries: <String>['Show']),
        ),
      );
      final List<VideoAcquisitionEffect> effects = s.feed(
        VideoAcquisitionWorksLoadedEvent(
          query: 'Show',
          items: <VideoDiscoveryItem>[_item()],
        ),
      );
      expect(effects.single, isA<VideoAcquisitionLoadDetailsEffect>());
      expect(s.state.stage, VideoAcquisitionStage.loadingDetails);
      expect(s.state.chosenItem, isNotNull);
      expect(s.said.last, VideoAcquisitionSayKind.workChosen);
    });

    test('≥2 命中 → DecideIdentityEffect，候选 key 形如 mal:1', () {
      final _Session s = _Session(_oneSource);
      s.feed(const VideoAcquisitionUserTextEvent('Show'));
      s.feed(
        _provide(
          const VideoAcquisitionIntentPatch(workQueries: <String>['Show']),
        ),
      );
      final List<VideoAcquisitionEffect> effects = s.feed(
        VideoAcquisitionWorksLoadedEvent(
          query: 'Show',
          items: <VideoDiscoveryItem>[
            _item(id: '1', title: 'Show', year: 2019),
            _item(id: '2', title: 'Show 2nd', year: 2021),
          ],
        ),
      );
      final VideoAcquisitionDecideIdentityEffect decide =
          effects.single as VideoAcquisitionDecideIdentityEffect;
      expect(
        decide.query.candidates.map((AiVideoIdentityCandidate c) => c.key),
        <String>['mal:1', 'mal:2'],
      );
      expect(decide.query.localTitles, <String>['Show', 'Show']);
      expect(decide.query.candidates.first.episodeCount, 12);
      expect(s.state.stage, VideoAcquisitionStage.awaitingWorkChoice);
      expect(s.state.busy, isTrue);
    });

    test('判定高置信 → 自动选并 aiPicked，随即拉详情', () {
      final _Session s = _Session(_oneSource);
      s.feed(const VideoAcquisitionUserTextEvent('Show'));
      s.feed(
        _provide(
          const VideoAcquisitionIntentPatch(workQueries: <String>['Show']),
        ),
      );
      s.feed(
        VideoAcquisitionWorksLoadedEvent(
          query: 'Show',
          items: <VideoDiscoveryItem>[
            _item(id: '1', title: 'Show'),
            _item(id: '2', title: 'Show 2nd'),
          ],
        ),
      );
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionIdentityDecidedEvent(
          AiVideoIdentityDecision(key: 'mal:2', confidence: 0.93),
        ),
      );
      expect(effects.single, isA<VideoAcquisitionLoadDetailsEffect>());
      expect(s.state.chosenItem!.reference.mediaId, '2');
      final VideoAcquisitionAssistantMessage picked = s.state.transcript
          .whereType<VideoAcquisitionAssistantMessage>()
          .firstWhere(
            (VideoAcquisitionAssistantMessage m) =>
                m.say.kind == VideoAcquisitionSayKind.aiPicked,
          );
      expect(picked.say.args['title'], 'Show 2nd');
      expect(picked.say.args['confidence'], 0.93);
      expect(picked.question!.options.single.id, kVideoAcquisitionOptionNone);
      expect(s.state.question, isNull, reason: '「换一部」不阻塞');
      expect(s.state.stage, VideoAcquisitionStage.loadingDetails);
    });

    test('判定低置信 → 问 work，最后一项 none', () {
      final _Session s = _Session(_oneSource);
      s.feed(const VideoAcquisitionUserTextEvent('Show'));
      s.feed(
        _provide(
          const VideoAcquisitionIntentPatch(workQueries: <String>['Show']),
        ),
      );
      s.feed(
        VideoAcquisitionWorksLoadedEvent(
          query: 'Show',
          items: <VideoDiscoveryItem>[
            _item(id: '1', title: 'Show', year: 2019),
            _item(id: '2', title: 'Show 2nd'),
          ],
        ),
      );
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionIdentityDecidedEvent(
          AiVideoIdentityDecision(key: 'mal:2', confidence: 0.5),
        ),
      );
      expect(effects, isEmpty);
      final VideoAcquisitionQuestion q = s.state.question!;
      expect(q.slot, VideoAcquisitionSlot.work);
      expect(s.optionIds, <String>['0', '1', kVideoAcquisitionOptionNone]);
      expect(q.options.first.label, 'Show');
      expect(q.options.first.hint, '2019 · anime');
      expect(q.preselectedIndex, 1);
      expect(s.state.busy, isFalse);

      final List<VideoAcquisitionEffect> chosen = s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.work,
          optionId: '0',
        ),
      );
      expect(chosen.single, isA<VideoAcquisitionLoadDetailsEffect>());
      expect(s.state.chosenItem!.reference.mediaId, '1');
    });

    test('work 问题选 none → 清候选回到等文本', () {
      final _Session s = _Session(_oneSource);
      s.feed(const VideoAcquisitionUserTextEvent('Show'));
      s.feed(
        _provide(
          const VideoAcquisitionIntentPatch(workQueries: <String>['Show']),
        ),
      );
      s.feed(
        VideoAcquisitionWorksLoadedEvent(
          query: 'Show',
          items: <VideoDiscoveryItem>[
            _item(id: '1'),
            _item(id: '2'),
          ],
        ),
      );
      s.feed(const VideoAcquisitionIdentityDecidedEvent(null));
      s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.work,
          optionId: kVideoAcquisitionOptionNone,
        ),
      );
      expect(s.state.stage, VideoAcquisitionStage.idle);
      expect(s.state.workCandidates, isEmpty);
      expect(s.state.question, isNull);
      expect(s.state.transcript, isNotEmpty);
    });
  });

  group('AI 不可用', () {
    test('开场 → 原文当查询词 SearchWorksEffect', () {
      final _Session s = _Session(_oneSource);
      s.feed(const VideoAcquisitionUserTextEvent('Some Show'));
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionAiUnavailableEvent(
          utterance: 'Some Show',
          code: 'unassigned',
        ),
      );
      final VideoAcquisitionSearchWorksEffect search =
          effects.single as VideoAcquisitionSearchWorksEffect;
      expect(search.query, 'Some Show');
      expect(s.said, contains(VideoAcquisitionSayKind.aiUnavailable));
      expect(s.state.stage, VideoAcquisitionStage.resolvingWork);
    });

    test('有问题挂起时 → 重出同一问题', () {
      final _Session s = _Session(_oneSource);
      _reachDetails(s, _item(status: 'Currently Airing'));
      expect(s.state.question!.slot, VideoAcquisitionSlot.mode);
      s.feed(const VideoAcquisitionUserTextEvent('hmm'));
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionAiUnavailableEvent(utterance: 'hmm'),
      );
      expect(effects, isEmpty);
      expect(s.state.question!.slot, VideoAcquisitionSlot.mode);
      expect(s.optionIds, <String>['download', 'subscribe']);
      expect(s.said.last, VideoAcquisitionSayKind.question);
      expect(s.state.busy, isFalse);
    });
  });

  group('AI 意图', () {
    test('choose 等价于点了对应选项', () {
      final _Session s = _Session(_oneSource);
      _reachDetails(s, _item(status: 'Currently Airing'));
      s.feed(const VideoAcquisitionUserTextEvent('subscribe please'));
      s.feed(
        const VideoAcquisitionAiIntentEvent(
          VideoAcquisitionIntent(
            VideoAcquisitionIntentKind.choose,
            VideoAcquisitionIntentPatch(choiceIndex: 1),
          ),
          utterance: 'subscribe please',
        ),
      );
      expect(s.state.slots.mode, VideoAcquisitionMode.subscribe);
    });

    test('unclear → 说 unclear 并重出同一问题', () {
      final _Session s = _Session(_oneSource);
      _reachDetails(s, _item(status: 'Currently Airing'));
      s.feed(const VideoAcquisitionUserTextEvent('???'));
      s.feed(
        const VideoAcquisitionAiIntentEvent(
          VideoAcquisitionIntent.unclear(),
          utterance: '???',
        ),
      );
      expect(s.said, contains(VideoAcquisitionSayKind.unclear));
      expect(s.state.question!.slot, VideoAcquisitionSlot.mode);
    });

    test('provide 在 collectingSlots 填了模式 → 继续决策表', () {
      final _Session s = _Session(_oneSource);
      _reachDetails(s, _item(status: 'Currently Airing'));
      s.feed(const VideoAcquisitionUserTextEvent('just download it'));
      final List<VideoAcquisitionEffect> effects = s.feed(
        _provide(
          const VideoAcquisitionIntentPatch(
            mode: VideoAcquisitionMode.download,
          ),
          utterance: 'just download it',
        ),
      );
      expect(effects.single, isA<VideoAcquisitionSearchResourcesEffect>());
      expect(s.state.slots.mode, VideoAcquisitionMode.download);
    });
  });

  group('库内存在性', () {
    test('inLibrary → 说 alreadyInLibrary 并问 presence；continue → 问 mode', () {
      final _Session s = _Session(_oneSource);
      _reachDetails(
        s,
        _item(status: 'Currently Airing'),
        presence: const VideoLibraryPresence(
          workId: 3,
          collectionId: 9,
          managedEpisodeKeys: <String>{'S01E01', 'S01E05'},
        ),
      );
      expect(s.said, contains(VideoAcquisitionSayKind.alreadyInLibrary));
      final VideoAcquisitionAssistantMessage said = s.state.transcript
          .whereType<VideoAcquisitionAssistantMessage>()
          .firstWhere(
            (VideoAcquisitionAssistantMessage m) =>
                m.say.kind == VideoAcquisitionSayKind.alreadyInLibrary,
          );
      expect(said.say.args['highestEpisode'], 5);
      expect(s.state.question!.slot, VideoAcquisitionSlot.presence);
      expect(s.optionIds, <String>[
        kVideoAcquisitionOptionContinue,
        kVideoAcquisitionOptionCancel,
      ]);

      s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.presence,
          optionId: kVideoAcquisitionOptionContinue,
        ),
      );
      expect(s.state.presenceAcknowledged, isTrue);
      expect(s.state.question!.slot, VideoAcquisitionSlot.mode);
    });

    test('已订阅 → 说 alreadySubscribed；presence 选 cancel → 取消', () {
      final _Session s = _Session(_oneSource);
      _reachDetails(
        s,
        _item(status: 'Currently Airing'),
        alreadySubscribed: true,
      );
      expect(s.said, contains(VideoAcquisitionSayKind.alreadySubscribed));
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.presence,
          optionId: kVideoAcquisitionOptionCancel,
        ),
      );
      expect(effects.single, isA<VideoAcquisitionCloseEffect>());
      expect(s.state.stage, VideoAcquisitionStage.cancelled);
    });
  });

  group('资源阶段', () {
    test('资源搜索效果带作品引用', () {
      final _Session s = _Session(_oneSource);
      final VideoAcquisitionSearchResourcesEffect search = _reachResources(
        s,
        _item(status: 'Finished Airing'),
      );
      expect(search.reference.mediaId, '1');
      expect(search.season, isNull);
      expect(s.state.busy, isTrue);
    });

    test('resolutionMismatch → 问 resolutionFallback（可用分辨率 + cancel）', () {
      final _Session s = _Session(_oneSource);
      _reachResources(s, _item(status: 'Finished Airing'));
      final List<VideoAcquisitionEffect> effects = s.feed(
        VideoAcquisitionResourcesLoadedEvent(
          _episodeResources(resolution: '720p'),
        ),
      );
      expect(effects, isEmpty);
      final VideoAcquisitionQuestion q = s.state.question!;
      expect(q.slot, VideoAcquisitionSlot.resolutionFallback);
      expect(s.optionIds, <String>['720p', kVideoAcquisitionOptionCancel]);
      expect(q.args['wanted'], '1080p');
      expect(q.args['available'], <String>['720p']);
      expect(s.state.busy, isFalse);

      s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.resolutionFallback,
          optionId: '720p',
        ),
      );
      expect(s.state.slots.quality, VideoAcquisitionQuality.p720);
      expect(s.state.stage, VideoAcquisitionStage.awaitingResourceConfirm);
      expect(s.state.question!.slot, VideoAcquisitionSlot.resource);
    });

    test('无候选 → failed(no_candidates) 回到等文本', () {
      final _Session s = _Session(_oneSource);
      _reachResources(s, _item(status: 'Finished Airing'));
      s.feed(
        const VideoAcquisitionResourcesLoadedEvent(<VideoResourceCandidate>[]),
      );
      expect(s.lastAssistant.say.kind, VideoAcquisitionSayKind.failed);
      expect(
        s.lastAssistant.say.args['message'],
        kVideoAcquisitionFailureNoCandidates,
      );
      expect(s.state.stage, VideoAcquisitionStage.idle);
      expect(s.state.chosenItem, isNull);
    });

    test('ok → summary + 问 resource（confirm / next / cancel）', () {
      final _Session s = _Session(_oneSource);
      _reachResources(s, _item(status: 'Finished Airing'));
      s.feed(VideoAcquisitionResourcesLoadedEvent(_episodeResources()));
      expect(s.state.stage, VideoAcquisitionStage.awaitingResourceConfirm);
      expect(s.state.plan, isNotNull);
      expect(s.state.plan!.picks, hasLength(2));
      final VideoAcquisitionAssistantMessage summary = s.state.transcript
          .whereType<VideoAcquisitionAssistantMessage>()
          .firstWhere(
            (VideoAcquisitionAssistantMessage m) =>
                m.say.kind == VideoAcquisitionSayKind.summary,
          );
      expect(summary.say.args['releaseGroup'], 'Grp');
      expect(summary.say.args['resolution'], '1080p');
      expect(summary.say.args['provider'], 'nyaa');
      expect(summary.say.args['count'], 2);
      expect(summary.say.args['batch'], isFalse);
      expect(summary.say.args['seeders'], 50);
      expect(s.state.question!.slot, VideoAcquisitionSlot.resource);
      expect(s.optionIds, <String>[
        kVideoAcquisitionOptionConfirm,
        kVideoAcquisitionOptionNext,
        kVideoAcquisitionOptionCancel,
      ]);
    });

    test('next 越界 → noMoreVersions，停在末组并重出问题', () {
      final _Session s = _Session(_oneSource);
      _reachResources(s, _item(status: 'Finished Airing'));
      s.feed(VideoAcquisitionResourcesLoadedEvent(_episodeResources()));
      final VideoAcquisitionResourcePlan before = s.state.plan!;
      s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.resource,
          optionId: kVideoAcquisitionOptionNext,
        ),
      );
      expect(s.said, contains(VideoAcquisitionSayKind.noMoreVersions));
      expect(identical(s.state.plan, before), isTrue);
      expect(s.state.groupCursor, 0);
      expect(s.state.question!.slot, VideoAcquisitionSlot.resource);
      expect(s.state.stage, VideoAcquisitionStage.awaitingResourceConfirm);
    });

    test('next 有下一组 → 换卡；AI 的 next 意图同效', () {
      final _Session s = _Session(_oneSource);
      _reachResources(s, _item(status: 'Finished Airing'));
      s.feed(
        VideoAcquisitionResourcesLoadedEvent(<VideoResourceCandidate>[
          ..._episodeResources(group: 'Alpha'),
          ..._episodeResources(group: 'Beta'),
        ]),
      );
      final String? first = s.state.plan!.group.releaseGroup;
      s.feed(const VideoAcquisitionUserTextEvent('another one'));
      s.feed(
        const VideoAcquisitionAiIntentEvent(
          VideoAcquisitionIntent(
            VideoAcquisitionIntentKind.next,
            VideoAcquisitionIntentPatch(),
          ),
          utterance: 'another one',
        ),
      );
      expect(s.state.groupCursor, 1);
      expect(s.state.plan!.group.releaseGroup, isNot(first));
      expect(s.state.question!.slot, VideoAcquisitionSlot.resource);
    });

    test('订阅模式没有可订阅版本 → 问 subscribeFallback；选 download 重过滤', () {
      final _Session s = _Session(_oneSource);
      _reachDetails(s, _item(status: 'Currently Airing'));
      s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.mode,
          optionId: 'subscribe',
        ),
      );
      expect(s.state.stage, VideoAcquisitionStage.resolvingResources);
      s.feed(
        VideoAcquisitionResourcesLoadedEvent(<VideoResourceCandidate>[
          _FakeResource(
            remoteId: 'x',
            title: 'Show - 01 (1080p)',
            resolution: '1080p',
            seeders: 10,
          ),
        ]),
      );
      expect(s.state.question!.slot, VideoAcquisitionSlot.subscribeFallback);
      expect(s.optionIds, <String>[
        kVideoAcquisitionOptionDownload,
        kVideoAcquisitionOptionCancel,
      ]);
      s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.subscribeFallback,
          optionId: kVideoAcquisitionOptionDownload,
        ),
      );
      expect(s.state.slots.mode, VideoAcquisitionMode.download);
      expect(s.state.stage, VideoAcquisitionStage.awaitingResourceConfirm);
    });
  });

  group('提交', () {
    test('confirm → 先 SetSeriesSubtitleLanguage 再 SubmitDownload', () {
      final _Session s = _Session(_oneSource);
      _reachResources(s, _item(status: 'Finished Airing'));
      s.feed(VideoAcquisitionResourcesLoadedEvent(_episodeResources()));
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.resource,
          optionId: kVideoAcquisitionOptionConfirm,
        ),
      );
      expect(effects, hasLength(2));
      final VideoAcquisitionSetSeriesSubtitleLanguageEffect remember =
          effects.first as VideoAcquisitionSetSeriesSubtitleLanguageEffect;
      expect(remember.languageCode, 'ja');
      expect(remember.reference.mediaId, '1');
      final VideoAcquisitionSubmitDownloadEffect submit =
          effects.last as VideoAcquisitionSubmitDownloadEffect;
      expect(submit.targetSourceId, 7);
      expect(submit.installSubtitles, isTrue);
      expect(submit.plan.picks, hasLength(2));
      expect(
        s.said,
        contains(VideoAcquisitionSayKind.subtitleLanguageRemembered),
      );
      expect(s.state.stage, VideoAcquisitionStage.submitting);
      expect(s.state.busy, isTrue);

      final List<VideoAcquisitionEffect> done = s.feed(
        const VideoAcquisitionSubmittedEvent(count: 2),
      );
      expect(done.single, isA<VideoAcquisitionCloseEffect>());
      expect(s.state.stage, VideoAcquisitionStage.done);
      expect(s.lastAssistant.say.kind, VideoAcquisitionSayKind.submitted);
      expect(s.lastAssistant.say.args['count'], 2);
      expect(s.lastAssistant.say.args['mode'], 'download');
    });

    test('subtitleLanguage == none → 无记忆效果且 installSubtitles == false', () {
      final _Session s = _Session(_defaults(subtitleLanguagePref: 'none'));
      _reachResources(s, _item(status: 'Finished Airing'));
      s.feed(VideoAcquisitionResourcesLoadedEvent(_episodeResources()));
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.resource,
          optionId: kVideoAcquisitionOptionConfirm,
        ),
      );
      expect(
        effects.whereType<VideoAcquisitionSetSeriesSubtitleLanguageEffect>(),
        isEmpty,
      );
      final VideoAcquisitionSubmitDownloadEffect submit =
          effects.single as VideoAcquisitionSubmitDownloadEffect;
      expect(submit.installSubtitles, isFalse);
      expect(
        s.said,
        isNot(contains(VideoAcquisitionSayKind.subtitleLanguageRemembered)),
      );
    });

    test('original 解析出的码写进每系列记忆', () {
      final _Session s = _Session(_defaults(subtitleLanguagePref: 'original'));
      _reachResources(
        s,
        _item(status: 'Finished Airing', originalLanguage: 'ja'),
      );
      s.feed(VideoAcquisitionResourcesLoadedEvent(_episodeResources()));
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.resource,
          optionId: kVideoAcquisitionOptionConfirm,
        ),
      );
      final VideoAcquisitionSetSeriesSubtitleLanguageEffect remember =
          effects.first as VideoAcquisitionSetSeriesSubtitleLanguageEffect;
      expect(remember.languageCode, 'ja');
    });

    test('订阅模式 confirm → SubmitSubscriptionEffect', () {
      final _Session s = _Session(_oneSource);
      _reachDetails(s, _item(status: 'Currently Airing'));
      s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.mode,
          optionId: 'subscribe',
        ),
      );
      s.feed(VideoAcquisitionResourcesLoadedEvent(_episodeResources()));
      expect(s.state.question!.slot, VideoAcquisitionSlot.resource);
      expect(s.state.plan!.filter, isNotNull);
      expect(s.state.plan!.startAfterEpisode, 1);
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.resource,
          optionId: kVideoAcquisitionOptionConfirm,
        ),
      );
      expect(effects.last, isA<VideoAcquisitionSubmitSubscriptionEffect>());
    });

    test('提交失败 → failed、busy 复位、回到版本确认可再试', () {
      final _Session s = _Session(_oneSource);
      _reachResources(s, _item(status: 'Finished Airing'));
      s.feed(VideoAcquisitionResourcesLoadedEvent(_episodeResources()));
      s.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.resource,
          optionId: kVideoAcquisitionOptionConfirm,
        ),
      );
      final List<VideoAcquisitionEffect> effects = s.feed(
        const VideoAcquisitionFailedEvent('backend_down'),
      );
      expect(effects, isEmpty);
      expect(s.said, contains(VideoAcquisitionSayKind.failed));
      expect(s.state.busy, isFalse);
      expect(s.state.stage, VideoAcquisitionStage.awaitingResourceConfirm);
      expect(s.state.question!.slot, VideoAcquisitionSlot.resource);
    });
  });

  group('取消', () {
    test('任意阶段 CancelEvent → cancelled + CloseEffect', () {
      for (final _Session s in <_Session>[
        _Session(_oneSource),
        _Session(_oneSource)..feed(const VideoAcquisitionUserTextEvent('Show')),
        _Session(_oneSource)
          .._reach(_item(status: 'Currently Airing'))
          ..feed(
            const VideoAcquisitionChipChosenEvent(
              slot: VideoAcquisitionSlot.mode,
              optionId: 'download',
            ),
          ),
      ]) {
        final List<VideoAcquisitionEffect> effects = s.feed(
          const VideoAcquisitionCancelEvent(),
        );
        expect(effects.single, isA<VideoAcquisitionCloseEffect>());
        expect(s.state.stage, VideoAcquisitionStage.cancelled);
        expect(s.lastAssistant.say.kind, VideoAcquisitionSayKind.cancelled);
        expect(s.state.busy, isFalse);
        // 终态后再来事件一律忽略。
        expect(s.feed(const VideoAcquisitionUserTextEvent('again')), isEmpty);
      }
    });

    test('AI cancel 意图与 resource 的 cancel chip 同效', () {
      final _Session a = _Session(_oneSource);
      _reachDetails(a, _item(status: 'Currently Airing'));
      a.feed(const VideoAcquisitionUserTextEvent('never mind'));
      final List<VideoAcquisitionEffect> byIntent = a.feed(
        const VideoAcquisitionAiIntentEvent(
          VideoAcquisitionIntent(
            VideoAcquisitionIntentKind.cancel,
            VideoAcquisitionIntentPatch(),
          ),
          utterance: 'never mind',
        ),
      );
      expect(byIntent.single, isA<VideoAcquisitionCloseEffect>());
      expect(a.state.stage, VideoAcquisitionStage.cancelled);

      final _Session b = _Session(_oneSource);
      _reachResources(b, _item(status: 'Finished Airing'));
      b.feed(VideoAcquisitionResourcesLoadedEvent(_episodeResources()));
      final List<VideoAcquisitionEffect> byChip = b.feed(
        const VideoAcquisitionChipChosenEvent(
          slot: VideoAcquisitionSlot.resource,
          optionId: kVideoAcquisitionOptionCancel,
        ),
      );
      expect(byChip.single, isA<VideoAcquisitionCloseEffect>());
      expect(b.state.stage, VideoAcquisitionStage.cancelled);
    });
  });
}

extension on _Session {
  void _reach(VideoDiscoveryItem item) => _reachDetails(this, item);
}
